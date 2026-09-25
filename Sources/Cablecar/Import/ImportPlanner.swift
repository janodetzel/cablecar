import Foundation

/// One file to copy: either an item's main file or one of its sidecars.
struct PlannedFile: Equatable, Sendable {
    let fileID: String
    /// Final on-disk filename (the item's display name — deterministic, never
    /// the device's default saved name).
    let filename: String
    /// Phone-reported byte size; the engine verifies the copy against this.
    let expectedSize: Int64
}

struct ImportPlan: Equatable, Sendable {
    var files: [PlannedFile] = []
    var skippedExisting = 0
    var skippedNotOnDevice = 0

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.expectedSize } }
}

/// Pure planning step of an import, kept free of ImageCaptureCore and the
/// filesystem so it is unit-testable.
enum ImportPlanner {
    /// Suffix for in-flight copies, so an interrupted run never satisfies the
    /// filename match on the next run (docs/design.md).
    static let partialSuffix = ".partial"

    /// - Parameters:
    ///   - items: the user's selection.
    ///   - existingFilenames: shallow listing of the destination folder.
    ///     Matching is case-insensitive (APFS default) and by exact filename.
    static func makePlan(items: [MediaItem], existingFilenames: some Sequence<String>) -> ImportPlan {
        let existing = Set(existingFilenames.map { $0.lowercased() })
        var plan = ImportPlan()
        var planned = Set<String>()

        for item in items {
            // Not-on-device items are unselectable in the UI, but the planner
            // guards anyway so they can never fail silently.
            guard item.isOnDevice else {
                plan.skippedNotOnDevice += 1
                continue
            }
            // Live Photos always import both parts (still + MOV sidecar).
            var files = [(item.id, item.displayName, item.sizeBytes)]
            files += item.sidecars.map { ($0.id, $0.filename, $0.sizeBytes) }

            for (fileID, filename, size) in files {
                let key = filename.lowercased()
                guard !planned.contains(key) else { continue }
                guard !existing.contains(key) else {
                    plan.skippedExisting += 1
                    continue
                }
                planned.insert(key)
                plan.files.append(PlannedFile(fileID: fileID, filename: filename, expectedSize: size))
            }
        }
        return plan
    }
}
