import Foundation

/// How unusual a species was at a place and week (ADR-0006, issue #52): the geomodel's occurrence there, the label the
/// calibration gives it, and which calibration and week of BirdNET's 48-week year it was read under. Saved with the
/// sighting at the add and never recomputed.
public struct RarityReading: Sendable, Equatable {
    public enum Label: String, Sendable, CaseIterable {
        case common
        case uncommon
        case rare
        case exceptional
    }

    public let occurrence: Float
    public let label: Label
    public let calibrationVersion: Int
    public let week: Int

    public init(occurrence: Float, label: Label, calibrationVersion: Int, week: Int) {
        self.occurrence = occurrence
        self.label = label
        self.calibrationVersion = calibrationVersion
        self.week = week
    }
}

/// Where occurrence splits into the four labels: computed once by `packbuilder calibrate-rarity` over the five packs'
/// species, regions and weeks, above the identification floor, and committed as `RarityCalibration.json`. A new
/// calibration takes a new version; saved readings keep theirs.
public struct RarityCalibration: Sendable, Equatable, Decodable {
    /// Each label's lower bound. Below `rare` is Exceptional, the floor included: identification never admits a
    /// species below the floor when it knows the place, so one named there is exceptional by definition.
    public struct Thresholds: Sendable, Equatable, Decodable {
        public let rare: Float
        public let uncommon: Float
        public let common: Float

        public init(rare: Float, uncommon: Float, common: Float) {
            self.rare = rare
            self.uncommon = uncommon
            self.common = common
        }
    }

    public let version: Int
    /// The identification floor the thresholds were calibrated above.
    public let floor: Float
    public let thresholds: Thresholds

    public init(version: Int, floor: Float, thresholds: Thresholds) {
        self.version = version
        self.floor = floor
        self.thresholds = thresholds
    }

    /// The calibration shipped in the package bundle.
    public static func bundled() throws -> RarityCalibration {
        guard let url = Bundle.module.url(forResource: "RarityCalibration", withExtension: "json") else {
            throw ModelError.resourceMissing("RarityCalibration.json")
        }
        return try JSONDecoder().decode(RarityCalibration.self, from: Data(contentsOf: url))
    }

    public func label(for occurrence: Float) -> RarityReading.Label {
        if occurrence >= thresholds.common { return .common }
        if occurrence >= thresholds.uncommon { return .uncommon }
        if occurrence >= thresholds.rare { return .rare }
        return .exceptional
    }
}

/// Reads a species' rarity at a place and week from the geo prior under a calibration.
public struct RarityReader: Sendable {
    public let occurrenceModel: any SpeciesOccurrenceModel
    public let calibration: RarityCalibration

    public init(occurrenceModel: any SpeciesOccurrenceModel, calibration: RarityCalibration) {
        self.occurrenceModel = occurrenceModel
        self.calibration = calibration
    }

    /// The reading for `scientificName` in `context`; nil without a place (the card says rarity is unavailable, never
    /// a guess) or when the geomodel doesn't know the species.
    public func reading(scientificName: String, in context: GeoContext?) throws -> RarityReading? {
        guard let context, let occurrence = try occurrenceModel.occurrence(in: context)[scientificName] else { return nil }
        return RarityReading(occurrence: occurrence, label: calibration.label(for: occurrence), calibrationVersion: calibration.version, week: context.week)
    }
}
