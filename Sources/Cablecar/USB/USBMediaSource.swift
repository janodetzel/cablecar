import CoreGraphics
import Foundation
import ImageCaptureCore

/// The v1 media source: USB camera-roll access via ImageCaptureCore (ADR-001).
///
/// Strictly read-only toward the phone: this type only browses, reads
/// thumbnails, and downloads copies. It never calls any delete or write API —
/// an unconditional constraint, not a v1 deferral.
///
/// ImageCaptureCore delivers delegate callbacks on the runloop of the thread
/// that started the browser (main, here); the `onMain` hop makes that explicit
/// and tolerant of the framework using another thread.
@MainActor
final class USBMediaSource: NSObject, MediaSource {
    weak var delegate: (any MediaSourceDelegate)?

    private(set) var state: SourceState = .waitingForDevice {
        didSet { if state != oldValue { delegate?.mediaSourceDidChangeState(self) } }
    }
    private(set) var items: [MediaItem] = []

    let limitationsNote =
        "USB shows the camera roll only: albums and iCloud-only originals aren’t reachable over the cable. The phone is never modified."

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var sessionOpen = false
    private var catalogReady = false

    /// Every downloadable file (items and their sidecars) by our stable id.
    private var filesByID: [String: ICCameraFile] = [:]
    /// Reverse lookup for thumbnail callbacks.
    private var idsByObject: [ObjectIdentifier: String] = [:]
    private var thumbnailRequested: Set<String> = []
    private var metadataRequested: Set<String> = []

    private struct ActiveDownload {
        /// Matches the request's `contextInfo` so a late completion of an
        /// already-cancelled download can never resume a newer request's
        /// continuation (the framework delivers -9937 asynchronously after
        /// `cancelDownload`, by which time the next download may be active).
        let token: Int
        let file: ICCameraFile
        let directory: URL
        let continuation: CheckedContinuation<URL, Error>
        let progress: @MainActor (Int64, Int64) -> Void
    }
    private var activeDownload: ActiveDownload?
    private var nextDownloadToken = 1

    private var deviceName: String { camera?.name ?? "iPhone" }

    // MARK: - MediaSource

    func start() {
        browser.delegate = self
        // Same mask construction the spike validated on hardware.
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        browser.start()
    }

    func stop() {
        camera?.requestCloseSession()
        browser.stop()
    }

    func requestThumbnail(for itemID: MediaItem.ID) {
        guard let file = filesByID[itemID], !thumbnailRequested.contains(itemID) else { return }
        thumbnailRequested.insert(itemID)
        file.requestThumbnail()
    }

    func requestMetadata(for itemID: MediaItem.ID) {
        guard let file = filesByID[itemID], !metadataRequested.contains(itemID) else { return }
        metadataRequested.insert(itemID)
        file.requestMetadata()
    }

    func downloadFile(
        _ fileID: String,
        to directory: URL,
        saveAs filename: String,
        progress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws -> URL {
        guard activeDownload == nil else { throw MediaSourceError.downloadAlreadyInFlight }
        guard let camera, sessionOpen else { throw MediaSourceError.deviceNotReady }
        guard let file = filesByID[fileID] else { throw MediaSourceError.fileNotAvailable(filename) }

        let token = nextDownloadToken
        nextDownloadToken += 1
        return try await withCheckedThrowingContinuation { continuation in
            activeDownload = ActiveDownload(
                token: token, file: file, directory: directory, continuation: continuation, progress: progress
            )
            camera.requestDownloadFile(
                file,
                options: [
                    .downloadsDirectoryURL: URL(fileURLWithPath: directory.path, isDirectory: true),
                    .saveAsFilename: filename,
                    .overwrite: true,
                ],
                downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: UnsafeMutableRawPointer(bitPattern: token)
            )
        }
    }

    func cancelActiveDownload() {
        guard let download = takeActiveDownload() else { return }
        camera?.cancelDownload()
        download.continuation.resume(throwing: CancellationError())
    }

    /// Single point that hands out the in-flight download, guaranteeing its
    /// continuation is resumed exactly once.
    private func takeActiveDownload() -> ActiveDownload? {
        defer { activeDownload = nil }
        return activeDownload
    }

    // MARK: - Download callbacks (see ICCameraDeviceDownloadDelegate extension)

    @objc nonisolated func didDownloadFile(
        _ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?
    ) {
        onMain { [self] in
            // Ignore late completions of cancelled downloads: only the
            // callback carrying the active request's token may resume it.
            guard let download = activeDownload, download.token == Int(bitPattern: contextInfo) else { return }
            activeDownload = nil
            if let error {
                let code = (error as NSError).code
                // ICReturnDownloadCanceled — surface as a cancellation, not a failure.
                download.continuation.resume(throwing: code == -9937 ? CancellationError() : error)
                return
            }
            // The framework reports the name it actually saved under; trust it
            // over the name we asked for.
            let savedName = (options[ICDownloadOption.savedFilename.rawValue] as? String)
                ?? (options[ICDownloadOption.saveAsFilename.rawValue] as? String)
                ?? file.name
                ?? "?"
            download.continuation.resume(returning: download.directory.appendingPathComponent(savedName))
        }
    }

    @objc nonisolated func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: off_t, maxBytes: off_t) {
        onMain { [self] in
            guard let download = activeDownload, download.file === file else { return }
            download.progress(Int64(downloadedBytes), Int64(maxBytes))
        }
    }

