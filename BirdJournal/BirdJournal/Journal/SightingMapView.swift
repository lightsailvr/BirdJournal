import Album
import CoreLocation
import MapKit
import Pack
import SwiftData
import SwiftUI

/// Every located sighting in the journal on one map (issue #44), opened from a sighting's map card: that sighting's
/// pin is selected with its callout up, every other sighting is a smaller pin, and selecting one shows its callout
/// with Open, which pushes its detail. Pan, zoom, the user's own dot and the locate button when location is allowed,
/// standard or satellite. No clustering in v1. Phone-only: nothing here reaches the lens or a share.
struct SightingMapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PackLibrary.self) private var library
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    @State private var position: MapCameraPosition
    @State private var selection: PersistentIdentifier?
    @State private var style = Style.standard
    private let focusID: PersistentIdentifier
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

        var mapStyle: MapStyle {
            switch self {
            case .standard: .standard
            case .satellite: .imagery
            }
        }
    }

    /// Opens on `focus`, a kilometre across, with its pin selected.
    init(focus: Sighting) {
        focusID = focus.persistentModelID
        _selection = State(initialValue: focus.persistentModelID)
        let centre = focus.location?.clCoordinate ?? CLLocationCoordinate2D()
        _position = State(initialValue: .region(MKCoordinateRegion(center: centre, latitudinalMeters: 1_000, longitudinalMeters: 1_000)))
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
            Map(position: $position, selection: $selection) {
                ForEach(located) { sighting in
                    if let centre = sighting.location?.clCoordinate {
                        if sighting.persistentModelID == focusID {
                            Marker(library.commonName(for: sighting), coordinate: centre)
                                .tint(Color.moss)
                                .tag(sighting.persistentModelID)
                        } else {
                            Annotation(library.commonName(for: sighting), coordinate: centre, anchor: .center) {
                                SmallPin(isSelected: sighting.persistentModelID == selection)
                            }
                            .annotationTitles(.hidden)
                            .tag(sighting.persistentModelID)
                        }
                    }
                }
                if userLocationAllowed { UserAnnotation() }
            }
            .mapStyle(style.mapStyle)
            .mapControls {
                if userLocationAllowed { MapUserLocationButton() }
                MapCompass()
            }
            .accessibilityIdentifier("sighting-map")
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                if let selected {
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
    }
}

/// Another sighting's pin: a moss dot, larger while selected.
private struct SmallPin: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color.moss)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: isSelected ? 22 : 14, height: isSelected ? 22 : 14)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// The selected sighting under the map: the common name, the date and the place, and Open for a sighting other than
/// the one the map was opened from (that one is already open behind the sheet).
private struct Callout: View {
    @Environment(PlaceNames.self) private var places
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    let isFocus: Bool

    var body: some View {
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
        .padding(16)
        .background(Color.paper, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sighting-map-callout")
        .task(id: sighting.persistentModelID) {
            if let location = sighting.location { await places.resolve(location) }
        }
    }
}
