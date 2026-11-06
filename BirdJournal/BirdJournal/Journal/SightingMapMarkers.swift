import Album
import CoreLocation
import MapKit
import SwiftData
import SwiftUI

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
    /// Its callout is up.
    var isChosen = false

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

/// `MKMapView`, since SwiftUI's `Map` has no clustering. Which sighting is chosen is ours: MapKit reports a tap and is left with nothing
/// selected, so the choice is the same whether its patch is on the map or gathered into a cluster.
struct SightingMap: UIViewRepresentable {
    let pins: [SightingPin]
    let centre: CLLocationCoordinate2D
    @Binding var selection: PersistentIdentifier?
    @Binding var here: [PersistentIdentifier]
    let style: SightingMapView.Style
    let showsUser: Bool

    /// A cluster tighter than this, in metres, is listed rather than zoomed into: GPS can't part it, and its sightings may share one fix.
    static let tightestZoom: CLLocationDistance = 50

    /// Whether zooming would part these coordinates, or they're at one spot.
    static func isOneSpot(_ coordinates: [CLLocationCoordinate2D]) -> Bool {
        guard let first = coordinates.first else { return true }
        let start = MKMapPoint(first)
        return coordinates.allSatisfy { start.distance(to: MKMapPoint($0)) < tightestZoom }
    }

    private static let pinID = "sighting-pin"
    private static let clusterID = "sighting-cluster"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(PatchPinView.self, forAnnotationViewWithReuseIdentifier: Self.pinID)
        map.register(PatchClusterView.self, forAnnotationViewWithReuseIdentifier: Self.clusterID)
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
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        context.coordinator.style = style
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = { selection = $0 }
        coordinator.onHere = { here = $0 }
        if coordinator.style != style {
            coordinator.style = style
            map.preferredConfiguration = style.configuration
        }
        if !coordinator.pins.elementsEqual(pins, by: ===) {
            map.removeAnnotations(coordinator.pins)
            coordinator.pins = pins
            map.addAnnotations(pins)
            coordinator.chosen = nil
        }
        if coordinator.chosen != selection {
            coordinator.choose(selection, on: map)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var pins: [SightingPin] = []
        var style = SightingMapView.Style.standard
        var chosen: PersistentIdentifier?
        var onSelect: (PersistentIdentifier?) -> Void = { _ in }
        var onHere: ([PersistentIdentifier]) -> Void = { _ in }

        func choose(_ id: PersistentIdentifier?, on map: MKMapView) {
            chosen = id
            for pin in pins where pin.isChosen || pin.id == id {
                pin.isChosen = pin.id == id
                (map.view(for: pin) as? PatchPinView)?.showChosen(animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is MKClusterAnnotation: mapView.dequeueReusableAnnotationView(withIdentifier: SightingMap.clusterID, for: annotation)
            case is SightingPin: mapView.dequeueReusableAnnotationView(withIdentifier: SightingMap.pinID, for: annotation)
            default: nil  // the birder's own dot
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            if let cluster = annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                let members = cluster.memberAnnotations.compactMap { $0 as? SightingPin }
                if SightingMap.isOneSpot(members.map(\.coordinate)) {
                    onSelect(nil)
                    onHere(members.sorted { $0.confirmedAt > $1.confirmedAt }.map(\.id))
                } else {
                    mapView.showAnnotations(members, animated: !UIAccessibility.isReduceMotionEnabled)
                }
            } else if let pin = annotation as? SightingPin {
                mapView.deselectAnnotation(pin, animated: false)
                onHere([])
                onSelect(pin.id)
            }
        }

        /// A tap on the map itself puts the callout away.
        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let map = tap.view as? MKMapView else { return }
            var view = map.hitTest(tap.location(in: map), with: nil)
            while let current = view {
                if current is MKAnnotationView { return }
                view = current.superview
            }
            onHere([])
            onSelect(nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// A sighting's patch: a plain picture, its ring in the place's tint while it's chosen.
private final class PatchPinView: MKAnnotationView {
    private let ring = CAShapeLayer()
    private var loading: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // MapKit reads this as the view is given its annotation: `prepareForDisplay` would be too late.
        clusteringIdentifier = "sightings"
        collisionMode = .circle
        canShowCallout = false
        displayPriority = .defaultHigh
        isAccessibilityElement = true
        accessibilityIdentifier = "map-patch"
        accessibilityTraits = .button
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.isHidden = true
        layer.addSublayer(ring)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: PatchPinView, _) in
            view.paintRing()
        }
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
        zPriority = pin.isFocus ? .max : .defaultUnselected
        accessibilityLabel = "\(pin.name), \(pin.confirmedAt.formatted(date: .abbreviated, time: .omitted))"
        let edition = PatchEdition.of(setID: pin.setID)
        let side = pin.isFocus ? MapPatchThumbnail.focusSide : MapPatchThumbnail.side
        image = MapPatchThumbnail.immediate(art: pin.art, edition: edition, side: side)
        let rect = MapPatchThumbnail.patchRect(edition: edition, side: side)
        ring.path = PatchOutline(shape: edition.shape).path(in: rect.insetBy(dx: -1.5, dy: -1.5)).cgPath
        paintRing()
        showChosen(animated: false)
        loading?.cancel()
        loading = Task { [weak self] in
            let done = await MapPatchThumbnail.load(art: pin.art, edition: edition, side: side)
            guard !Task.isCancelled else { return }
            self?.image = done
        }
    }

    private func paintRing() {
        guard let pin = annotation as? SightingPin else { return }
        ring.strokeColor = UIColor(PatchEdition.tint(setID: pin.setID)).resolvedColor(with: traitCollection).cgColor
    }

    func showChosen(animated: Bool) {
        let isChosen = (annotation as? SightingPin)?.isChosen ?? false
        ring.isHidden = !isChosen
        let change = { self.transform = isChosen ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity }
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
        isAccessibilityElement = true
        accessibilityIdentifier = "map-patch-cluster"
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: PatchClusterView, _) in
            view.draw()
        }
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        image = nil
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        draw()
    }

    private func draw() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let members = cluster.memberAnnotations.compactMap { $0 as? SightingPin }
        guard let newest = members.max(by: { $0.confirmedAt < $1.confirmedAt }) else { return }
        accessibilityLabel = "\(members.count) sightings, the newest \(newest.name)"
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
