import Album
import CoreLocation
import MapKit
import Pack
import SwiftData
import SwiftUI

/// Every located sighting in the journal on one map (issue #44), opened from a sighting's map card: each is a tiny flat patch in
/// its edition's shape (issue #150, A5), MapKit gathers the ones too close to tell apart into a cluster showing the newest, and a tap on
/// a cluster zooms into it. That sighting's patch is larger with its callout up, and selecting another shows its callout with Open,
/// which pushes its detail. Pan, zoom, the user's own dot and the locate button when location is allowed, standard or satellite.
/// Phone-only: nothing here reaches the lens or a share.
struct SightingMapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PackLibrary.self) private var library
    @Environment(CollectionStore.self) private var collectionStore
    @Query(Sighting.newestFirst()) private var sightings: [Sighting]
    @State private var pins: [SightingPin] = []
    @State private var selection: PersistentIdentifier?
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
            SightingMap(pins: pins, centre: centre, selection: $selection, style: style, showsUser: userLocationAllowed)
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
        .task(id: located.map(\.persistentModelID)) {
            pins = makePins()
        }
    }

    /// One pin per located sighting. A bird's painting and name are found once per bird and edition, however many sightings it has.
    private func makePins() -> [SightingPin] {
        let collection = collectionStore.collection
        var arts: [CardCollection.Patch.Key: PatchArt?] = [:]
        return located.compactMap { sighting in
            guard let coordinate = sighting.location?.clCoordinate else { return nil }
            let setID = collection.patch(of: sighting.identifier)?.placement.setID
            let key = CardCollection.Patch.Key(speciesID: sighting.scientificName, setID: setID)
            let art: PatchArt?
            if let known = arts[key] {
                art = known
            } else {
                art = library.patchArt(scientificName: sighting.scientificName, setID: setID)
                arts[key] = art
            }
            return SightingPin(
                id: sighting.persistentModelID, coordinate: coordinate, name: library.commonName(for: sighting),
                confirmedAt: sighting.confirmedAt, art: art, setID: setID, isFocus: sighting.persistentModelID == focusID
            )
        }
    }
}

/// One sighting on the map.
final class SightingPin: NSObject, MKAnnotation {
    let id: PersistentIdentifier
    let coordinate: CLLocationCoordinate2D
    /// Not the annotation's `title`, which would have MapKit draw a callout of its own over the patch: ours is under the map.
    let name: String
    let confirmedAt: Date
    let art: PatchArt?
    /// The patch's set, nil for Uncharted: its shape, and the place's tint.
    let setID: String?
    let isFocus: Bool

    init(id: PersistentIdentifier, coordinate: CLLocationCoordinate2D, name: String, confirmedAt: Date, art: PatchArt?, setID: String?, isFocus: Bool) {
        self.id = id
        self.coordinate = coordinate
        self.name = name
        self.confirmedAt = confirmedAt
        self.art = art
        self.setID = setID
        self.isFocus = isFocus
    }
}

/// `MKMapView`, since SwiftUI's `Map` has no clustering.
private struct SightingMap: UIViewRepresentable {
    let pins: [SightingPin]
    let centre: CLLocationCoordinate2D
    @Binding var selection: PersistentIdentifier?
    let style: SightingMapView.Style
    let showsUser: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(PatchPinView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        map.register(PatchClusterView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        var across: CLLocationDistance = 1_000
        #if DEBUG
        // `-autoMapAcross <metres>`: a wider map to begin with, for the screenshots of more than one edition.
        let wider = UserDefaults.standard.double(forKey: "autoMapAcross")
        if wider > 0 { across = wider }
        #endif
        map.setRegion(MKCoordinateRegion(center: centre, latitudinalMeters: across, longitudinalMeters: across), animated: false)
        map.showsCompass = true
        map.showsUserLocation = showsUser
        map.showsUserTrackingButton = showsUser
        map.preferredConfiguration = style.configuration
        context.coordinator.style = style
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = { selection = $0 }
        if coordinator.style != style {
            coordinator.style = style
            map.preferredConfiguration = style.configuration
        }
        if coordinator.pins.map(\.id) != pins.map(\.id) {
            map.removeAnnotations(coordinator.pins)
            coordinator.pins = pins
            map.addAnnotations(pins)
        }
        let shown = map.selectedAnnotations.compactMap { $0 as? SightingPin }.first
        if shown?.id != selection {
            if let selection, let pin = pins.first(where: { $0.id == selection }) {
                map.selectAnnotation(pin, animated: false)
            } else if let shown {
                map.deselectAnnotation(shown, animated: false)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var pins: [SightingPin] = []
        var style = SightingMapView.Style.standard
        var onSelect: (PersistentIdentifier?) -> Void = { _ in }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            if let cluster = annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: !UIAccessibility.isReduceMotionEnabled)
            } else if let pin = annotation as? SightingPin {
                onSelect(pin.id)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: any MKAnnotation) {
            guard annotation is SightingPin, mapView.selectedAnnotations.isEmpty else { return }
            onSelect(nil)
        }
    }
}

/// A sighting's patch: a plain picture, its ring in the place's tint while selected.
private final class PatchPinView: MKAnnotationView {
    private let ring = CAShapeLayer()
    private var loading: Task<Void, Never>?

