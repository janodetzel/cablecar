import Foundation

/// What a camera-roll item is, derived client-side (extension, duration, PTP
/// flags, sidecars) because `ICCameraFile.uti` is only ever the generic
/// `public.image` / `public.movie` (spike finding, 2026-09-25).
enum MediaKind: String, CaseIterable, Sendable {
    case photo
    case livePhoto
    case video
    case slowMoVideo
    case timeLapseVideo

    var isVideo: Bool {
        switch self {
        case .video, .slowMoVideo, .timeLapseVideo: return true
        case .photo, .livePhoto: return false
        }
    }
}

/// A source-agnostic media item. The UI and import engine only ever see this
/// type — ImageCaptureCore concepts must not leak past `USBMediaSource`
/// (ADR-001 consequence).
struct MediaItem: Identifiable, Hashable, Sendable {
    /// A secondary file that belongs to this item and is always imported with
    /// it — e.g. the .MOV half of a Live Photo.
    struct Sidecar: Hashable, Sendable {
        let id: String
        let filename: String
        let sizeBytes: Int64
    }

    let id: String
    /// Name shown in the UI and used as the on-disk filename. Always pass this
    /// explicitly when saving — the device's default saved name can differ
    /// (spike finding: `6CD21CDD-….MOV` saved as `IUAV5727.MOV`).
    let displayName: String
    let kind: MediaKind
    let sizeBytes: Int64
    let creationDate: Date?
    let duration: TimeInterval?
    /// False for iCloud-offloaded items where the phone holds only a stub.
    /// Such items are greyed out, unselectable, and never imported.
    let isOnDevice: Bool
    let sidecars: [Sidecar]
    /// Display-oriented pixel dimensions (EXIF rotation already applied);
    /// 0 when the source doesn't report them.
    let pixelWidth: Int
    let pixelHeight: Int

    var fileExtension: String { (displayName as NSString).pathExtension.uppercased() }
    var totalSizeBytes: Int64 { sidecars.reduce(sizeBytes) { $0 + $1.sizeBytes } }

    var orientation: MediaOrientation {
        guard pixelWidth > 0, pixelHeight > 0 else { return .unknown }
        if pixelWidth > pixelHeight { return .landscape }
        if pixelWidth < pixelHeight { return .portrait }
        return .square
    }
}

enum MediaOrientation: Sendable {
    case landscape, portrait, square, unknown
}

enum ExifDimensionMapper {
    /// EXIF orientations 5–8 rotate the stored pixels by 90°, so the stored
    /// width/height are swapped relative to how the media is displayed.
    static func displaySize(width: Int, height: Int, exifOrientation: Int) -> (width: Int, height: Int) {
        (5...8).contains(exifOrientation) ? (height, width) : (width, height)
    }
}

enum MediaKindClassifier {
    static let videoExtensions: Set<String> = ["MOV", "MP4", "M4V", "AVI", "3GP"]

    static func classify(
        filename: String,
        duration: TimeInterval?,
        isHighFramerate: Bool,
        isTimeLapse: Bool,
        hasVideoSidecar: Bool
    ) -> MediaKind {
        let ext = (filename as NSString).pathExtension.uppercased()
        if videoExtensions.contains(ext) || (duration ?? 0) > 0 {
            if isHighFramerate { return .slowMoVideo }
            if isTimeLapse { return .timeLapseVideo }
            return .video
        }
        return hasVideoSidecar ? .livePhoto : .photo
    }

    static func isVideoFilename(_ filename: String) -> Bool {
        videoExtensions.contains((filename as NSString).pathExtension.uppercased())
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case slowMo = "Slow-mo"
    case timeLapse = "Time-lapse"
    case livePhotos = "Live Photos"

    var id: String { rawValue }

    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !item.kind.isVideo
        case .videos: return item.kind.isVideo
        case .slowMo: return item.kind == .slowMoVideo
        case .timeLapse: return item.kind == .timeLapseVideo
        case .livePhotos: return item.kind == .livePhoto
        }
    }
}

/// Second, independent filter axis (composes with `MediaFilter`), so e.g.
/// "Videos + Landscape" works. Square and unknown-size items only appear
/// under "Any".
enum OrientationFilter: String, CaseIterable, Identifiable {
    case any = "Any Orientation"
    case landscape = "Landscape"
    case portrait = "Portrait"

    var id: String { rawValue }

    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .any: return true
        case .landscape: return item.orientation == .landscape
        case .portrait: return item.orientation == .portrait
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case date = "Date"
    case size = "Size"
    case name = "Name"
    case type = "Type"

    var id: String { rawValue }
}

enum MediaSorter {
    /// Stable, name-tie-broken sort. Default app order is date descending
    /// (newest first) per docs/design.md.
    static func sort(_ items: [MediaItem], by key: SortKey, ascending: Bool) -> [MediaItem] {
        let sorted = items.sorted { a, b in
            switch key {
            case .date:
                let da = a.creationDate ?? .distantPast
                let db = b.creationDate ?? .distantPast
                return da != db ? da < db : nameAscending(a, b)
            case .size:
                return a.sizeBytes != b.sizeBytes ? a.sizeBytes < b.sizeBytes : nameAscending(a, b)
            case .name:
                return nameAscending(a, b)
            case .type:
                let ea = a.fileExtension
                let eb = b.fileExtension
                return ea != eb ? ea < eb : nameAscending(a, b)
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private static func nameAscending(_ a: MediaItem, _ b: MediaItem) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }
}
