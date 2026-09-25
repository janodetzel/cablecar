import XCTest
@testable import Cablecar

final class ImportPlannerTests: XCTestCase {
    private func item(
        name: String,
        size: Int64 = 1_000,
        kind: MediaKind = .photo,
        onDevice: Bool = true,
        sidecars: [MediaItem.Sidecar] = []
    ) -> MediaItem {
        MediaItem(
            id: "id-\(name)",
            displayName: name,
            kind: kind,
            sizeBytes: size,
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            duration: nil,
            isOnDevice: onDevice,
            sidecars: sidecars,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    func testFreshImportPlansEverything() {
        let plan = ImportPlanner.makePlan(
            items: [item(name: "IMG_0001.HEIC"), item(name: "IMG_0002.MOV", size: 5_000)],
            existingFilenames: []
        )
        XCTAssertEqual(plan.files.map(\.filename), ["IMG_0001.HEIC", "IMG_0002.MOV"])
        XCTAssertEqual(plan.totalBytes, 6_000)
        XCTAssertEqual(plan.skippedExisting, 0)
        XCTAssertEqual(plan.skippedNotOnDevice, 0)
    }

    func testRerunIntoSameFolderCopiesNothing() {
        let items = [item(name: "IMG_0001.HEIC"), item(name: "IMG_0002.MOV")]
        let plan = ImportPlanner.makePlan(
            items: items,
            existingFilenames: ["IMG_0001.HEIC", "IMG_0002.MOV", "unrelated.txt"]
        )
        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.skippedExisting, 2)
    }

    func testExistingMatchIsCaseInsensitive() {
        let plan = ImportPlanner.makePlan(
            items: [item(name: "IMG_0001.HEIC")],
            existingFilenames: ["img_0001.heic"]
        )
        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.skippedExisting, 1)
    }

    func testPartialFilesNeverSatisfyTheMatch() {
        let plan = ImportPlanner.makePlan(
            items: [item(name: "IMG_0001.HEIC")],
            existingFilenames: ["IMG_0001.HEIC" + ImportPlanner.partialSuffix]
        )
        XCTAssertEqual(plan.files.count, 1)
    }

    func testNotOnDeviceItemsAreSkippedAndCounted() {
        let plan = ImportPlanner.makePlan(
            items: [item(name: "IMG_0001.HEIC", onDevice: false), item(name: "IMG_0002.HEIC")],
            existingFilenames: []
        )
        XCTAssertEqual(plan.files.map(\.filename), ["IMG_0002.HEIC"])
        XCTAssertEqual(plan.skippedNotOnDevice, 1)
    }

    func testLivePhotoImportsBothParts() {
        let live = item(
            name: "IMG_0003.HEIC",
            kind: .livePhoto,
            sidecars: [.init(id: "id-IMG_0003.MOV", filename: "IMG_0003.MOV", sizeBytes: 2_000)]
        )
        let plan = ImportPlanner.makePlan(items: [live], existingFilenames: [])
        XCTAssertEqual(plan.files.map(\.filename), ["IMG_0003.HEIC", "IMG_0003.MOV"])
        XCTAssertEqual(plan.totalBytes, 3_000)
    }

    func testLivePhotoWithExistingStillImportsOnlyTheSidecar() {
        let live = item(
            name: "IMG_0003.HEIC",
            kind: .livePhoto,
            sidecars: [.init(id: "id-IMG_0003.MOV", filename: "IMG_0003.MOV", sizeBytes: 2_000)]
        )
        let plan = ImportPlanner.makePlan(items: [live], existingFilenames: ["IMG_0003.HEIC"])
        XCTAssertEqual(plan.files.map(\.filename), ["IMG_0003.MOV"])
        XCTAssertEqual(plan.skippedExisting, 1)
    }

    func testDuplicateFilenamesArePlannedOnce() {
        // Same sidecar reachable via two selected items must not be copied twice.
        let sidecar = MediaItem.Sidecar(id: "id-shared.MOV", filename: "SHARED.MOV", sizeBytes: 100)
        let a = item(name: "IMG_0004.HEIC", kind: .livePhoto, sidecars: [sidecar])
        let b = item(name: "IMG_0005.HEIC", kind: .livePhoto, sidecars: [sidecar])
        let plan = ImportPlanner.makePlan(items: [a, b], existingFilenames: [])
        XCTAssertEqual(plan.files.filter { $0.filename == "SHARED.MOV" }.count, 1)
    }
}
