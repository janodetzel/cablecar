# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

No code exists yet. This repository contains only `docs/handoff.md`, which is the authoritative spec — read it in full before writing any code. The project is a native macOS app (Swift/SwiftUI, macOS 13+) that imports photos and videos from a USB-connected iPhone into a Finder folder, delivering **unmodified originals** (HEVC video with HDR metadata intact) for a DaVinci Resolve workflow.

## Blocking decision before implementation

A source-architecture decision must be made and recorded as an ADR (the user writes ADRs as part of their role) before code is written:

- **Option A — USB only (ImageCaptureCore):** meets the cable, filter, sort, original-export, and simplicity requirements. Cannot do albums or iCloud-only items.
- **Option B — Mac Photos library (PhotoKit):** adds albums and iCloud-only items but drops the USB cable requirement.
- **Option C — both sources with a switcher:** most work; only if cable imports of not-yet-synced items are truly needed.

Do not start Option A while implicitly promising albums or iCloud items — state the limitation in the UI.

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
