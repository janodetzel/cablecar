// Throwaway spike for ADR-001 (see docs/design.md, "Spike").
// Phase 1: list the catalog and probe lock/TCC/offload behavior.
// Phase 2: download ONE recent video, verify byte size, and read codec + color
//          tags via AVFoundation (Rec.2100 HLG check without Resolve).
// Read-only toward the phone: downloading copies a file, never modifies or deletes.

import AVFoundation
import Foundation
import ImageCaptureCore

let startTime = Date()

func log(_ s: String) {
    let t = String(format: "%7.2fs", Date().timeIntervalSince(startTime))
    print("[\(t)] \(s)")
}

func fmtSize(_ bytes: off_t) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
}

final class Spike: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    var sessionOpen = false
    var catalogDone = false
    var downloadTarget: ICCameraFile?
    let downloadDir = URL(fileURLWithPath: "spike-downloads", isDirectory: true)

    func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let cam = self.camera, !self.sessionOpen else { return }
            log("Retrying session open… (isAccessRestrictedAppleDevice: \(cam.isAccessRestrictedAppleDevice))")
            cam.requestOpenSession()
        }
    }

    func start() {
        log("Cablecar spike starting. Watch for any TCC/permission prompt now (fact #2).")
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        browser.start()
        log("Browsing for local cameras. Plug in the iPhone, unlock it, tap Trust if asked.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.camera == nil {
                log("No camera device after 15s. Still waiting (Ctrl-C to abort)…")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            if self?.catalogDone != true {
                log("Timed out after 300s without a complete content catalog.")
                exit(2)
            }
        }
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else {
            log("Ignoring non-camera device: \(device.name ?? "?")")
            return
        }
        guard camera == nil else {
            log("Ignoring additional camera: \(cam.name ?? "?")")
            return
        }
        camera = cam
        log("Camera found: \(cam.name ?? "?")")
        log("  capabilities: \(cam.capabilities)")
        log("  isAccessRestrictedAppleDevice: \(cam.isAccessRestrictedAppleDevice) (true = locked/untrusted)")
        cam.delegate = self
        log("Opening session…")
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        log("Device removed: \(device.name ?? "?")")
        if device === camera {
            log("Our camera disappeared; exiting.")
            exit(1)
        }
    }

    // MARK: ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            let code = (error as NSError).code
            log("didOpenSession error (code \(code)): \(error.localizedDescription)")
            log("Waiting for unlock/trust — will retry when the access restriction lifts (and every 10s as fallback). Unlock the phone with the cable connected; re-plug if no Trust prompt appears.")
            scheduleRetry()
            return
        }
        sessionOpen = true
        log("Session open.")
        guard let cam = camera else { return }
        log("  capabilities now: \(cam.capabilities)")
        if cam.capabilities.contains(ICDeviceCapability.cameraDeviceSupportsHEIF.rawValue) {
            cam.mediaPresentation = .originalAssets
            log("mediaPresentation set to .originalAssets (device supports HEIF).")
        } else {
            log("NOTE: device does not report SupportsHEIF; mediaPresentation left at default \(cam.mediaPresentation.rawValue).")
        }
        log("Waiting for complete content catalog…")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        log("Session closed\(error.map { " with error: \($0)" } ?? ".")")
    }

    func didRemove(_ device: ICDevice) {}

    // MARK: ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard !catalogDone else { return }
        catalogDone = true
        log("Complete content catalog ready.")
        dumpCatalog(device)
        startDownloadTest(device)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        log("Capability changed. isAccessRestrictedAppleDevice: \(camera.isAccessRestrictedAppleDevice)")
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log("Access restriction removed (phone unlocked/trusted).")
        if let cam = camera, !sessionOpen {
            log("Reopening session…")
            cam.requestOpenSession()
        }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log("Access restriction ENABLED (phone locked?).")
    }

    // MARK: Phase 1 — catalog dump

    func dumpCatalog(_ device: ICCameraDevice) {
        let files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        print("\n===== CATALOG: \(files.count) media files =====\n")

        var utiCounts: [String: Int] = [:]
        var flagged: [String] = []
        var zeroOrTiny: [String] = []

        for f in files {
            let name = f.originalFilename ?? f.name ?? "?"
            let uti = f.uti ?? "?"
            utiCounts[uti, default: 0] += 1
            if f.highFramerate { flagged.append("\(name): highFramerate") }
            if f.timeLapse { flagged.append("\(name): timeLapse") }
            if f.fileSize < 100_000 { zeroOrTiny.append("\(name) (\(fmtSize(f.fileSize)), \(uti))") }
        }

        print("-- Counts by UTI --")
        for (uti, n) in utiCounts.sorted(by: { $0.value > $1.value }) {
            print("  \(uti): \(n)")
        }

        print("\n-- Counts by extension --")
        var extCounts: [String: Int] = [:]
        for f in files {
            extCounts[(name(of: f) as NSString).pathExtension.uppercased(), default: 0] += 1
        }
        for (ext, n) in extCounts.sorted(by: { $0.value > $1.value }) {
            print("  \(ext.isEmpty ? "(none)" : ext): \(n)")
        }

        print("\n-- Sample (first 25 files) --")
        for f in files.prefix(25) {
            let date = f.exifCreationDate ?? f.fileCreationDate
            let sidecars = (f.sidecarFiles ?? []).compactMap { $0.name }
            var line = "  \(name(of: f))  \(f.uti ?? "?")  \(fmtSize(f.fileSize))"
            line += "  created=\(date.map { "\($0)" } ?? "nil")"
            if f.duration > 0 { line += String(format: "  dur=%.1fs", f.duration) }
            if f.highFramerate { line += "  [SLOWMO]" }
            if f.timeLapse { line += "  [TIMELAPSE]" }
            if let burst = f.burstUUID { line += "  burst=\(burst.prefix(8))" }
            if !sidecars.isEmpty { line += "  sidecars=\(sidecars)" }
            print(line)
        }

        print("\n-- Slow-mo / time-lapse flags (fact #1) --")
        print(flagged.isEmpty ? "  none flagged — check whether the roll has any, or the flags don't survive PTP"
                              : flagged.joined(separator: "\n"))

        print("\n-- Files under 100 KB (fact #3: iCloud-offloaded candidates) --")
        print(zeroOrTiny.isEmpty ? "  none — either nothing is offloaded, or offloaded items are hidden entirely"
                                 : zeroOrTiny.joined(separator: "\n"))
        print("\nCompare the catalog count (\(files.count)) with the Photos app 'on this iPhone' count:")
        print("if Photos shows more items than the catalog, offloaded items are HIDDEN over USB")
        print("rather than presented as small files. Either way v1 needs a detection story.\n")

        print("-- Live Photo pairing check --")
        let movBases = Set(files.filter { name(of: $0).uppercased().hasSuffix(".MOV") }
            .map { baseName(name(of: $0)) })
        let pairedStills = files.filter {
            let n = name(of: $0).uppercased()
            return (n.hasSuffix(".HEIC") || n.hasSuffix(".JPG")) && movBases.contains(baseName(name(of: $0)))
        }
        print("  stills sharing a basename with a .MOV: \(pairedStills.count)")
        print("  (sidecarFiles is the authoritative pairing; this is the fallback heuristic)\n")
    }

    // MARK: Phase 2 — download one video and verify

    func startDownloadTest(_ device: ICCameraDevice) {
        let files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        func date(_ f: ICCameraFile) -> Date { f.exifCreationDate ?? f.fileCreationDate ?? .distantPast }
        let videos = files
            .filter { name(of: $0).uppercased().hasSuffix(".MOV") && $0.fileSize > 1_000_000 }
            .sorted { date($0) > date($1) }
        // Camera-captured clips (IMG_*.MOV) are the ones that should be HEVC/HDR;
        // UUID-named clips are often saved/shared media that was born H.264.
        let cameraClips = videos.filter { name(of: $0).uppercased().hasPrefix("IMG_") }
        let pool = cameraClips.isEmpty ? videos : cameraClips
        // Most recent under 100 MB keeps the test quick; fall back to the newest one.
        guard let target = pool.first(where: { $0.fileSize < 100_000_000 }) ?? pool.first else {
            log("No .MOV found to download-test; closing.")
            finish(device)
            return
        }
        downloadTarget = target
        log("  target identity: name=\(target.name ?? "nil") originalFilename=\(target.originalFilename ?? "nil") createdFilename=\(target.createdFilename ?? "nil")")
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        log("PHASE 2: downloading \(name(of: target)) (\(fmtSize(target.fileSize))) to \(downloadDir.path)/ …")
        device.requestDownloadFile(
            target,
            options: [.downloadsDirectoryURL: downloadDir, .overwrite: true],
            downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            log("Download test timed out after 300s.")
            exit(3)
        }
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        if let error {
            log("Download ERROR: \(error)")
            if let cam = camera { finish(cam) }
            return
        }
        let savedName = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? name(of: file)
        let url = downloadDir.appendingPathComponent(savedName)
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        log("Downloaded: \(savedName)")
        log("  size on phone: \(file.fileSize) bytes, on disk: \(onDisk ?? -1) bytes → \(Int64(file.fileSize) == onDisk ? "MATCH ✅" : "MISMATCH ❌")")
        Task {
            await analyze(url)
            if let cam = self.camera { self.finish(cam) }
        }
    }

    func analyze(_ url: URL) async {
        log("AVFoundation analysis of \(url.lastPathComponent):")
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            for track in tracks where track.mediaType == .video {
                let descs = try await track.load(.formatDescriptions)
                for desc in descs {
                    let codec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let primaries = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String ?? "?"
                    let transfer = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? "?"
                    let matrix = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String ?? "?"
                    log("  video track: codec=\(codec) \(dims.width)x\(dims.height)")
                    log("    colorPrimaries=\(primaries)")
                    log("    transferFunction=\(transfer)  ← 'ITU_R_2100_HLG' means HDR intact (fact for acceptance criterion)")
                    log("    yCbCrMatrix=\(matrix)")
                    log("  VERDICT: codec \(codec == "hvc1" || codec == "hev1" ? "is HEVC ✅" : "is NOT HEVC (\(codec)) — check mediaPresentation/Keep Originals ❌")")
                }
            }
        } catch {
            log("  AVFoundation analysis failed: \(error)")
        }
    }

    func finish(_ device: ICCameraDevice) {
        device.requestCloseSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    private func name(of f: ICCameraFile) -> String { f.originalFilename ?? f.name ?? "?" }
    private func baseName(_ n: String) -> String { (n as NSString).deletingPathExtension }
}

let spike = Spike()
spike.start()
RunLoop.main.run()
