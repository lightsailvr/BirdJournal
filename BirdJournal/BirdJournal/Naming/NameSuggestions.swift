import Identification
import SwiftUI

// Issue #189 (of #185): where "Name this bird" gets what it suggests before anything is typed. The ranking itself is
// `NameableBirds.search(_:in:)`; this is what the sheet reads the run and the geomodel through.

extension EnvironmentValues {
    /// The geomodel "Name this bird" reads its likely birds from: the bundled one, shared with the run's engine and the
    /// rarity reader, unless a test stands one in.
    @Entry var occurrenceModel: any SpeciesOccurrenceModel = BundledIdentification.geoModel
}

extension ListeningCoordinator {
    /// The scientific names of the birds heard on the run under way, or the one under review, as the run lists them:
    /// calling now first, then the most recently heard. None without a run.
    var heardScientificNames: [String] {
        state == .idle ? [] : orderedCandidates.map(\.species.scientificName)
    }

    /// The birds heard on the run `unnamed` was taken on, while that run is under way or under review; none for a photo
    /// from an earlier run or from no run, named later from the Collection: what this run hears says nothing about it.
    func heardScientificNames(for unnamed: UnnamedSighting) -> [String] {
        sightings.unnamed.contains { $0.id == unnamed.id } ? heardScientificNames : []
    }
}
