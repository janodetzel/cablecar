import CoreGraphics
import Foundation

/// Connection state of a media source, in UI-facing terms.
enum SourceState: Equatable {
    case waitingForDevice
    case connecting(deviceName: String)
    /// The phone is locked or not yet trusted. ImageCaptureCore evaluates lock
    /// state at connect time; the source retries automatically once the
    /// restriction lifts (spike finding: error -9943, then
    /// `cameraDeviceDidRemoveAccessRestriction` ~0.2 s after unlock).
    case locked(deviceName: String)
    case loadingCatalog(deviceName: String)
    case ready(deviceName: String)
    case failed(deviceName: String, message: String)
}

@MainActor
protocol MediaSourceDelegate: AnyObject {
    func mediaSourceDidChangeState(_ source: any MediaSource)
    func mediaSourceDidUpdateItems(_ source: any MediaSource)
    func mediaSource(_ source: any MediaSource, didLoadThumbnail thumbnail: CGImage?, for itemID: MediaItem.ID)
}

/// Abstraction over where media comes from (ADR-001). v1 ships only
/// `USBMediaSource`; a PhotoKit/iCloud source slots in behind the same
/// protocol later. Implementations are strictly read-only toward the device:
/// nothing here can delete or modify anything on the phone.
@MainActor
protocol MediaSource: AnyObject {
    var delegate: (any MediaSourceDelegate)? { get set }
    var state: SourceState { get }
    var items: [MediaItem] { get }
    /// One-line caveat shown in the UI (e.g. what this source cannot reach).
    var limitationsNote: String { get }

    func start()
    func stop()

    func requestThumbnail(for itemID: MediaItem.ID)

    /// Copies one file (an item or one of its sidecars, addressed by id) into
    /// `directory` under exactly `filename`. Reports (downloadedBytes,
    /// totalBytes) via `progress`. Returns the URL the file was saved at.
    /// Serial: at most one download may be in flight per source.
    func downloadFile(
        _ fileID: String,
        to directory: URL,
        saveAs filename: String,
        progress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws -> URL

    func cancelActiveDownload()
}

enum MediaSourceError: LocalizedError {
    case fileNotAvailable(String)
    case deviceNotReady
    case downloadAlreadyInFlight
    case deviceDisconnected

    var errorDescription: String? {
        switch self {
        case .fileNotAvailable(let name): return "\(name) is no longer available on the device."
        case .deviceNotReady: return "The device is not connected and ready."
        case .downloadAlreadyInFlight: return "Another download is already in progress."
        case .deviceDisconnected: return "The device was disconnected."
        }
    }
}
