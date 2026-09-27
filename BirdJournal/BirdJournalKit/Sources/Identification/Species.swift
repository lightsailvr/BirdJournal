import Foundation

/// One output class of the acoustic model. `index` is the class's row in the model output; `scientificName` is
/// the key shared with the geomodel and, later, the species pack.
public struct Species: Sendable, Hashable, Identifiable {
    public let index: Int
    public let scientificName: String
    public let commonName: String
    /// Taxonomic class as the label file spells it, e.g. "Aves", "Mammalia", "Insecta".
    public let taxonomicClass: String

    public var id: Int { index }

    public init(index: Int, scientificName: String, commonName: String, taxonomicClass: String) {
        self.index = index
        self.scientificName = scientificName
        self.commonName = commonName
        self.taxonomicClass = taxonomicClass
    }
}

extension Species {
    public static let birds = "Aves"
}

public enum LabelFileError: Error, Equatable {
    case missingHeader
    case malformedRow(line: Int)
    case indexMismatch(line: Int, expected: Int)
}

/// Parses BirdNET+ V3.0's label CSV (`idx;id;sci_name;com_name;class;order`, UTF-8 with a BOM) into the model's
/// species in output order.
public enum AcousticLabels {
    public static func parse(_ text: String) throws -> [Species] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let header = lines.first?.replacingOccurrences(of: "\u{FEFF}", with: "") else { throw LabelFileError.missingHeader }
        let columns = header.split(separator: ";").map(String.init)
        guard let idx = columns.firstIndex(of: "idx"), let sci = columns.firstIndex(of: "sci_name"),
              let com = columns.firstIndex(of: "com_name"), let cls = columns.firstIndex(of: "class")
        else { throw LabelFileError.missingHeader }

        return try lines.dropFirst().enumerated().map { offset, line in
            let lineNumber = offset + 2
            let fields = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == columns.count, let index = Int(fields[idx]) else { throw LabelFileError.malformedRow(line: lineNumber) }
            guard index == offset else { throw LabelFileError.indexMismatch(line: lineNumber, expected: offset) }
            return Species(index: index, scientificName: fields[sci], commonName: fields[com], taxonomicClass: fields[cls])
        }
    }

    public static func load(from url: URL) throws -> [Species] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}

/// One output class of the geomodel: `id<TAB>sci_name<TAB>com_name`, one per line, in output order.
public struct GeoLabel: Sendable, Hashable {
    public let scientificName: String
    public let commonName: String
}

public enum GeoLabels {
    public static func parse(_ text: String) throws -> [GeoLabel] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return try lines.enumerated().map { offset, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw LabelFileError.malformedRow(line: offset + 1) }
            return GeoLabel(scientificName: String(fields[1]), commonName: String(fields[2]))
        }
    }

    public static func load(from url: URL) throws -> [GeoLabel] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
