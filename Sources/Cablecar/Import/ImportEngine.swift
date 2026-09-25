import Foundation
import Observation

struct ImportSummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let filename: String
        let reason: String
    }

    var imported = 0
    var skippedExisting = 0
    var skippedNotOnDevice = 0
    var failures: [Failure] = []
    var cancelled = false
}

/// Runs an import: plan → download each file with a `.partial` suffix → verify
/// byte size against the phone-reported size → rename into place. Files are
/// copied one at a time (PTP is effectively serial anyway), which keeps
/// progress and cancellation simple.
@MainActor
@Observable
final class ImportEngine {
    private(set) var isRunning = false
    private(set) var currentFilename: String?
    private(set) var completedFiles = 0
    private(set) var totalFiles = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var currentFileBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0

    private var cancelRequested = false
    private weak var activeSource: (any MediaSource)?

    var overallProgress: Double {
        totalBytes > 0 ? Double(completedBytes + currentFileBytes) / Double(totalBytes) : 0
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        activeSource?.cancelActiveDownload()
    }

    func run(items: [MediaItem], from source: any MediaSource, into destination: URL) async -> ImportSummary {
        precondition(!isRunning, "ImportEngine.run is not reentrant")
        isRunning = true
        cancelRequested = false
        activeSource = source
        defer {
            isRunning = false
            activeSource = nil
            currentFilename = nil
        }

        let fm = FileManager.default
        var summary = ImportSummary()
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            summary.failures.append(.init(
                filename: destination.lastPathComponent,
                reason: "Could not create the destination folder: \(error.localizedDescription)"
            ))
            return summary
        }

        let existing = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
        let plan = ImportPlanner.makePlan(items: items, existingFilenames: existing)
        summary.skippedExisting = plan.skippedExisting
        summary.skippedNotOnDevice = plan.skippedNotOnDevice

        totalFiles = plan.files.count
        completedFiles = 0
        totalBytes = plan.totalBytes
        completedBytes = 0
        currentFileBytes = 0

        for planned in plan.files {
            if cancelRequested { summary.cancelled = true; break }
            currentFilename = planned.filename

            let partialName = planned.filename + ImportPlanner.partialSuffix
            do {
                let partialURL = try await source.downloadFile(
                    planned.fileID, to: destination, saveAs: partialName
                ) { [weak self] downloaded, _ in
                    self?.currentFileBytes = downloaded
                }

                let onDisk = ((try? fm.attributesOfItem(atPath: partialURL.path)[.size]) as? Int64) ?? -1
                if onDisk != planned.expectedSize {
                    // Leave the .partial in place for inspection (design.md).
                    summary.failures.append(.init(
                        filename: planned.filename,
                        reason: "Size mismatch: phone reports \(planned.expectedSize) bytes, copy has \(onDisk). Kept as \(partialURL.lastPathComponent)."
                    ))
                } else {
                    let finalURL = destination.appendingPathComponent(planned.filename)
                    if fm.fileExists(atPath: finalURL.path) {
                        // Appeared mid-run; the existing file wins.
                        try? fm.removeItem(at: partialURL)
                        summary.skippedExisting += 1
                    } else {
                        try fm.moveItem(at: partialURL, to: finalURL)
                        summary.imported += 1
                    }
                }
            } catch is CancellationError {
                try? fm.removeItem(at: destination.appendingPathComponent(partialName))
                summary.cancelled = true
                break
            } catch {
                summary.failures.append(.init(filename: planned.filename, reason: error.localizedDescription))
                if error as? MediaSourceError == .deviceDisconnected { break }
            }

            completedFiles += 1
            completedBytes += planned.expectedSize
            currentFileBytes = 0
        }
        return summary
    }
}

extension MediaSourceError: Equatable {
    static func == (lhs: MediaSourceError, rhs: MediaSourceError) -> Bool {
        switch (lhs, rhs) {
        case (.deviceNotReady, .deviceNotReady),
             (.downloadAlreadyInFlight, .downloadAlreadyInFlight),
             (.deviceDisconnected, .deviceDisconnected):
            return true
        case (.fileNotAvailable(let a), .fileNotAvailable(let b)):
            return a == b
        default:
            return false
        }
    }
}
