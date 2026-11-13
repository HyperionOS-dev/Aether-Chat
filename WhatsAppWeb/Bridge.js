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
  // Native paints the strips above and below the web view with the page's edge colors. Element hit testing
  // and getComputedStyle both force style recalc, so this is no longer a 1 s timer: Layout.js calls
  // refreshEdges() on a debounce when something actually changed, and resize/visibility cover the rest.
  function bgAt(x, y) {
    var el = document.elementFromPoint(x, y);
    for (; el && el !== document.documentElement; el = el.parentElement) {
      var c = getComputedStyle(el).backgroundColor;
      if (c && c !== 'transparent' && !/,\s*0\)$/.test(c)) return c;
    }
    return getComputedStyle(document.body || document.documentElement).backgroundColor;
  }
  var lastEdges = '';
  function refreshEdges() {
    if (!document.body || document.hidden) return;
    var top = bgAt(window.innerWidth / 2, 2), bottom = bgAt(window.innerWidth / 2, window.innerHeight - 2);
    if (top + bottom !== lastEdges) { lastEdges = top + bottom; post({ type: 'edges', top: top, bottom: bottom }); }
  }
  window.addEventListener('resize', function () { setTimeout(refreshEdges, 300); }, { passive: true });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) setTimeout(refreshEdges, 300);
  }, { passive: true });

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
  // Called by Layout.js on the same debounce as the edge colors (it already knows when the page changed),
  // instead of a 2 s poll that ran querySelectors forever.
  function refreshOpenChat() {
    var name = currentChatTitle();
    if (name === openChat) return;
    openChat = name;
    post({ type: 'openChat', title: name });
  }

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

  // ---- Turbo: media the page is not looking at ----------------------------------------
  // Offscreen videos and stickers keep decoding and animating (CPU, GPU, battery) with nobody watching, and
  // every new message adds more of them. Only elements well outside the viewport are touched, and a video
  // the page started is resumed when it scrolls back in. Off by default for old messages already on screen.
  function turboMedia() {
    function turboOn() { return document.documentElement.classList.contains('wam-turbo'); }
    var io = null;
    try {
      io = new IntersectionObserver(function (entries) {
        for (var i = 0; i < entries.length; i++) {
          var v = entries[i].target;
          if (v.tagName !== 'VIDEO') continue;
          if (entries[i].isIntersecting) {
            if (v.__dwPaused) {
              v.__dwPaused = false;
              try { var p = v.play(); if (p && p.catch) p.catch(function () {}); } catch (e) {}
            }
          } else if (!v.paused) {
            v.__dwPaused = true;
            try { v.pause(); } catch (e) {}
          }
        }
      }, { rootMargin: '300px 0px' });
    } catch (e) { return; }
    function consider(el) {
      if (!el || el.nodeType !== 1 || el.__dwMedia) return;
      if (el.tagName === 'VIDEO') {
        el.__dwMedia = true;
        if (!el.hasAttribute('preload')) el.setAttribute('preload', 'none');   // no speculative download
        try { io.observe(el); } catch (e) {}
      } else if (el.tagName === 'IMG') {
        el.__dwMedia = true;
        if (el.decoding !== 'async') el.decoding = 'async';                    // decode off the main thread
        if (!el.hasAttribute('loading')) el.setAttribute('loading', 'lazy');   // offscreen images wait
        considerFreeze(el);
      }
    }

    // Stickers are animated WebP images, and an <img> decodes a new frame for as long as it is on screen, so a
    // chat full of them is a permanent CPU and battery cost. Only genuinely animated media is touched: the
    // blob header says so (an animated WebP carries an ANIM chunk), which keeps photos and thumbnails
    // completely untouched. A tainted canvas means a remote image, and that one is left alone too.
    var frozen = 0;
    function freeze(img) {
      if (frozen++ >= 200) return;
      try {
        var canvas = document.createElement('canvas');
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        canvas.getContext('2d').drawImage(img, 0, 0);
        var still = canvas.toDataURL('image/webp', 0.92);
        if (still && still.length > 32) { img.srcset = ''; img.src = still; }
      } catch (e) {}   // tainted canvas: the image stays as it is
    }
    function considerFreeze(img) {
      if (frozen >= 200 || !turboOn()) return;
      // Only the conversation: the chat list never shows stickers, so there is nothing to walk there.
      var main = document.getElementById('main');
      if (!main || !main.contains(img)) return;
      var src = img.getAttribute('src') || '';
      if (!/^blob:/i.test(src)) return;             // decrypted in the page; a remote URL cannot be read back
      if (!img.complete || !img.naturalWidth) {
        img.addEventListener('load', function () { considerFreeze(img); }, { once: true });
        return;
      }
      if (img.naturalWidth > 512 || img.naturalHeight > 512) return;   // stickers and icons, not photos
      try {
        fetch(src).then(function (r) { return r.arrayBuffer(); }).then(function (buf) {
          var bytes = new Uint8Array(buf, 0, Math.min(buf.byteLength, 64)), head = '';
          for (var i = 0; i < bytes.length; i++) head += String.fromCharCode(bytes[i]);
          if (head.indexOf('ANIM') >= 0) freeze(img);
        }).catch(function () {});
      } catch (e) {}
    }
    function scan(node) {
      if (!node || node.nodeType !== 1) return;
      consider(node);
      var found = node.querySelectorAll ? node.querySelectorAll('video, img') : [];
      for (var i = 0; i < found.length; i++) consider(found[i]);
    }
    scan(document.body);
    try {
      // Only walks what was added, so it stays cheap even while WhatsApp churns through messages.
      new MutationObserver(function (records) {
        if (!turboOn()) return;
        for (var i = 0; i < records.length; i++) {
          var added = records[i].addedNodes;
          for (var j = 0; j < added.length; j++) scan(added[j]);
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
  }

  // ---- Performance sample (shake menu) ------------------------------------------------
  // What the page itself can see: frames per second, how many frames were slow, and long tasks that blocked
  // the main thread. Native adds memory, main-thread stalls and the launch-to-chat-list time on top.
  function measure(ms, done) {
    var frames = 0, slow = 0, worst = 0, start = 0, last = 0, raf = 0, longTasks = 0, obs = null;
    try {
      if (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes &&
          PerformanceObserver.supportedEntryTypes.indexOf('longtask') >= 0) {
        obs = new PerformanceObserver(function (list) { longTasks += list.getEntries().length; });
        obs.observe({ entryTypes: ['longtask'] });
      }
    } catch (e) { obs = null; }
    function finish(elapsed) {
      if (obs) { try { obs.disconnect(); } catch (e) {} }
      done({ fps: elapsed > 0 ? Math.round(frames * 1000 / elapsed) : 0, frames: frames,
             slowFrames: slow, worstFrameMs: Math.round(worst), longTasks: longTasks });
    }
    function step(t) {
      if (!start) { start = last = t; }
      var d = t - last;
      last = t;
      frames++;
      if (d > 32) slow++;      // longer than two 60 Hz refreshes: a visible hitch
      if (d > worst) worst = d;
      if (t - start < ms) raf = requestAnimationFrame(step);
      else finish(t - start);
    }
    raf = requestAnimationFrame(step);
  }

  // ---- API used from Swift --------------------------------------------------------
  window.__dw = {
    setAppActive: setAppActive,
    keepAlive: keepAlive,
    keepAliveState: function () { return { mode: keepMode, state: keepState() }; },
    refreshEdges: refreshEdges,
    refreshOpenChat: refreshOpenChat,
    measure: function (ms) {
      measure(ms || 3000, function (result) {
        result.type = 'perf';
        result.turbo = document.documentElement.classList.contains('wam-turbo');
        post(result);
      });
    },
    notificationClicked: function (id) {
      var n = live[id];
      window.focus();
      if (n) n._fire('click');
    }
  };
  turboMedia();

  // Every new document (including reloads while in the background) asks native for the app state.
  post({ type: 'ready' });
})();
