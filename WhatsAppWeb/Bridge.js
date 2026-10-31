// Injected at document start into web.whatsapp.com.
// Talks to Swift through window.webkit.messageHandlers.dw.
(function () {
  if (window.__dw) return;
  var post = function (msg) {
    try { window.webkit.messageHandlers.dw.postMessage(msg); } catch (e) {}
  };

  // ---- Look like desktop Safari ---------------------------------------------------
  // WhatsApp treats "Mac + maxTouchPoints > 2" as an iPad/iPhone and shows a
  // "Download WhatsApp from the App Store" overlay instead of the login screen.
  // Touch input itself keeps working; only the capability report changes.
  try {
    Object.defineProperty(Navigator.prototype, 'maxTouchPoints', { get: function () { return 0; }, configurable: true });
  } catch (e) {}

  // ---- Notification API shim -------------------------------------------------
  // WKWebView has no window.Notification; WhatsApp Web uses it for new-message alerts.
  var live = {};
  var seq = 0;
  var loggedIn = false;

  // Native cannot read a blob: URL — it only exists inside this page — so those are inlined as data:
  // URLs here. Resolving is capped at 300 ms and the notification is posted either way: a missing avatar
  // is fine, a missing notification is not.
  var ICON_TIMEOUT = 300;
  var ICON_MAX_BYTES = 512 * 1024;
  function iconForNative(icon, cb) {
    if (!icon || !/^blob:/i.test(icon)) {
      // Native has no document to resolve a relative path against, so resolve it here.
      if (icon && !/^(data|https?):/i.test(icon)) {
        try { icon = new URL(icon, location.href).href; } catch (e) { icon = ''; }
      }
      cb(icon || '');
      return;
    }
    var done = false;
    function finish(url) { if (!done) { done = true; cb(url || ''); } }
    setTimeout(function () { finish(''); }, ICON_TIMEOUT);
    try {
      fetch(icon).then(function (r) { return r.blob(); }).then(function (b) {
        if (!b || b.size > ICON_MAX_BYTES) { finish(''); return; }
        var fr = new FileReader();
        fr.onload = function () { finish(typeof fr.result === 'string' ? fr.result : ''); };
        fr.onerror = function () { finish(''); };
        fr.readAsDataURL(b);
      }).catch(function () { finish(''); });
    } catch (e) { finish(''); }
  }

  function DWNotification(title, options) {
    options = options || {};
    this.title = String(title || '');
    this.body = options.body ? String(options.body) : '';
    this.tag = options.tag ? String(options.tag) : '';
    this.icon = options.icon || '';
    this.data = options.data;
    this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
    this._id = 'n' + (++seq) + '-' + Date.now();
    this._closed = false;
    this._listeners = {};
    live[this._id] = this;
    var self = this;
    // The avatar is resolved first (see iconForNative) and sent with the message.
    iconForNative(this.icon, function (icon) {
      // Closing in the meantime (read on another device) must not bring the notification back.
      if (!self._closed) post({ type: 'notify', id: self._id, title: self.title, body: self.body, tag: self.tag, icon: icon });
    });
    setTimeout(function () { self._fire('show'); }, 0);
  }
  DWNotification.permission = 'granted';
  DWNotification.maxActions = 0;
  // Native asks for iOS permission once the chat list has loaded (see "loggedIn").
  DWNotification.requestPermission = function (cb) {
    if (typeof cb === 'function') cb('granted');
    return Promise.resolve('granted');
  };
  DWNotification.prototype.close = function () {
    this._closed = true;
    if (this.tag) post({ type: 'closeNotification', tag: this.tag });
    delete live[this._id];
    this._fire('close');
  };
  DWNotification.prototype.addEventListener = function (type, fn) {
    (this._listeners[type] = this._listeners[type] || []).push(fn);
  };
  DWNotification.prototype.removeEventListener = function (type, fn) {
    var l = this._listeners[type]; if (!l) return;
    var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1);
  };
  DWNotification.prototype._fire = function (type) {
    var ev = { type: type, target: this, currentTarget: this, preventDefault: function () {} };
    try { if (typeof this['on' + type] === 'function') this['on' + type](ev); } catch (e) {}
    (this._listeners[type] || []).slice().forEach(function (fn) { try { fn.call(this, ev); } catch (e) {} }, this);
  };
  try {
    Object.defineProperty(window, 'Notification', { value: DWNotification, writable: true, configurable: true });
  } catch (e) { window.Notification = DWNotification; }

  // Some code paths query the Permissions API for notifications.
  if (navigator.permissions && navigator.permissions.query) {
    var origQuery = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = function (desc) {
      if (desc && desc.name === 'notifications') {
        return Promise.resolve({ state: 'granted', status: 'granted', onchange: null,
          addEventListener: function () {}, removeEventListener: function () {} });
      }
      return origQuery(desc);
    };
  }

  // ---- Login detection -----------------------------------------------------------
  // (The unread badge is read natively from the page title, which keeps working when JS is throttled.)
  // Stops itself after the first detection; loggedIn was never reset before either, so behavior is the same.
  var loginTimer = setInterval(function () {
    if (!document.getElementById('side')) return;
    clearInterval(loginTimer);
    loggedIn = true;
    post({ type: 'loggedIn' });
  }, 2000);

  // ---- Colors behind the status bar / home indicator -------------------------------
  // Native paints the strips above and below the web view with the page's edge colors.
  function bgAt(x, y) {
    var el = document.elementFromPoint(x, y);
    for (; el && el !== document.documentElement; el = el.parentElement) {
      var c = getComputedStyle(el).backgroundColor;
      if (c && c !== 'transparent' && !/,\s*0\)$/.test(c)) return c;
    }
    return getComputedStyle(document.body || document.documentElement).backgroundColor;
  }
  var lastEdges = '';
  setInterval(function () {
    if (!document.body || document.hidden) return;
    var top = bgAt(window.innerWidth / 2, 2), bottom = bgAt(window.innerWidth / 2, window.innerHeight - 2);
    if (top + bottom !== lastEdges) { lastEdges = top + bottom; post({ type: 'edges', top: top, bottom: bottom }); }
  }, 1000);

  // ---- Focus ------------------------------------------------------------------------
  // WhatsApp never shows a notification while document.hasFocus() is true, and uses focus for
  // read receipts. In a WKWebView hasFocus() depends on UIKit first-responder state, so report the
  // app's real foreground/background state instead (native calls setAppActive on lifecycle changes).
  var appActive = true;
  Document.prototype.hasFocus = function () { return appActive; };
  function setAppActive(v) {
    v = !!v;
    if (v === appActive) return;
    appActive = v;
    try { window.dispatchEvent(new FocusEvent(v ? 'focus' : 'blur')); } catch (e) {}
  }

  // ---- Which chat is on screen ---------------------------------------------------------
  // Native keeps the alert sound off for a message in the chat you are already reading, so it needs the
  // name in the conversation header (the same #main > header anchor Layout.js uses for the back button).
  var openChat = '';
  function currentChatTitle() {
    var main = document.getElementById('main');
    var header = main && main.querySelector(':scope > header');
    if (!header) return '';
    var el = header.querySelector('[data-testid="conversation-info-header-chat-title"], span[title], div[title]');
    var name = el ? String(el.getAttribute('title') || el.textContent || '') : '';
    name = name.replace(/\s+/g, ' ').trim();
    if (!name) {
      // Last resort: WhatsApp puts the name of the open chat in the page title.
      name = String(document.title || '').replace(/^\(\d+\)\s*/, '').trim();
      if (/^WhatsApp/i.test(name)) name = '';
    }
    return name;
  }
  setInterval(function () {
    var name = currentChatTitle();
    if (name === openChat) return;
    openChat = name;
    post({ type: 'openChat', title: name });
  }, 2000);

  // ---- Background keep-alive (opt-in) ----------------------------------------------
  // WebKit keeps a page's process at foreground priority while it is playing audio, so something has to
  // keep playing after you leave the app. Two ways, both inaudible:
  //   webaudio - a silent AudioContext graph. iOS does not turn it into a lock-screen media card, but it
  //              only starts from a real tap and needs navigator.audioSession ("playback", Safari 16.4+).
  //   element  - a looping 1 s clip of digital silence in an <audio> element. Always works; while it runs
  //              iOS shows a lock-screen player card titled with document.title.
  // Native picks the mode and reacts to the state reported below: a mode that never reaches "running" is
  // replaced by the other one. Both modes also repair themselves, because a single interruption (a call,
  // Siri, another app taking the session, a lock-screen pause) used to stop delivery silently while the
  // app still looked connected.
  var keepOn = false;        // native wants the connection held (the app is in the background)
  var keepMode = 'element';  // 'element' or 'webaudio', chosen by native
  var keepEl = null;
  var keepCtx = null;
  var keepArmed = false;     // a suspended AudioContext exists and may be resumed
  var lastBeat = 0;
  var stateTimer = 0;

  function silentWavURL() {
    var n = 8000, buf = new Uint8Array(44 + n), dv = new DataView(buf.buffer);
    var w = function (o, str) { for (var i = 0; i < str.length; i++) buf[o + i] = str.charCodeAt(i); };
    w(0, 'RIFF'); dv.setUint32(4, 36 + n, true); w(8, 'WAVE'); w(12, 'fmt ');
    dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, 1, true);
    dv.setUint32(24, 8000, true); dv.setUint32(28, 8000, true); dv.setUint16(32, 1, true); dv.setUint16(34, 8, true);
    w(36, 'data'); dv.setUint32(40, n, true); buf.fill(0x80, 44); // 1 s of 8-bit PCM silence
    return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
  }

  /* ---------- audio element ---------- */
  function elementMode() {
    if (keepEl) return keepEl;
    keepEl = new Audio(silentWavURL());
    keepEl.loop = true;
    keepEl.preload = 'auto';
    // iOS stops it (a call, Siri, the lock-screen controls, another app taking the session): start it again.
    ['pause', 'ended', 'stalled', 'error'].forEach(function (t) {
      keepEl.addEventListener(t, function () {
        if (keepOn && keepMode === 'element') setTimeout(repair, 250);
      });
    });
    return keepEl;
  }

  function elementStart() {
    var el = elementMode();
    try {
      var p = el.play();
      if (p && p.catch) p.catch(function () { reportSoon(); });
    } catch (e) { reportSoon(); }
    return el;
  }

  /* ---------- Web Audio ---------- */
  function webAudioSession() {
    // The Audio Session API is what tells WebKit this page plays media in the background; without it a
    // backgrounded AudioContext is suspended instead of keeping the page alive.
    try {
      var s = navigator.audioSession;
      if (!s) return false;
      if (s.type !== 'playback') s.type = 'playback';
      return s.type === 'playback';
    } catch (e) { return false; }
  }

  function releaseWebAudioSession() {
    // Back to WebKit's own choice, so nothing about the audio session is left changed in the foreground.
    try { if (navigator.audioSession) navigator.audioSession.type = 'auto'; } catch (e) {}
  }

  // Built on the first tap on the page, then left suspended: a context created outside a user gesture is
  // refused, and by the time the app goes to the background it is too late for one. Suspended, it costs
  // nothing and cannot disturb other apps' audio while you are using the app.
  function armWebAudio() {
    if (keepArmed) return;
    var Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;
    try {
      keepCtx = new Ctx();
      var osc = keepCtx.createOscillator(), gain = keepCtx.createGain();
      gain.gain.value = 0.00001;   // about -100 dB: a real signal, far below anything you can hear
      osc.frequency.value = 1000;
      osc.connect(gain);
      gain.connect(keepCtx.destination);
      osc.start();
      var p = keepCtx.suspend();
      if (p && p.catch) p.catch(function () {});
      keepCtx.addEventListener('statechange', function () {
        if (keepOn && keepMode === 'webaudio') repair();
        if (keepCtx.state === 'running') reportState(); else reportSoon();
      });
      keepArmed = true;
    } catch (e) { keepCtx = null; }
  }

  ['touchstart', 'click', 'mousedown'].forEach(function (t) {
    document.addEventListener(t, armWebAudio, true);
  });

  function webAudioStart() {
    if (!keepCtx) armWebAudio();
    if (!keepCtx || !webAudioSession()) return false;
    try {
      var p = keepCtx.resume();
      if (p && p.catch) p.catch(function () { reportSoon(); });
    } catch (e) { return false; }
    return keepCtx.state === 'running';
  }

  /* ---------- shared ---------- */
  function keepState() {
    if (!keepOn) return 'off';
    if (keepMode === 'webaudio') return keepCtx ? keepCtx.state : 'unavailable';
    if (!keepEl) return 'idle';
    return keepEl.paused || keepEl.ended ? 'paused' : 'running';
  }

  // Native treats anything but "running" as a mode this device does not support, so a mode that is still
  // coming up is given a grace period before it is reported.
  function reportSoon() {
    clearTimeout(stateTimer);
    stateTimer = setTimeout(reportState, 1500);
  }

  function reportState() {
    post({ type: 'keepAlive', mode: keepOn ? keepMode : 'off', state: keepState() });
  }

  function repair() {
    if (!keepOn) return;
    if (keepMode === 'webaudio') {
      if (keepCtx && keepCtx.state !== 'running') webAudioStart();
    } else if (keepEl && (keepEl.paused || keepEl.ended)) {
      elementStart();
    }
  }

  function keepAlive(on, mode) {
    if (mode === 'webaudio' || mode === 'element') keepMode = mode;
    keepOn = !!on;
    if (!keepOn) {
      // keepOn is already false, so the element's own "pause" handler does not read this as a failure.
      if (keepEl && !keepEl.paused) { try { keepEl.pause(); } catch (e) {} }
      if (keepCtx && keepCtx.state === 'running') {
        try { var q = keepCtx.suspend(); if (q && q.catch) q.catch(function () {}); } catch (e) {}
      }
      if (keepMode === 'webaudio') releaseWebAudioSession();
      reportState();
      return;
    }
    if (keepMode === 'webaudio') webAudioStart(); else elementStart();
    if (keepState() === 'running') reportState(); else reportSoon();
    lastBeat = Date.now();
    post({ type: 'keepBeat', mode: keepMode, state: keepState() });
  }

  // Every 5 s: repair the keep-alive if iOS quietly stopped it, and while in the background beat to native
  // every 20 s. Native falls back to the audio element when the beats stop, because a frozen page cannot
  // tell it anything else.
  setInterval(function () {
    if (!keepOn) return;
    repair();
    if (!appActive && Date.now() - lastBeat >= 20000) {
      lastBeat = Date.now();
      post({ type: 'keepBeat', mode: keepMode, state: keepState() });
    }
  }, 5000);

  // ---- API used from Swift --------------------------------------------------------
  window.__dw = {
    setAppActive: setAppActive,
    keepAlive: keepAlive,
    keepAliveState: function () { return { mode: keepMode, state: keepState() }; },
    notificationClicked: function (id) {
      var n = live[id];
      window.focus();
      if (n) n._fire('click');
    }
  };
  // Every new document (including reloads while in the background) asks native for the app state.
  post({ type: 'ready' });
})();