    // MARK: - Catalog → MediaItem mapping

    private func rebuildItems() {
        guard let camera else { return }
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }

        filesByID = [:]
        idsByObject = [:]

        // Assign stable, unique ids to every file (items and sidecars alike).
        for file in files {
            register(file)
        }

        // A Live Photo's .MOV appears both as the still's sidecar and as its
        // own top-level entry; hide the top-level duplicate so the grid shows
        // the Live Photo once.
        var consumedAsSidecar: Set<ObjectIdentifier> = []
        for file in files {
            for sidecar in usableSidecars(of: file) {
                register(sidecar)
                consumedAsSidecar.insert(ObjectIdentifier(sidecar))
            }
        }

        items = files
            .filter { !consumedAsSidecar.contains(ObjectIdentifier($0)) }
            .map { mediaItem(for: $0) }
        delegate?.mediaSourceDidUpdateItems(self)
    }

    /// Sidecars we import alongside an item: currently the Live Photo video.
    /// `.AAE` edit recipes also show up as sidecars but are skipped — they are
    /// useless without the Photos library (design.md leaves this open; revisit
    /// if edited-photo recipes turn out to matter).
    private func usableSidecars(of file: ICCameraFile) -> [ICCameraFile] {
        (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }.filter {
            displayName(of: $0).uppercased().hasSuffix(".MOV")
        }
    }

    private func mediaItem(for file: ICCameraFile) -> MediaItem {
        let name = displayName(of: file)
        let sidecars = usableSidecars(of: file).map {
            MediaItem.Sidecar(id: id(of: $0), filename: displayName(of: $0), sizeBytes: Int64($0.fileSize))
        }
        let kind = MediaKindClassifier.classify(
            filename: name,
            duration: file.duration > 0 ? file.duration : nil,
            isHighFramerate: file.highFramerate,
            isTimeLapse: file.timeLapse,
            hasVideoSidecar: !sidecars.isEmpty
        )
        let displaySize = ExifDimensionMapper.displaySize(
            width: file.width, height: file.height, exifOrientation: Int(file.orientation.rawValue)
        )
        return MediaItem(
            id: id(of: file),
            displayName: name,
            kind: kind,
            sizeBytes: Int64(file.fileSize),
            creationDate: file.exifCreationDate ?? file.fileCreationDate,
            duration: file.duration > 0 ? file.duration : nil,
            isOnDevice: OffloadHeuristic.isOnDevice(sizeBytes: Int64(file.fileSize)),
            sidecars: sidecars,
            pixelWidth: displaySize.width,
            pixelHeight: displaySize.height
        )
    }

    private func register(_ file: ICCameraFile) {
        let object = ObjectIdentifier(file)
        if idsByObject[object] != nil { return }
        var candidate = id(of: file)
        // Guard against pathological id collisions (no fingerprint and
        // identical name+size+date) by suffixing.
        var n = 1
        while filesByID[candidate] != nil {
            n += 1
            candidate = "\(id(of: file))#\(n)"
        }
        filesByID[candidate] = file
        idsByObject[object] = candidate
    }

    private func id(of file: ICCameraFile) -> String {
        if let registered = idsByObject[ObjectIdentifier(file)] { return registered }
        if let fingerprint = file.fingerprint, !fingerprint.isEmpty { return fingerprint }
        let stamp = (file.exifCreationDate ?? file.fileCreationDate)?.timeIntervalSince1970 ?? 0
        return "\(displayName(of: file))|\(file.fileSize)|\(stamp)"
    }

    private func displayName(of file: ICCameraFile) -> String {
        file.originalFilename ?? file.name ?? "unknown"
    }
}

