# ADR-001: Source architecture — USB first, PhotoKit later

- **Status:** Proposed (drafted by Claude from the 2026-09-25 design session; awaiting Jano's review)
- **Date:** 2026-09-25

## Context

The app imports photos and videos from an iPhone into a Finder folder as unmodified originals for a DaVinci Resolve workflow. `docs/handoff.md` identified a conflict: the USB-cable requirement (req. 1) cannot satisfy albums (req. 4) or iCloud-only items (req. 5), because ImageCaptureCore exposes only a flat DCIM tree and the phone holds only thumbnails for offloaded items.

The design session established why the cable matters: during travel, media is not yet uploaded to iCloud, and a network round-trip (upload, then download) is slow and failure-prone. The cable is therefore load-bearing for the primary use case — fast, network-independent field imports — not incidental. iCloud Photos is enabled on the user's Mac, so a PhotoKit source is viable later.

## Decision

**Option A now, evolving to Option C.** v1 imports over USB via ImageCaptureCore only. The code is structured around a `MediaSource` abstraction so a PhotoKit-backed iCloud source can be added later without a rewrite.

Deferred to the future PhotoKit source, and stated plainly in the v1 UI:

- **Albums** — permanently impossible over USB (album membership lives in the Photos database, which PTP does not expose). Albums can only ever come from the PhotoKit source.
- **iCloud-only originals** — the phone holds only a thumbnail; the future PhotoKit source resolves these via `PHAssetResourceManager` with `isNetworkAccessAllowed = true`. In v1, such items are greyed out, unselectable, and badged "not on device"; "select all" skips them.

## Options considered

- **Option A — USB only (ImageCaptureCore).** Meets cable, filtering, sorting, originals, simplicity. Chosen for v1.
- **Option B — Mac Photos library (PhotoKit).** Meets albums and iCloud items but drops the cable — fails the field-import use case outright. Rejected as the sole source.
- **Option C — both sources with a switcher.** The end state, but too much work for v1. Reached incrementally via the `MediaSource` abstraction.

## Hard constraints attached to this decision

- **The app never deletes media from the phone — in any version.** Strictly read-only toward the device. This is an unconditional user constraint, not a v1 deferral.
- **Unmodified originals only.** HEVC `.MOV` with HDR metadata intact; `ICCameraDevice.mediaPresentation = .originalAssets`; no conversion of any media, ever.

## Consequences

- v1 cannot import items shot before the phone offloaded them (Optimise iPhone Storage). Workaround until the PhotoKit source ships: Settings > Photos > Download and Keep Originals on the phone.
- The `MediaSource` protocol must be designed so ImageCaptureCore-specific concepts (device trust, lock state, PTP quirks) do not leak into the UI layer.

## Spike results (2026-09-25 — decision validated on hardware)

The spike (`spike/`, run against the real iPhone) confirmed the USB path delivers everything this decision depends on:

- **Unmodified HEVC/HDR originals over the cable**: an HDR clip downloaded byte-exact as `hvc1` 4K with Rec.2020 primaries and `ITU_R_2100_HLG` transfer — the core acceptance criterion — even though the device never reports the `SupportsHEIF` capability and `mediaPresentation` stays at its default. Per-file byte-size verification stays in the design as the safety net.
- **No TCC/entitlement friction**: an unsandboxed CLI browsed, opened a session, and listed the full 2610-item catalog (~1 s total) with no permission prompt.
- **Lock state is asynchronous**: session open fails with `-9943` at connect even if the phone is unlocked shortly after; the app must retry on `cameraDeviceDidRemoveAccessRestriction` (verified working).
- **`uti` is only ever `public.image`/`public.movie`** — type filtering must use extension, `duration`, and the boolean flags.
- **Live Photo `sidecarFiles` pairing works**; `.AAE` edit-recipe sidecars also appear.
- **Saved filename can differ from the display name** for shared/saved (non-camera) media — the app must pass an explicit save-as filename so skip-existing is deterministic.
- Open, non-blocking: whether iCloud-offloaded items are hidden or shown as small proxies (detection heuristic for the "not on device" badge), and whether `highFramerate`/`timeLapse` flags survive PTP (zero flagged in a 2610-item roll pending confirmation the roll contains such clips).
