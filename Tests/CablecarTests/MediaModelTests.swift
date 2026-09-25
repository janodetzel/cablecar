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
    private func item(
        name: String, kind: MediaKind, size: Int64 = 1, date: Date? = nil,
        width: Int = 0, height: Int = 0
    ) -> MediaItem {
        MediaItem(
            id: name, displayName: name, kind: kind, sizeBytes: size,
            creationDate: date, duration: nil, isOnDevice: true, sidecars: [],
            pixelWidth: width, pixelHeight: height
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

    func testOrientationFilter() {
        let landscape = item(name: "land.MOV", kind: .video, width: 3840, height: 2160)
        let portrait = item(name: "port.HEIC", kind: .photo, width: 3024, height: 4032)
        let square = item(name: "square.HEIC", kind: .photo, width: 2000, height: 2000)
        let unknown = item(name: "unknown.HEIC", kind: .photo)
        let items = [landscape, portrait, square, unknown]

        XCTAssertEqual(items.filter(OrientationFilter.landscape.matches).map(\.displayName), ["land.MOV"])
        XCTAssertEqual(items.filter(OrientationFilter.portrait.matches).map(\.displayName), ["port.HEIC"])
        XCTAssertEqual(items.filter(OrientationFilter.any.matches).count, 4)
    }

    func testExifRotationSwapsDisplayDimensions() {
        // Orientations 1–4 keep stored dimensions; 5–8 are 90° rotations.
        let stored = (width: 4032, height: 3024)
        for exif in 1...4 {
            let size = ExifDimensionMapper.displaySize(
                width: stored.width, height: stored.height, exifOrientation: exif)
            XCTAssertEqual(size.width, 4032, "exif \(exif)")
            XCTAssertEqual(size.height, 3024, "exif \(exif)")
        }
        for exif in 5...8 {
            let size = ExifDimensionMapper.displaySize(
                width: stored.width, height: stored.height, exifOrientation: exif)
            XCTAssertEqual(size.width, 3024, "exif \(exif)")
            XCTAssertEqual(size.height, 4032, "exif \(exif)")
        }
        // A portrait-shot photo stored landscape with a 90° flag filters as portrait.
        let rotated = ExifDimensionMapper.displaySize(width: 4032, height: 3024, exifOrientation: 6)
        let portraitItem = item(name: "p.HEIC", kind: .photo, width: rotated.width, height: rotated.height)
        XCTAssertEqual(portraitItem.orientation, .portrait)
        XCTAssertTrue(OrientationFilter.portrait.matches(portraitItem))
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
