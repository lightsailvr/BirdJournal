import Foundation
import Pack
import Testing
import UIKit
@testable import BirdJournal

// Issue #55: the stats a card prints, in units that follow the phone's measurement system, "≈" on a predicted
// wingspan, a diet icon VoiceOver can name, and nothing at all for a stat the datasets lack.
@Suite("Card stats")
@MainActor
struct CardStatsTests {
    static let us = Locale(identifier: "en_US")
    static let metric = Locale(identifier: "en_AU")
    static let uk = Locale(identifier: "en_GB")

    static func stats(
        wingspan: PackStats.Wingspan? = .init(centimetres: 23.4, isPredicted: true), massGrams: Double? = 21.4, diet: PackStats.Diet? = .granivore,
        nests: [PackStats.Nest] = [.cup], clutch: ClosedRange<Double>? = 2...7
    ) -> PackStats {
        PackStats(
            avibaseID: "AVIBASE-89431E9F", wingspan: wingspan, massGrams: massGrams, diet: diet, habitat: .shrubland, migration: .partialMigrant,
            nests: nests, clutch: clutch, lifestyle: .insessorial, sources: [.avonet, .birdbase, .wingspan]
        )
    }

    @Test("a measured wingspan in centimetres or metres, inches or feet; a predicted one marked ≈", arguments: [
        (23.4, false, "metric", "23 cm"), (23.4, true, "metric", "≈ 23 cm"), (203.0, false, "metric", "2.0 m"), (121.5, true, "metric", "≈ 1.2 m"),
        (23.4, false, "us", "9 in"), (23.4, true, "us", "≈ 9 in"), (203.0, false, "us", "6.7 ft"), (11.7, false, "us", "5 in"),
        (23.4, false, "uk", "23 cm"),
    ])
    func wingspan(centimetres: Double, predicted: Bool, system: String, expected: String) {
        let locale = ["metric": Self.metric, "us": Self.us, "uk": Self.uk][system]!
        #expect(CardStatsText.wingspan(.init(centimetres: centimetres, isPredicted: predicted), locale: locale) == expected)
    }

    @Test("VoiceOver hears the wingspan's units in full and that a predicted one is an estimate")
    func spokenWingspan() {
        #expect(CardStatsText.wingspanSpoken(.init(centimetres: 23.4, isPredicted: false), locale: Self.metric) == "Wingspan 23 centimetres")
        #expect(CardStatsText.wingspanSpoken(.init(centimetres: 23.4, isPredicted: true), locale: Self.us) == "Wingspan about 9 inches, estimated from wing length")
    }

    @Test("weight in grams or kilograms, ounces or pounds", arguments: [
        (4.2, "metric", "4.2 g"), (21.4, "metric", "21 g"), (1101.2, "metric", "1.1 kg"),
        (4.2, "us", "0.15 oz"), (21.4, "us", "0.75 oz"), (450.0, "us", "15.9 oz"), (1101.2, "us", "2.4 lb"),
    ])
    func weight(grams: Double, system: String, expected: String) {
        let locale = system == "us" ? Self.us : Self.metric
        #expect(CardStatsText.weight(grams: grams, locale: locale) == expected)
    }

    @Test("every diet has an icon the system draws and a name VoiceOver reads")
    func dietIcons() {
        for diet in PackStats.Diet.allCases {
            #expect(UIImage(systemName: CardStatsText.dietSymbol(diet)) != nil, "\(diet) has no SF Symbol")
            #expect(!CardStatsText.dietTitle(diet).isEmpty)
        }
        #expect(CardStatsText.dietTitle(.granivore) == "Seeds")
        #expect(CardStatsText.dietSpoken(.aquaticPredator) == "Diet: fish and other water life")
    }

    @Test("the front shows wingspan, weight and diet, leaving off what the datasets lack")
    func frontStats() {
        let full = CardStatsText.front(Self.stats(), locale: Self.metric)
        #expect(full.map(\.label) == ["Wingspan", "Weight", "Diet"])
        #expect(full.map(\.value) == ["≈ 23 cm", "21 g", "Seeds"])
        #expect(full.last?.symbol == "laurel.leading")
        #expect(full.first?.spoken == "Wingspan about 23 centimetres, estimated from wing length")
        #expect(full[1].spoken == "Weight 21 grams")
        #expect(CardStatsText.front(Self.stats(massGrams: 1101.2), locale: Self.us)[1].spoken == "Weight 2.4 pounds")

        let flightless = CardStatsText.front(Self.stats(wingspan: nil, diet: nil), locale: Self.metric)
        #expect(flightless.map(\.label) == ["Weight"])
    }

    @Test("the back names habitat, migration, nest, clutch and lifestyle in plain words")
    func backStats() {
        let back = CardStatsText.back(Self.stats(nests: [.halfCup, .cup, .platform]))
        #expect(back.map(\.label) == ["Habitat", "Migration", "Nest", "Clutch", "Lifestyle"])
        #expect(back.map(\.value) == ["Shrubland", "Partial migrant", "Half cup, cup or platform", "2–7 eggs", "Perches in trees and shrubs"])

        #expect(CardStatsText.back(Self.stats(nests: [], clutch: nil)).map(\.label) == ["Habitat", "Migration", "Lifestyle"])
        #expect(CardStatsText.clutch(1...1) == "1 egg")
        #expect(CardStatsText.clutch(2...2) == "2 eggs")
        #expect(CardStatsText.clutch(3.5...5) == "3.5–5 eggs")
    }

    @Test("the sources line credits the datasets the species' stats came from")
    func sources() {
        #expect(CardStatsText.sources(Self.stats()) == "From AVONET, BIRDBASE and the Avian wingspan database (CC BY 4.0). A wingspan marked ≈ is estimated from wing length.")
        let measured = PackStats(
            avibaseID: nil, wingspan: .init(centimetres: 78, isPredicted: false), massGrams: 450, diet: .vertivore, habitat: nil, migration: nil,
            nests: [], clutch: nil, lifestyle: nil, sources: [.avonet, .wingspan]
        )
        #expect(CardStatsText.sources(measured) == "From AVONET and the Avian wingspan database (CC BY 4.0).")
    }
}
