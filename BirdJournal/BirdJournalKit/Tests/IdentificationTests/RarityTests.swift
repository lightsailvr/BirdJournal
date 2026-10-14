import Foundation
import Testing
@testable import Identification

// Issue #52, ADR-0006: a card's rarity is the geomodel's occurrence for the species at the add's place and week,
// labelled by the committed calibration. These run the pinned geomodel; the species and weeks were picked well inside
// their label's band, so a change in the model or the calibration shows here.
@Suite("Rarity", .serialized)
struct RarityTests {
    static let downtownLA = (latitude: 34.05, longitude: -118.25)

    static func reader() throws -> RarityReader {
        RarityReader(occurrenceModel: try ONNXGeoModel.bundled(), calibration: try RarityCalibration.bundled())
    }

    static func losAngeles(week: Int) -> GeoContext {
        GeoContext(latitude: downtownLA.latitude, longitude: downtownLA.longitude, week: week)
    }

    @Test("the committed calibration is version 1, above the identification floor, rarest band lowest")
    func committedCalibration() throws {
        let calibration = try RarityCalibration.bundled()
        #expect(calibration.version == 1)
        #expect(calibration.floor == IdentificationConfiguration().occurrenceThreshold)
        #expect(calibration.floor < calibration.thresholds.rare)
        #expect(calibration.thresholds.rare < calibration.thresholds.uncommon)
        #expect(calibration.thresholds.uncommon < calibration.thresholds.common)
        #expect(calibration.thresholds.common < 1)
    }

    @Test("an occurrence takes the label of the band it falls in, each lower bound included")
    func bands() {
        let calibration = RarityCalibration(version: 9, floor: 0.03, thresholds: .init(rare: 0.1, uncommon: 0.4, common: 0.75))
        #expect(calibration.label(for: 1) == .common)
        #expect(calibration.label(for: 0.75) == .common)
        #expect(calibration.label(for: 0.749) == .uncommon)
        #expect(calibration.label(for: 0.4) == .uncommon)
        #expect(calibration.label(for: 0.399) == .rare)
        #expect(calibration.label(for: 0.1) == .rare)
        #expect(calibration.label(for: 0.099) == .exceptional)
        #expect(calibration.label(for: 0.01) == .exceptional, "below the floor is Exceptional")
        #expect(calibration.label(for: 0) == .exceptional)
    }

    @Test("the real geomodel in Los Angeles labels each band", arguments: [
        ("Haemorhous mexicanus", 20, RarityReading.Label.common),  // House Finch in May, about 1.0
        ("Catharus ustulatus", 42, .uncommon),  // Swainson's Thrush in late October, about 0.64
        ("Polioptila californica", 2, .rare),  // California Gnatcatcher in early January, about 0.28
        ("Contopus sordidulus", 2, .exceptional),  // Western Wood Pewee in early January, about 0.08
    ])
    func labelsFromTheGeomodel(scientificName: String, week: Int, expected: RarityReading.Label) throws {
        let reading = try #require(try Self.reader().reading(scientificName: scientificName, in: Self.losAngeles(week: week)))
        #expect(reading.label == expected, "occurrence \(reading.occurrence)")
        #expect(reading.calibrationVersion == 1)
        #expect(reading.week == week)
        #expect(reading.occurrence >= 0.03, "above the identification floor")
    }

    @Test("a species below the identification floor is Exceptional and keeps its occurrence")
    func belowTheFloor() throws {
        // The Florida Scrub-Jay in Los Angeles: identification would never admit it with a location, but a sighting
        // can still name it.
        let reading = try #require(try Self.reader().reading(scientificName: "Aphelocoma coerulescens", in: Self.losAngeles(week: 20)))
        #expect(reading.occurrence < 0.03)
        #expect(reading.label == .exceptional)
    }

    @Test("no location, or a species the geomodel doesn't know, gives no reading rather than a guess")
    func unavailable() throws {
        let reader = try Self.reader()
        #expect(try reader.reading(scientificName: "Haemorhous mexicanus", in: nil) == nil)
        #expect(try reader.reading(scientificName: "Tyto furcata", in: Self.losAngeles(week: 20)) == nil)
    }
}
