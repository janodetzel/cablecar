# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

No code exists yet. The authoritative documents, in precedence order:

1. `docs/adr/001-source-architecture.md` — the source-architecture decision (made 2026-09-25)
2. `docs/design.md` — the v1 design from the grilling session
3. `docs/handoff.md` — the original spec; superseded where the above differ

The project is a native macOS app (Swift/SwiftUI, **macOS 15+**) that imports photos and videos from a USB-connected iPhone into a Finder folder, delivering **unmodified originals** (HEVC video with HDR metadata intact) for a DaVinci Resolve workflow. Internal name **Cablecar** (`com.janodetzel.cablecar`); display name decided before publishing.

## Decided architecture (ADR-001)

**Option A now, evolving to Option C**: v1 is USB-only via ImageCaptureCore, built around a `MediaSource` abstraction so a PhotoKit/iCloud source can be added later. Albums and iCloud-only originals are deferred to that PhotoKit source; the v1 UI states both limitations plainly.

**Hard constraints:**

- **Never delete media from the phone — in any version.** The app is strictly read-only toward the device.
- Never convert media; originals only.

**Next step:** the spike listed in `docs/design.md` (verify `ICCameraFile` property names, unsandboxed ImageCaptureCore entitlement behavior, and how iCloud-offloaded items present over USB) before any app code.

## Hard technical constraints (from docs/handoff.md)

- USB camera-roll access goes through **ImageCaptureCore** (`ICDeviceBrowser`, `ICCameraDevice`, `ICCameraFile`). File name, UTI, creation date, and size are exposed, so type filtering and sorting are client-side. Verify exact `ICCameraFile` property names (high frame rate, time-lapse, sidecars) against the current SDK.
- Request originals with `ICCameraDevice.mediaPresentation = .originalAssets` (macOS 13+); iPhone Settings > Photos > "Keep Originals" is the fallback.
- USB **cannot** reach: iCloud-only items (phone holds only a thumbnail), albums (Photos database is not exposed over PTP — the camera roll is a flat DCIM tree), or the Files app "On My iPhone" storage (private AFC/house_arrest protocols only).
- PhotoKit on the Mac (`PHAssetCollection`, `PHAsset.mediaType`/`mediaSubtypes`, `PHAssetResourceManager` with `isNetworkAccessAllowed = true`) covers albums and iCloud-only originals, but reads the Mac's Photos library, not the cable.
- Distribution/sandboxing is an open question — start unsandboxed and confirm which entitlements ImageCaptureCore needs in a spike.

## Acceptance criteria (v1)

- Unlocked, trusted iPhone lists camera-roll items within a few seconds of launch.
- "Videos" filter shows only videos; imported videos are HEVC `.MOV` matching on-phone size.
- An imported HDR clip opens in DaVinci Resolve reporting Rec.2100 HLG input color space.
- Re-running an import into the same folder copies nothing (skip-existing with a count shown).
- iCloud-only items show an explicit "not on device" state instead of failing silently.
