import XCTest
@testable import Cablecar

final class MetadataFormatterTests: XCTestCase {
    func testSectionsSplitFileFieldsFromNestedDictionaries() {
        let raw: [AnyHashable: Any] = [
            "ColorModel": "RGB",
            "PixelWidth": 4032,
            "{Exif}": [
                "FNumber": 1.6,
                "ISOSpeedRatings": [80],
                "Flash": false,
            ],
            "{TIFF}": [
                "Make": "Apple",
                "Model": "iPhone 15 Pro",
            ],
        ]
        let sections = MetadataFormatter.sections(from: raw)

        XCTAssertEqual(sections.map(\.title), ["File", "Exif", "TIFF"])

        let file = sections[0]
        XCTAssertEqual(file.fields, [
            MetadataField(label: "ColorModel", value: "RGB"),
            MetadataField(label: "PixelWidth", value: "4032"),
        ])

        let exif = sections[1]
        XCTAssertEqual(exif.fields, [
            MetadataField(label: "FNumber", value: "1.6"),
            MetadataField(label: "Flash", value: "No"),
            MetadataField(label: "ISOSpeedRatings", value: "80"),
        ])
    }

    func testEmptyNestedDictionariesAreDropped() {
        let sections = MetadataFormatter.sections(from: ["{GPS}": [AnyHashable: Any]()])
        XCTAssertTrue(sections.isEmpty)
    }

    func testValueFormatting() {
        XCTAssertEqual(MetadataFormatter.format("text"), "text")
        XCTAssertEqual(MetadataFormatter.format(42), "42")
        XCTAssertEqual(MetadataFormatter.format(1.6), "1.6")
        XCTAssertEqual(MetadataFormatter.format(true), "Yes")
        XCTAssertEqual(MetadataFormatter.format(false), "No")
        XCTAssertEqual(MetadataFormatter.format([1, 2, 3]), "1, 2, 3")
    }

    func testSectionTitleStripsBraces() {
        XCTAssertEqual(MetadataFormatter.sectionTitle("{Exif}"), "Exif")
        XCTAssertEqual(MetadataFormatter.sectionTitle("Plain"), "Plain")
    }
}