    /// The map's opening sighting stays out of every cluster, so it can always be found. MapKit reads this as the view is given its
    /// annotation, before `prepareForDisplay`, which would be too late.
    private static func clusterID(for annotation: (any MKAnnotation)?) -> String? {
        (annotation as? SightingPin)?.isFocus == true ? nil : "sightings"
    }

    override var annotation: (any MKAnnotation)? {
        didSet { clusteringIdentifier = Self.clusterID(for: annotation) }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        canShowCallout = false
        clusteringIdentifier = Self.clusterID(for: annotation)
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.isHidden = true
        layer.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        image = nil
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let pin = annotation as? SightingPin else { return }
        displayPriority = pin.isFocus ? .required : .defaultHigh
        zPriority = pin.isFocus ? .max : .defaultUnselected
        accessibilityLabel = "\(pin.name), \(pin.confirmedAt.formatted(date: .abbreviated, time: .omitted))"
        accessibilityIdentifier = "map-patch"
        let edition = PatchEdition.of(setID: pin.setID)
        let side = pin.isFocus ? MapPatchThumbnail.focusSide : MapPatchThumbnail.side
        image = MapPatchThumbnail.immediate(art: pin.art, edition: edition, side: side)
        drawRing(edition: edition, side: side, setID: pin.setID)
        loading?.cancel()
        loading = Task { [weak self] in
            let done = await MapPatchThumbnail.load(art: pin.art, edition: edition, side: side)
            guard !Task.isCancelled else { return }
            self?.image = done
        }
    }

    private func drawRing(edition: PatchEdition, side: CGFloat, setID: String?) {
        let rect = MapPatchThumbnail.patchRect(edition: edition, side: side)
        ring.path = PatchOutline(shape: edition.shape).path(in: rect.insetBy(dx: -1.5, dy: -1.5)).cgPath
        ring.strokeColor = UIColor(PatchEdition.tint(setID: setID)).resolvedColor(with: traitCollection).cgColor
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        ring.isHidden = !selected
        let change = { self.transform = selected ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: change)
        } else {
            change()
        }
    }
}

/// A cluster of sightings: the newest one's patch, with how many.
private final class PatchClusterView: MKAnnotationView {
    private var loading: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        canShowCallout = false
        displayPriority = .defaultHigh
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        image = nil
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let members = cluster.memberAnnotations.compactMap { $0 as? SightingPin }
        guard let newest = members.max(by: { $0.confirmedAt < $1.confirmedAt }) else { return }
        accessibilityLabel = "\(members.count) sightings, the newest \(newest.name). Zooms in."
        accessibilityIdentifier = "map-patch-cluster"
        accessibilityTraits = .button
        let edition = PatchEdition.of(setID: newest.setID)
        let tint = UIColor(PatchEdition.tint(setID: newest.setID)).resolvedColor(with: traitCollection)
        let ink = UIColor(Color.mossText).resolvedColor(with: traitCollection)
        let count = members.count
        image = MapPatchThumbnail.cluster(MapPatchThumbnail.immediate(art: newest.art, edition: edition), count: count, tint: tint, ink: ink)
        loading?.cancel()
        loading = Task { [weak self] in
            let done = await MapPatchThumbnail.load(art: newest.art, edition: edition)
            guard !Task.isCancelled else { return }
            self?.image = MapPatchThumbnail.cluster(done, count: count, tint: tint, ink: ink)
        }
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
