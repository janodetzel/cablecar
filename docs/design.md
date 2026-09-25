# Cablecar — v1 design

Outcome of the 2026-09-25 design session. Architecture rationale lives in [ADR-001](adr/001-source-architecture.md); the original requirements and constraints live in [handoff.md](handoff.md). Where the two differ, this document and the ADR win.

**Cablecar** is the internal name only (an app of that name already exists); the display name is decided before any publishing. Bundle id: `com.janodetzel.cablecar`.

## Purpose

Ongoing tool for importing travel media from an iPhone over USB-C into a Finder folder, delivering unmodified originals (HEVC `.MOV`, HDR metadata intact) for DaVinci Resolve. The cable exists because footage in the field is not yet in iCloud, and network round-trips are slow and failure-prone.

## Hard constraints

- **Never delete media from the phone. Ever.** The app is strictly read-only toward the device — no delete or "free up space" capability in any version.
- **Never convert media.** Originals only: `mediaPresentation = .originalAssets`; iPhone "Keep Originals" transfer setting as fallback.
- macOS 15 minimum.
- v1 build: personal, unsandboxed, local. Publishing (signing, notarization, possibly sandboxing) revisited later — avoid decisions that permanently block it.

## v1 behavior

### Source and device

- USB via ImageCaptureCore (`ICDeviceBrowser`, `ICCameraDevice`, `ICCameraFile`), behind a `MediaSource` abstraction (see ADR-001).
- Clear messages for locked-phone and "trust this computer" states.
- Camera-roll items listed within a few seconds of connecting an unlocked, trusted iPhone.

### Browsing

- Grid of thumbnails.
- Filters: All / Photos / Videos / Slow-mo / Time-lapse / Live Photos.
- Sort by date, size, name, type. Default view: **All, newest first**.
- iCloud-thumbnail-only items: greyed out, unselectable, badged "not on device"; "select all" skips them.
- The UI states plainly that albums and iCloud-only originals are not available over USB (deferred to the future PhotoKit source).

### Import

- Multi-select → "Import selected" into a folder picked with `NSOpenPanel`. Last-used destination remembered between launches.
- Flat destination folder, **original filenames**. (Renaming-pattern UI deferred; planned tokens when it lands: `{name}`, `{date}`, `{time}`, `{seq}`, default `{name}`. Skip-existing then compares the final renamed name.)
- Live Photos always import **both** parts: HEIC still + MOV sidecar.
- Skip-existing by **filename match** in the target folder, with a skipped count in the summary.
- In-flight copies use a `.partial` suffix so an interrupted run never satisfies the filename match.
- After each copy, verify byte size against the phone-reported size; mismatches flagged in the summary, `.partial` file left in place.
- Progress per file and total; cancellable.
- End-of-import summary: imported / skipped-existing / skipped-not-on-device / failed counts.

## Deferred (in decision order)

1. **PhotoKit source** (→ Option C): iCloud-only originals via `PHAssetResourceManager` (`isNetworkAccessAllowed = true`) and albums via `PHAssetCollection`.
2. Renaming-pattern UI.
3. Date-based subfolders (possible toggle).
4. Publishing/distribution decisions.

Never coming: deletion from the phone.

## Spike (before app code)

Throwaway CLI against the real iPhone to verify three facts; findings amend ADR-001:

1. Exact `ICCameraFile` property names in the current SDK for high frame rate (slow-mo), time-lapse, and sidecar files (Live Photo video part).
2. Whether unsandboxed ImageCaptureCore triggers any entitlement or TCC prompt.
3. How an iCloud-offloaded (thumbnail-only) item presents itself over the cable — needed for reliable "not on device" detection.

## Acceptance criteria (v1)

Unchanged from handoff.md:

- Unlocked, trusted iPhone lists camera-roll items within a few seconds of launch.
- "Videos" filter shows only videos; imported videos are HEVC `.MOV` matching on-phone size.
- An imported HDR clip opens in DaVinci Resolve reporting Rec.2100 HLG input color space.
- Re-running an import into the same folder copies nothing (skip count shown).
- iCloud-only items show an explicit "not on device" state instead of failing silently.
