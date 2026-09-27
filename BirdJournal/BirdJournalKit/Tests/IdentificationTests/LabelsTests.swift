import Testing
@testable import Identification

@Suite("Acoustic labels")
struct AcousticLabelsTests {
    @Test("rows become species in output order, BOM and header stripped")
    func parsesRows() throws {
        let csv = "\u{FEFF}idx;id;sci_name;com_name;class;order\n0;3;Abeillia abeillei;Emerald-chinned Hummingbird;Aves;Apodiformes\n1;5;Canis familiaris;Domestic Dog;Mammalia;Carnivora\n"

        let species = try AcousticLabels.parse(csv)

        #expect(species == [
            Species(index: 0, scientificName: "Abeillia abeillei", commonName: "Emerald-chinned Hummingbird", taxonomicClass: "Aves"),
            Species(index: 1, scientificName: "Canis familiaris", commonName: "Domestic Dog", taxonomicClass: "Mammalia"),
        ])
    }

    @Test("the BirdNET label joins the scientific and common names, as the album and packs key species")
    func birdnetLabel() {
        let phoebe = Species(index: 0, scientificName: "Sayornis nigricans", commonName: "Black Phoebe", taxonomicClass: "Aves")
        #expect(phoebe.birdnetLabel == "Sayornis nigricans_Black Phoebe")
    }

    @Test("a row whose idx does not match its position is rejected, since idx is the model output row")
    func rejectsIndexGap() {
        let csv = "idx;id;sci_name;com_name;class;order\n0;3;A a;A;Aves;X\n2;5;B b;B;Aves;X\n"
        #expect(throws: LabelFileError.indexMismatch(line: 3, expected: 1)) { try AcousticLabels.parse(csv) }
    }

    @Test("a row with the wrong number of fields is rejected")
    func rejectsMalformedRow() {
        let csv = "idx;id;sci_name;com_name;class;order\n0;3;A a;A;Aves\n"
        #expect(throws: LabelFileError.malformedRow(line: 2)) { try AcousticLabels.parse(csv) }
    }

    @Test("a file without the expected header is rejected")
    func rejectsMissingHeader() {
        #expect(throws: LabelFileError.missingHeader) { try AcousticLabels.parse("0;3;A a;A;Aves;X\n") }
    }
}

@Suite("Geomodel labels")
struct GeoLabelsTests {
    @Test("tab-separated rows keep scientific and common names in output order")
    func parsesRows() throws {
        let labels = try GeoLabels.parse("100034\tEpiaeschna heros\tSwamp Darner\n4848\tHaemorhous mexicanus\tHouse Finch\n")
        #expect(labels == [
            GeoLabel(scientificName: "Epiaeschna heros", commonName: "Swamp Darner"),
            GeoLabel(scientificName: "Haemorhous mexicanus", commonName: "House Finch"),
        ])
    }

    @Test("a row without three fields is rejected")
    func rejectsMalformedRow() {
        #expect(throws: LabelFileError.malformedRow(line: 1)) { try GeoLabels.parse("just one field\n") }
    }
}
