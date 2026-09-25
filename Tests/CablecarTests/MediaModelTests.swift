import XCTest
@testable import Cablecar

final class MediaKindClassifierTests: XCTestCase {
    func testPlainVideo() {
        XCTAssertEqual(
            MediaKindClassifier.classify(
                filename: "IMG_0493.MOV", duration: 12.3,
                isHighFramerate: false, isTimeLapse: false, hasVideoSidecar: false),
            .video
        )
    }

    func testSlowMoAndTimeLapseFlags() {
        XCTAssertEqual(
            MediaKindClassifier.classify(
                filename: "IMG_1.MOV", duration: 5,
                isHighFramerate: true, isTimeLapse: false, hasVideoSidecar: false),
            .slowMoVideo
        )
        XCTAssertEqual(
            MediaKindClassifier.classify(
                filename: "IMG_2.MOV", duration: 5,
                isHighFramerate: false, isTimeLapse: true, hasVideoSidecar: false),
            .timeLapseVideo
        )
    }

    func testVideoDetectedByDurationWhenExtensionIsUnknown() {
        // uti over PTP is only ever generic (spike finding) — duration is the
        // fallback video signal.
        XCTAssertEqual(
            MediaKindClassifier.classify(
                filename: "CLIP_0001.XYZ", duration: 3,
                isHighFramerate: false, isTimeLapse: false, hasVideoSidecar: false),
            .video
        )
    }

    func testLivePhoto() {
        XCTAssertEqual(
            MediaKindClassifier.classify(
                filename: "IMG_0100.HEIC", duration: nil,
                isHighFramerate: false, isTimeLapse: false, hasVideoSidecar: true),
            .livePhoto
        )
    }

    func testPlainPhoto() {
        XCTAssertEqual(
            MediaKindClassifier.classify(
                filename: "IMG_0101.HEIC", duration: nil,
                isHighFramerate: false, isTimeLapse: false, hasVideoSidecar: false),
            .photo
        )
    }
}

final class MediaFilterAndSortTests: XCTestCase {
    private func item(name: String, kind: MediaKind, size: Int64 = 1, date: Date? = nil) -> MediaItem {
        MediaItem(
            id: name, displayName: name, kind: kind, sizeBytes: size,
            creationDate: date, duration: nil, isOnDevice: true, sidecars: []
        )
    }

    func testVideosFilterShowsOnlyVideos() {
        let items = [
            item(name: "a.HEIC", kind: .photo),
            item(name: "b.HEIC", kind: .livePhoto),
            item(name: "c.MOV", kind: .video),
            item(name: "d.MOV", kind: .slowMoVideo),
            item(name: "e.MOV", kind: .timeLapseVideo),
        ]
        let videos = items.filter(MediaFilter.videos.matches)
        XCTAssertEqual(videos.map(\.displayName), ["c.MOV", "d.MOV", "e.MOV"])
        let photos = items.filter(MediaFilter.photos.matches)
        XCTAssertEqual(photos.map(\.displayName), ["a.HEIC", "b.HEIC"])
        XCTAssertEqual(items.filter(MediaFilter.livePhotos.matches).map(\.displayName), ["b.HEIC"])
        XCTAssertEqual(items.filter(MediaFilter.all.matches).count, 5)
    }

    func testDefaultSortIsNewestFirstWithUndatedItemsLast() {
        let old = item(name: "old.HEIC", kind: .photo, date: Date(timeIntervalSince1970: 100))
        let new = item(name: "new.HEIC", kind: .photo, date: Date(timeIntervalSince1970: 200))
        let undated = item(name: "undated.HEIC", kind: .photo, date: nil)
        let sorted = MediaSorter.sort([old, undated, new], by: .date, ascending: false)
        XCTAssertEqual(sorted.map(\.displayName), ["new.HEIC", "old.HEIC", "undated.HEIC"])
    }

    func testSortBySizeAndName() {
        let small = item(name: "b.MOV", kind: .video, size: 10)
        let big = item(name: "a.MOV", kind: .video, size: 20)
        XCTAssertEqual(
            MediaSorter.sort([small, big], by: .size, ascending: true).map(\.displayName),
            ["b.MOV", "a.MOV"]
        )
        XCTAssertEqual(
            MediaSorter.sort([small, big], by: .name, ascending: true).map(\.displayName),
            ["a.MOV", "b.MOV"]
        )
    }

    func testSortByTypeGroupsByExtension() {
        let heic = item(name: "b.HEIC", kind: .photo)
        let mov = item(name: "a.MOV", kind: .video)
        XCTAssertEqual(
            MediaSorter.sort([mov, heic], by: .type, ascending: true).map(\.displayName),
            ["b.HEIC", "a.MOV"]
        )
    }
}
