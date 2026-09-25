import XCTest
@testable import Cablecar

@MainActor
private final class FakeMediaSource: MediaSource {
    weak var delegate: (any MediaSourceDelegate)?
    var state: SourceState = .ready(deviceName: "Fake")
    var items: [MediaItem] = []
    let limitationsNote = ""

    func start() {}
    func stop() {}
    func requestThumbnail(for itemID: MediaItem.ID) {}
    func requestMetadata(for itemID: MediaItem.ID) {}
    func downloadFile(
        _ fileID: String, to directory: URL, saveAs filename: String,
        progress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws -> URL {
        throw MediaSourceError.deviceNotReady
    }
    func cancelActiveDownload() {}
}

@MainActor
final class SelectionModelTests: XCTestCase {
    private var source: FakeMediaSource!
    private var model: AppModel!
    /// Items in visible order (default sort: newest first).
    private var items: [MediaItem] = []

    override func setUp() {
        super.setUp()
        source = FakeMediaSource()
        model = AppModel(source: source)
        items = (0..<6).map { index in
            MediaItem(
                id: "item\(index)", displayName: "IMG_000\(index).HEIC", kind: .photo,
                sizeBytes: 100,
                creationDate: Date(timeIntervalSince1970: TimeInterval(1_000 - index)),
                duration: nil, isOnDevice: index != 4,  // item4 is iCloud-only
                sidecars: [], pixelWidth: 0, pixelHeight: 0
            )
        }
        source.items = items
        model.mediaSourceDidUpdateItems(source)
        XCTAssertEqual(model.visibleItems.map(\.id), items.map(\.id), "test setup: visible order")
    }

    private func ids(_ indices: Int...) -> Set<MediaItem.ID> {
        Set(indices.map { "item\($0)" })
    }

    func testPlainClickSelectsOnlyThatItemAndInspectsIt() {
        model.handleClick(items[2], shiftPressed: false)
        XCTAssertEqual(model.selection, ids(2))
        XCTAssertEqual(model.inspectedItemID, "item2")

        model.handleClick(items[3], shiftPressed: false)
        XCTAssertEqual(model.selection, ids(3), "plain click replaces the selection")
        XCTAssertEqual(model.inspectedItemID, "item3")
        XCTAssertFalse(model.isMultipleSelection)
    }

    func testPlainClickOnNotOnDeviceItemInspectsButClearsSelection() {
        model.handleClick(items[1], shiftPressed: false)
        model.handleClick(items[4], shiftPressed: false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.inspectedItemID, "item4")
    }

    func testCommandClickTogglesKeepingTheRest() {
        model.handleClick(items[1], shiftPressed: false)
        model.handleClick(items[3], shiftPressed: false, commandPressed: true)
        XCTAssertEqual(model.selection, ids(1, 3))
        XCTAssertEqual(model.inspectedItemID, "item3")
        model.handleClick(items[1], shiftPressed: false, commandPressed: true)
        XCTAssertEqual(model.selection, ids(3))
    }

    func testClickThenShiftClickSelectsRange() {
        model.handleClick(items[1], shiftPressed: false)
        model.handleClick(items[3], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(1, 2, 3))
    }

    func testShiftClickInsideRangeShrinksIt() {
        model.handleClick(items[0], shiftPressed: false)
        model.handleClick(items[5], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2, 3, 5), "item4 is not on device")
        // Finder behavior: shift-click inside the range re-pins it to the click.
        model.handleClick(items[2], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2))
    }

    func testShiftClickFlipsDirectionAroundAnchor() {
        model.handleClick(items[3], shiftPressed: false)
        model.handleClick(items[5], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(3, 5), "item4 is not on device")
        model.handleClick(items[1], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(1, 2, 3))
    }

    func testShiftRangeReplacementKeepsCommandClickedSelections() {
        model.handleClick(items[5], shiftPressed: false)
        model.handleClick(items[0], shiftPressed: false, commandPressed: true)  // anchor
        model.handleClick(items[2], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2, 5))
        model.handleClick(items[1], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 5), "shrinking the range must not drop item5")
    }

    func testShiftClickWithoutAnchorStartsSelection() {
        model.handleClick(items[2], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(2))
        model.handleClick(items[4], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(2), "not-on-device item can't be shift-selected")
        model.handleClick(items[5], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(2, 3, 5))
    }

    func testPlainClickResetsAnchorAndDropsOldRange() {
        model.handleClick(items[0], shiftPressed: false)
        model.handleClick(items[2], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2))
        // Plain click replaces everything and re-anchors.
        model.handleClick(items[5], shiftPressed: false)
        model.handleClick(items[3], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(3, 5), "item4 skipped inside the new range")
    }

    func testDeselectAllKeepsInspectedItem() {
        model.handleClick(items[0], shiftPressed: false)
        model.handleClick(items[2], shiftPressed: true)
        model.deselectAll()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.inspectedItemID, "item0", "Escape keeps the last inspected item")
    }

    func testSelectAllVisibleSkipsNotOnDevice() {
        model.selectAllVisible()
        XCTAssertEqual(model.selection, ids(0, 1, 2, 3, 5))
    }
}
