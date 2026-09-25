import Foundation

struct MetadataField: Hashable, Sendable {
    let label: String
    let value: String
}

struct MetadataSection: Hashable, Sendable {
    let title: String
    let fields: [MetadataField]
}

/// Converts an ImageIO-style metadata dictionary (what ImageCaptureCore
/// delivers per file: top-level file properties plus nested `{Exif}`,
/// `{TIFF}`, `{GPS}`, … dictionaries) into ordered, display-ready sections.
/// Pure and deterministic (fields and sections sorted) so it is testable.
enum MetadataFormatter {
    static func sections(from raw: [AnyHashable: Any]) -> [MetadataSection] {
        var fileFields: [MetadataField] = []
        var nested: [MetadataSection] = []

        for (key, value) in raw {
            let name = String(describing: key)
            if let dict = value as? [AnyHashable: Any] {
                let fields = dict
                    .map { MetadataField(label: String(describing: $0.key), value: format($0.value)) }
                    .sorted { $0.label < $1.label }
                if !fields.isEmpty {
                    nested.append(MetadataSection(title: sectionTitle(name), fields: fields))
                }
            } else {
                fileFields.append(MetadataField(label: name, value: format(value)))
            }
        }

        fileFields.sort { $0.label < $1.label }
        var result: [MetadataSection] = []
        if !fileFields.isEmpty {
            result.append(MetadataSection(title: "File", fields: fileFields))
        }
        result += nested.sorted { $0.title < $1.title }
        return result
    }

    /// "{Exif}" → "Exif"
    static func sectionTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }

    static func format(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "Yes" : "No"
            }
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 1e12 {
                return String(Int64(double))
            }
            return String(double)
        case let date as Date:
            return date.formatted(date: .abbreviated, time: .standard)
        case let array as [Any]:
            return array.map(format).joined(separator: ", ")
        case let dict as [AnyHashable: Any]:
            return dict
                .map { "\(String(describing: $0.key)): \(format($0.value))" }
                .sorted()
                .joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }
}
