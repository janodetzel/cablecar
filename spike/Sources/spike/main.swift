// Throwaway spike for ADR-001 (see docs/design.md, "Spike").
// Answers, against a real iPhone over USB:
//   1. Do highFramerate / timeLapse / sidecarFiles carry real values for iPhone media?
//   2. Does unsandboxed ImageCaptureCore trigger any TCC prompt? (observe while running)
//   3. How does an iCloud-offloaded (thumbnail-only) item present itself?
// Read-only: opens a session and lists the catalog. Never writes to or deletes from the device.

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

final class Spike: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            log("Timed out after 300s without a complete content catalog.")
            exit(2)
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
        if let error { log("didOpenSession ERROR: \(error)"); exit(1) }
        log("Session open.")
        guard let cam = camera else { return }
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
        log("Complete content catalog ready.")
        dumpCatalog(device)
        device.requestCloseSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
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
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log("Access restriction ENABLED (phone locked?).")
    }

    // MARK: Catalog dump

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

        print("\n-- Sample (first 25 files) --")
        for f in files.prefix(25) {
            let name = f.originalFilename ?? f.name ?? "?"
            let date = f.exifCreationDate ?? f.fileCreationDate
            let sidecars = (f.sidecarFiles ?? []).compactMap { $0.name }
            var line = "  \(name)  \(f.uti ?? "?")  \(fmtSize(f.fileSize))"
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
        let movBases = Set(files.filter { ($0.uti ?? "").contains("movie") || name(of: $0).hasSuffix(".MOV") }
            .map { baseName(name(of: $0)) })
        let pairedStills = files.filter {
            let n = name(of: $0)
            return (n.hasSuffix(".HEIC") || n.hasSuffix(".JPG")) && movBases.contains(baseName(n))
        }
        print("  stills sharing a basename with a .MOV: \(pairedStills.count)")
        print("  (if sidecarFiles above were empty but this count is high, Live Photo pairing is by basename, not sidecar)\n")
    }

    private func name(of f: ICCameraFile) -> String { f.originalFilename ?? f.name ?? "?" }
    private func baseName(_ n: String) -> String { (n as NSString).deletingPathExtension }
}

let spike = Spike()
spike.start()
RunLoop.main.run()
