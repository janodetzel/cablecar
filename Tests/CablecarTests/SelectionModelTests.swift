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

    func testBrowseModeClickInspectsWithoutSelecting() {
        model.handleClick(items[2], shiftPressed: false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.inspectedItemID, "item2")
        XCTAssertFalse(model.isSelectionMode)
    }

    func testCheckboxThenPlainClicksToggle() {
        model.toggleSelection(of: items[1])
        XCTAssertEqual(model.selection, ids(1))
        model.handleClick(items[3], shiftPressed: false)
        XCTAssertEqual(model.selection, ids(1, 3))
        model.handleClick(items[1], shiftPressed: false)
        XCTAssertEqual(model.selection, ids(3))
    }

    func testShiftClickSelectsRangeFromAnchor() {
        model.toggleSelection(of: items[1])
        model.handleClick(items[3], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(1, 2, 3))
    }

    func testShiftClickInsideRangeShrinksIt() {
        model.toggleSelection(of: items[0])
        model.handleClick(items[5], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2, 3, 5), "item4 is not on device")
        // Finder behavior: shift-click inside the range re-pins it to the click.
        model.handleClick(items[2], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2))
    }

    func testShiftClickFlipsDirectionAroundAnchor() {
        model.toggleSelection(of: items[3])
        model.handleClick(items[5], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(3, 5), "item4 is not on device")
        model.handleClick(items[1], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(1, 2, 3))
    }

    func testShiftRangeReplacementKeepsIndependentSelections() {
        model.toggleSelection(of: items[5])   // independent selection
        model.toggleSelection(of: items[0])   // anchor
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

    func testPlainClickResetsAnchorAndRange() {
        model.toggleSelection(of: items[0])
        model.handleClick(items[2], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2))
        // New anchor via plain click; old shift range is no longer live.
        model.handleClick(items[5], shiftPressed: false)
        model.handleClick(items[3], shiftPressed: true)
        XCTAssertEqual(model.selection, ids(0, 1, 2, 3, 5), "range item4 skipped; earlier range kept")
    }

    func testDeselectAllReturnsToBrowseMode() {
        model.toggleSelection(of: items[0])
        model.handleClick(items[2], shiftPressed: true)
        model.deselectAll()
        XCTAssertFalse(model.isSelectionMode)
        model.handleClick(items[1], shiftPressed: false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.inspectedItemID, "item1")
    }
}
