# Handoff: iPhone media importer for macOS (inital handoff, might be outdated)

## Goal

Build a native macOS app in Swift that imports photos and videos from an iPhone connected by USB-C into a normal Finder folder. The imported files feed a DaVinci Resolve editing workflow, so the app must deliver unmodified originals (HEVC video, HDR metadata intact), not converted copies.

The first real use case is travel footage from Sweden, recorded on an iPhone and synced to iCloud Photos.

## Why this project exists

The user tried the built-in tools and each one failed a requirement:

- Image Capture does not show iCloud-only items, does not show albums, and cannot filter or sort by media type.
- The import screen in the Photos app on the Mac does not offer a media-type filter either.
- The user exported "unmodified originals" on the iPhone into the Files app (On My iPhone). Neither Image Capture nor Photos can see that folder, because it sits in the Files app storage and not in the camera roll.

## User requirements

1. Connect the iPhone by USB-C cable and import from it. No AirDrop, no iCloud Drive detour.
2. Filter by media type. At minimum photos and videos. Nice to have: slow-motion, time-lapse, Live Photos, screenshots.
3. Sort by date, size, name and type.
4. Browse by album or folder.
5. Include items that exist only in iCloud.
6. Export unmodified originals into a folder the user picks in Finder.
7. Simple. One window, pick device, filter, select, import.

## Hard technical constraints

Read this section before writing code. Requirements 4 and 5 conflict with requirement 1, and the app design has to resolve that.

### What USB access can do

Apple's public API for camera-roll access over USB is ImageCaptureCore (`ICDeviceBrowser`, `ICCameraDevice`, `ICCameraFile`). It is the same framework Image Capture uses. It exposes each file's name, UTI, creation date and size, so client-side filtering and sorting by type (requirements 2 and 3) are straightforward. `ICCameraFile` also has properties for high frame rate, time-lapse and sidecar files (the video part of a Live Photo). Verify the exact property names against the current SDK.

On macOS 13 and later, `ICCameraDevice.mediaPresentation` can request original assets instead of converted ones. Use `.originalAssets`. On the iPhone, Settings > Photos > Transfer to Mac or PC should be set to Keep Originals as a fallback.

### What USB access cannot do

- iCloud-only items. The phone holds only a thumbnail, so no USB-based tool can transfer the file. This includes paid tools like iMazing. The only fixes are downloading originals on the phone first (Settings > Photos > Download and Keep Originals) or reading from iCloud instead of USB.
- Albums. ImageCaptureCore exposes the camera roll as a flat DCIM file tree. Album membership lives in the Photos database, which PTP does not expose.
- The Files app "On My iPhone" folder. ImageCaptureCore cannot reach it. The only known route is Apple's private AFC and house_arrest protocols over usbmuxd, as implemented by libimobiledevice. This path is undocumented, needs device pairing, and can break with any iOS update. The files there are also duplicates of camera-roll items that ImageCaptureCore can already import.

### The alternative that meets requirements 2 to 6

PhotoKit on the Mac, reading the Mac's own Photos library, which already syncs with iCloud. It provides albums (`PHAssetCollection`), media types and subtypes (`PHAsset.mediaType`, `mediaSubtypes`), and original file export through `PHAssetResourceManager` with `isNetworkAccessAllowed = true` to download iCloud-only originals. It does not use the USB cable, so it fails requirement 1.

## Decision the user must make before implementation

Pick one:

- Option A, USB only (ImageCaptureCore). Meets requirements 1, 2, 3, 6 and 7. Drops albums and iCloud-only items.
- Option B, Mac Photos library (PhotoKit). Meets requirements 2 to 7. Drops the cable.
- Option C, both sources in one app, with a source switcher. Most work. Recommended only if the user really needs cable imports for items that are not yet in iCloud.

Do not start Option A with a hidden promise of albums or iCloud items. Say the limitation in the UI.

Record the decision as an ADR. The user writes ADRs as part of their role.

## Suggested v1 scope (Option A)

- SwiftUI app, macOS 13 minimum.
- Device list from `ICDeviceBrowser`. Handle the "trust this computer" and locked-phone states with a clear message.
- Grid of thumbnails with a type filter (All, Photos, Videos, Slow-mo, Time-lapse, Live Photos) and sort control.
- Multi-select and "Import selected" to a folder picked with `NSOpenPanel`.
- Request original assets. Keep original filenames. Skip files that already exist in the target folder, with a count shown after import.
- Progress per file and total, cancellable.
- Out of scope for v1: albums, iCloud-only items, Files app storage, editing, deleting from the phone.

## Acceptance criteria

- With an unlocked, trusted iPhone connected, the app lists camera-roll items within a few seconds of launch.
- Filtering to Videos shows only video items. Imported videos are HEVC `.MOV` files with the same size as on the phone.
- An HDR clip imported by the app opens in DaVinci Resolve and reports Rec.2100 HLG as its input color space.
- Re-running an import into the same folder copies nothing new.
- iCloud-only items show a clear "not on device" state instead of silently failing.

## Open questions

- Distribution: personal Developer ID build or App Store? Sandboxing affects which entitlements ImageCaptureCore needs. Start unsandboxed and confirm entitlements in a spike.
- Should imports create subfolders by date or by type?
- Does the user want a Resolve-friendly naming scheme (for example date plus original name)?

## Suggested skills for the next agent

- `grilling`, to challenge the scope decision before code gets written.
- `technical-writing`, for the ADR and README.
