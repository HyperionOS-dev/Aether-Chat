import UIKit
import WebKit

/// Saves files the page downloads (media, documents) to a temporary folder,
/// then offers the share sheet so they can be saved to Photos/Files or shared.
/// Each download lives in its own temporary folder, which is removed once the share sheet closes.
final class DownloadManager: NSObject, WKDownloadDelegate {
    weak var presenter: UIViewController?

    private var destinations: [ObjectIdentifier: URL] = [:]

    override init() {
        super.init()
        DownloadManager.sweepStaleFolders()
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        // A fresh folder per download keeps the suggested name and avoids collisions.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        guard let presenter else {
            DownloadManager.removeFolder(of: url)
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        // Runs when the share sheet closes (saved, shared or cancelled): the file is no longer needed.
        sheet.completionWithItemsHandler = { _, _, _, _ in
            DownloadManager.removeFolder(of: url)
        }
        (presenter.presentedViewController ?? presenter).present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            DownloadManager.removeFolder(of: url)
        }
        let alert = UIAlertController(title: "Download failed", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }

    // MARK: - Cleanup

    private static func removeFolder(of file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Removes leftover download folders (UUID-named, older than a day), e.g. from sessions where the
    /// app was killed while a share sheet was open.
    private static func sweepStaleFolders() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: keys) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for item in items where UUID(uuidString: item.lastPathComponent) != nil {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, let modified = values?.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: item)
        }
    }
}
