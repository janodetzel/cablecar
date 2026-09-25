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

Throwaway CLI (`spike/`, run with `swift run` inside that folder with the iPhone connected and unlocked) to verify three facts; findings amend ADR-001:

1. ~~Exact `ICCameraFile` property names~~ **Confirmed from the macOS 26 SDK headers:** `highFramerate`, `timeLapse`, `sidecarFiles` (plus useful extras: `fingerprint`, `burstUUID`, `exifCreationDate`, `duration`, `originalFilename`). Caveat: `mediaPresentation` is only available when the device reports the `ICDeviceCapability.cameraDeviceSupportsHEIF` capability — the spike prints whether the iPhone does. Still to verify on hardware: whether the slow-mo/time-lapse flags and sidecar links actually carry values over PTP.
2. ~~Whether unsandboxed ImageCaptureCore triggers any entitlement or TCC prompt~~ **Confirmed on hardware (2026-09-25):** no TCC prompt; an unsandboxed CLI browsed, opened a session, and listed 2610 items with no permission dialog.
3. How an iCloud-offloaded (thumbnail-only) item presents itself over the cable — **partially answered:** the catalog contains a cluster of sub-100 KB JPG/PNG files (offload-proxy candidates). Still open: whether offloaded items are also *hidden* (compare catalog count vs the Photos app's on-phone count), and whether small files are proxies or genuinely small images. Detection likely needs a size-vs-expected heuristic or a metadata probe.

### Hardware findings (first spike run, iPhone over USB-C, 2026-09-25)

- Lock state is evaluated at connect time: session open fails with error `-9943` ("Please unlock") even if the phone is unlocked moments later. The restriction lifts asynchronously — the app must listen for `cameraDeviceDidRemoveAccessRestriction` and re-issue `requestOpenSession` (verified working, ~0.2 s later).
- **The iPhone does not report the `SupportsHEIF` capability** (only `ICCameraDeviceCanAcceptPTPCommands`), so `mediaPresentation = .originalAssets` cannot be set. Despite that, the catalog lists `.HEIC`, `.DNG`, and full-size `.MOV` files — originals appear to be governed by the phone's Settings > Photos > Transfer to Mac or PC setting. Phase 2 of the spike (download + AVFoundation codec/color check) verifies whether downloads are true HEVC/HDR originals.
- `ICCameraFile.uti` is only ever generic `public.image` / `public.movie` — type filtering must use file extension, `duration`, and the boolean flags, not UTI subtypes.
- Live Photo pairing via `sidecarFiles` works (HEIC items list their `.MOV` sidecar). `.AAE` edit-recipe sidecars also appear (decision pending: copy or skip).
- Slow-mo/time-lapse flags came back false for all 2610 items — pending confirmation whether the roll contains any such clips; if it does, the flags do not survive PTP and the filter feature needs rethinking.
- Full catalog (2610 items) was delivered ~0.1 s after session open — well within the "few seconds" acceptance criterion.

### Hardware findings (spike phase 2 — download verification, 2026-09-25)

- **HEVC originals survive the cable** even though the device never reports `SupportsHEIF` and `mediaPresentation` stays at its default: the newest camera clip (`IMG_0493.MOV`, 4K) downloaded byte-exact (28,835,801 bytes on phone and disk) as `hvc1`. The phone's Transfer to Mac or PC setting presumably governs this; the app should still attempt `.originalAssets` when the capability appears, but must verify per-file size regardless (already in the v1 design).
- **Saved filename can differ from the catalog display name** for shared/saved (non-camera) media: a clip listed as `6CD21CDD-….MOV` saved to disk as `IUAV5727.MOV`. Camera-captured items (`IMG_*`) have `name`, `originalFilename`, and `createdFilename` all equal. Consequence for skip-existing: the app must pass an explicit `ICSaveAsFilename` (derived from the display name it shows the user) so the on-disk name is deterministic — never rely on the device's default saved name.
- A UUID-named 2020 clip (`avc1` 720×1280) also downloaded byte-exact — imports of non-camera media are unmodified too; H.264 sources simply stay H.264.
- **HDR survives the cable ✅** (verified 2026-09-25 with a freshly shot HDR clip, `IMG_0558.MOV`): downloaded byte-exact (31,635,098 bytes) as `hvc1` 3840×2160 with `colorPrimaries=ITU_R_2020`, `transferFunction=ITU_R_2100_HLG`, `yCbCrMatrix=ITU_R_2020`. The core acceptance criterion (unmodified HEVC/HLG originals) holds over USB with default `mediaPresentation`. An SDR camera clip (`IMG_0493.MOV`, Rec.709 tags) also came down byte-exact — tags faithfully reflect how each clip was shot.
- **Still open (non-blocking, user facts):** phone's on-device Photos/Videos counts vs the 1677 + 933 catalog (does USB hide offloaded items or show them as small proxies?), and whether any slow-mo/time-lapse clips exist on the roll given zero flagged items. Both only affect the "not on device" detection heuristic and the Slow-mo/Time-lapse filters, not the core import path.

**Spike verdict: passed.** The USB path meets every hard requirement it was chosen for. The throwaway `spike/` CLI stays in the repo as reference until the app's import engine replaces it.

## Acceptance criteria (v1)

Unchanged from handoff.md:

- Unlocked, trusted iPhone lists camera-roll items within a few seconds of launch.
- "Videos" filter shows only videos; imported videos are HEVC `.MOV` matching on-phone size.
- An imported HDR clip opens in DaVinci Resolve reporting Rec.2100 HLG input color space.
- Re-running an import into the same folder copies nothing (skip count shown).
- iCloud-only items show an explicit "not on device" state instead of failing silently.
