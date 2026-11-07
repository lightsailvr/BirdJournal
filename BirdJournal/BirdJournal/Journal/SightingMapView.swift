import Album
import CoreLocation
import MapKit
import Pack
import SwiftData
import SwiftUI

/// Every located sighting in the journal on one map (issue #44), opened from a sighting's map card: each is a tiny flat patch in
/// its edition's shape (issue #150, A5), and MapKit gathers the ones too close to tell apart into a cluster showing the newest. A tap on
/// a cluster zooms into it, or lists its sightings when they're all at one spot, as a run's are. That sighting's patch is larger with
/// its callout up, it's never gathered into a cluster, and selecting another shows its callout with Open, which pushes its detail. Pan, zoom, the user's own dot and the locate button when location is allowed, standard or satellite.
/// Phone-only: nothing here reaches the lens or a share.
struct SightingMapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    @State private var pins: [SightingPin] = []
    @State private var selection: PersistentIdentifier?
    /// The sightings of a cluster too tight to zoom apart, listed under the map.
    @State private var here: [PersistentIdentifier] = []
    @State private var style = Style.standard
    private let focusID: PersistentIdentifier
    private let centre: CLLocationCoordinate2D
    private let userLocationAllowed: Bool

    /// The toolbar's choice of map: the standard map or satellite imagery.
    enum Style: String, CaseIterable, Identifiable {
        case standard
        case satellite

        var id: Self { self }

        var title: String {
            switch self {
            case .standard: "Standard"
            case .satellite: "Satellite"
            }
        }

        var configuration: MKMapConfiguration {
            switch self {
            case .standard: MKStandardMapConfiguration()
            case .satellite: MKImageryMapConfiguration()
            }
        }
    }

    /// Opens on `focus`, a kilometre across, with its pin selected.
    init(focus: Sighting) {
        focusID = focus.persistentModelID
        _selection = State(initialValue: focus.persistentModelID)
        centre = focus.location?.clCoordinate ?? CLLocationCoordinate2D()
        let status = CLLocationManager().authorizationStatus
        userLocationAllowed = status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private var located: [Sighting] { sightings.filter { $0.location != nil } }

    private var selected: Sighting? {
        guard let selection else { return nil }
        return located.first { $0.persistentModelID == selection }
    }

    var body: some View {
        NavigationStack {
            SightingMap(pins: pins, centre: centre, selection: $selection, here: $here, style: style, showsUser: userLocationAllowed)
            .accessibilityIdentifier("sighting-map")
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                if !here.isEmpty {
                    SightingsHere(sightings: sightings(in: here), focusID: focusID)
                        .padding(.horizontal, JournalLayout.margin)
                        .padding(.vertical, 12)
                } else if let selected {
                    Callout(sighting: selected, isFocus: selected.persistentModelID == focusID)
                        .padding(.horizontal, JournalLayout.margin)
                        .padding(.vertical, 12)
                }
            }
            .navigationTitle("On the map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Map style", selection: $style) {
                        ForEach(Style.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .appDestinations()
        }
        .task(id: located.map(\.persistentModelID)) {
            pins = makePins()
        }
        // A download that finishes with the map open paints its blanks.
        .onChange(of: library.packs.count) { pins = makePins() }
    }

    private func sightings(in ids: [PersistentIdentifier]) -> [Sighting] {
        let ids = Set(ids)
        return located.filter { ids.contains($0.persistentModelID) }
    }

    /// One pin per located sighting. A bird's painting and name are found once per bird and edition, however many sightings it has.
    private func makePins() -> [SightingPin] {
        let collection = collectionStore.collection
        var birds: [CardCollection.Patch.Key: (art: PatchArt?, name: String)] = [:]
        let pins: [SightingPin] = located.compactMap { sighting in
            guard let coordinate = sighting.location?.clCoordinate else { return nil }
            let setID = collection.patch(of: sighting.identifier)?.placement.setID
            let key = CardCollection.Patch.Key(speciesID: sighting.scientificName, setID: setID)
            let bird = birds[key] ?? (library.patchArt(scientificName: sighting.scientificName, setID: setID), library.commonName(for: sighting))
            birds[key] = bird
            return SightingPin(
                id: sighting.persistentModelID, coordinate: coordinate, name: bird.name,
                confirmedAt: sighting.confirmedAt, art: bird.art, setID: setID, isFocus: sighting.persistentModelID == focusID
            )
        }
        if let focus = pins.first(where: \.isFocus) {
            focus.othersHere = pins.count { !$0.isFocus && SightingMap.isOneSpot([focus.coordinate, $0.coordinate]) }
        }
        return pins
    }
}

/// A cluster's sightings under the map, when they're at one spot and no zoom would part them: a run's birds share its place.
private struct SightingsHere: View {
    let sightings: [Sighting]
    let focusID: PersistentIdentifier

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sightings.count) sightings here")
                .font(JournalFont.rowTitle)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sightings) { sighting in
                        Callout(sighting: sighting, isFocus: sighting.persistentModelID == focusID, isInList: true)
                        RowRule()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(16)
        .background(Color.paper, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sighting-map-here")
    }
}

/// The selected sighting under the map: the common name, the date and the place, and Open for a sighting other than
/// the one the map was opened from (that one is already open behind the sheet).
private struct Callout: View {
    @Environment(PlaceNames.self) private var places
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    let isFocus: Bool
    /// One row of `SightingsHere`, which is the card.
    var isInList = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(library.commonName(for: sighting))
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                Text(sighting.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                Text(places.placeText(for: sighting.location))
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            if !isFocus {
                Spacer(minLength: 8)
                NavigationLink(value: Route.sighting(sighting.persistentModelID)) {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .buttonStyle(.journalOutlined)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isInList ? 8 : 16)
        .padding(.horizontal, isInList ? 0 : 16)
        .background(isInList ? Color.clear : Color.paper, in: shape)
        .overlay(shape.strokeBorder(isInList ? Color.clear : Color.rule, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sighting-map-callout")
        .task(id: sighting.persistentModelID) {
            if let location = sighting.location { await places.resolve(location) }
        }
    }
}
