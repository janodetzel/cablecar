# Cablecar - iOS media import tool for macOS

Native macOS app (Swift/SwiftUI, macOS 15+) that imports photos and videos from a USB-connected iPhone into a Finder folder as **unmodified originals** — HEVC `.MOV` with HDR (Rec.2100 HLG) metadata intact — for a DaVinci Resolve workflow.

Two hard rules, in every version:

- **Never deletes anything from the phone.** Strictly read-only toward the device.
- **Never converts media.** Originals only, verified byte-for-byte against the phone-reported size.

## Running

```sh
swift run Cablecar     # run directly (or: make run)
make app               # assemble Cablecar.app (release build, ad-hoc signed)
swift test             # unit tests for the planner / filtering / sorting logic
```

Plug in the iPhone over USB, unlock it, and tap Trust if asked — the camera roll appears automatically. Pick a destination folder, select items, Import. Re-running an import into the same folder skips files that already exist (matched by filename; in-flight copies use a `.partial` suffix so interrupted runs never count as done).

## What it can and can't do

v1 is USB-only via ImageCaptureCore (ADR-001). Over the cable the phone exposes a flat camera roll — **albums and iCloud-offloaded originals are not reachable** and are deferred to a future PhotoKit/iCloud source behind the same `MediaSource` abstraction. Live Photos import both parts (HEIC + MOV). `.AAE` edit-recipe sidecars are skipped.

## Repository layout

- `Sources/Cablecar/` — the app: `Model/` (source-agnostic types + `MediaSource` protocol), `USB/` (ImageCaptureCore source), `Import/` (pure planner + import engine), `UI/`
- `Tests/CablecarTests/` — unit tests for the pure logic
- `docs/` — authoritative docs: `adr/001-source-architecture.md`, `design.md`, `handoff.md`
- `spike/` — throwaway hardware-verification CLI that validated ADR-001 (kept as reference)