/// Detection of iCloud-offloaded (thumbnail-only) items. The spike left this
/// partially open: offloaded items either hide entirely over USB or present as
/// tiny stub files. Zero-byte entries are definitely not on the device;
/// anything else is treated as importable, and the engine's byte-size
/// verification catches a stub that slips through. Tune here once the
/// on-device-count comparison from design.md is done.
enum OffloadHeuristic {
    static func isOnDevice(sizeBytes: Int64) -> Bool { sizeBytes > 0 }
}

// MARK: - ICCameraDeviceDownloadDelegate

// The callback methods live in the main class body (the @objc selector is
// referenced there); this extension just declares the conformance.
extension USBMediaSource: ICCameraDeviceDownloadDelegate {}

// MARK: - ICDeviceBrowserDelegate

extension USBMediaSource: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        onMain { [self] in
            guard let cam = device as? ICCameraDevice, camera == nil else { return }
            camera = cam
            cam.delegate = self
            state = .connecting(deviceName: deviceName)
            cam.requestOpenSession()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        onMain { [self] in
            guard device === camera else { return }
            if let download = takeActiveDownload() {
                download.continuation.resume(throwing: MediaSourceError.deviceDisconnected)
            }
            camera = nil
            sessionOpen = false
            catalogReady = false
            filesByID = [:]
            idsByObject = [:]
            thumbnailRequested = []
            metadataRequested = []
            items = []
            delegate?.mediaSourceDidUpdateItems(self)
            state = .waitingForDevice
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension USBMediaSource: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        onMain { [self] in
            if let error {
                // -9943: locked / not yet trusted. The restriction lifts
                // asynchronously; we retry on the restriction-removed callback
                // and every 10 s as a fallback (both spike-verified).
                if (error as NSError).code == -9943 {
                    state = .locked(deviceName: deviceName)
                } else {
                    state = .failed(deviceName: deviceName, message: error.localizedDescription)
                }
                scheduleSessionRetry()
                return
            }
            sessionOpen = true
            state = .loadingCatalog(deviceName: deviceName)
            if let cam = camera,
               cam.capabilities.contains(ICDeviceCapability.cameraDeviceSupportsHEIF.rawValue) {
                // iPhones typically don't report this capability, yet still
                // deliver originals (spike-verified); set it whenever we can.
                cam.mediaPresentation = .originalAssets
            }
        }
    }

    private func scheduleSessionRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let cam = self.camera, !self.sessionOpen else { return }
            cam.requestOpenSession()
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        onMain { [self] in sessionOpen = false }
    }

    nonisolated func didRemove(_ device: ICDevice) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { [self] in
            catalogReady = true
            rebuildItems()
            state = .ready(deviceName: deviceName)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        onMain { [self] in if catalogReady { rebuildItems() } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        onMain { [self] in if catalogReady { rebuildItems() } }
    }

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?
    ) {
        onMain { [self] in
            guard let file = item as? ICCameraFile, let itemID = idsByObject[ObjectIdentifier(file)] else { return }
            if thumbnail == nil { thumbnailRequested.remove(itemID) }  // allow a retry
            delegate?.mediaSource(self, didLoadThumbnail: thumbnail, for: itemID)
        }
    }

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?
    ) {
        onMain { [self] in
            guard let file = item as? ICCameraFile, let itemID = idsByObject[ObjectIdentifier(file)] else { return }
            if metadata == nil { metadataRequested.remove(itemID) }  // allow a retry
            delegate?.mediaSource(self, didLoadMetadata: metadata.map(MetadataFormatter.sections(from:)), for: itemID)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    // Required by the protocol; this app never issues a delete request.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        onMain { [self] in
            guard let cam = camera, !sessionOpen else { return }
            state = .connecting(deviceName: deviceName)
            cam.requestOpenSession()
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        onMain { [self] in
            if !sessionOpen { state = .locked(deviceName: deviceName) }
        }
    }
}

/// Runs `body` on the main actor: immediately when already on the main thread
/// (ImageCaptureCore's normal delivery), otherwise via a hop.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
