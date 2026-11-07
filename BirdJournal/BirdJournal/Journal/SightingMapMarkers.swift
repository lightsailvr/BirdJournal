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
        map.register(PatchPinView.self, forAnnotationViewWithReuseIdentifier: PatchPinView.focusIdentifier)
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
            case let pin as SightingPin:
                mapView.dequeueReusableAnnotationView(withIdentifier: pin.isFocus ? PatchPinView.focusIdentifier : SightingMap.pinID, for: annotation)
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
                // The opening sighting is out of the clusters: the rest of its spot may be right under it.
                let start = MKMapPoint(pin.coordinate)
                let spot = pin.isFocus ? pins.filter { start.distance(to: MKMapPoint($0.coordinate)) < SightingMap.tightestZoom } : []
                if spot.count > 1 {
                    onSelect(nil)
                    onHere(spot.sorted { $0.confirmedAt > $1.confirmedAt }.map(\.id))
                } else {
                    onHere([])
                    onSelect(pin.id)
                }
            }
        }

        /// A chosen patch gathered into a cluster by a zoom: the callout shouldn't name a bird the map no longer shows.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard let chosen, let pin = pins.first(where: { $0.id == chosen }), !pin.isFocus, mapView.view(for: pin)?.cluster != nil else { return }
            onSelect(nil)
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

/// An annotation view of a fixed size, whose picture is a sublayer. Setting `MKAnnotationView.image`, or nilling it on reuse, tells MapKit the
/// view's metrics changed, and it clusters again, which makes more views and sets more pictures: at 5,000 sightings a pan never settled
/// (issue #150's review; `AtlasUITests.testTheMapAnswersAtFiveThousandSightings`). A new picture here changes nothing MapKit reads.
private class FixedPictureView: MKAnnotationView {
    let picture = CALayer()

    init(annotation: (any MKAnnotation)?, reuseIdentifier: String?, size: CGSize) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: size)
        canShowCallout = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        picture.frame = bounds
        picture.contentsGravity = .center
        picture.actions = ["contents": NSNull(), "contentsScale": NSNull()]
        layer.addSublayer(picture)
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    func show(_ image: UIImage) {
        picture.contentsScale = image.scale
        picture.contents = image.cgImage
    }
}

/// A sighting's patch, in a view as big as a tap's target: a plain picture, its ring in the place's tint while it's chosen. The sighting
/// the map opened on is larger and stays out of every cluster, with nothing colliding with it, so the map always shows the bird its
/// callout names, and a cluster near it stays too.
private final class PatchPinView: FixedPictureView {
    static let focusIdentifier = "sighting-pin-focus"

    private let isFocus: Bool
    private var ring: CAShapeLayer?
    private var loading: Task<Void, Never>?

    private var side: CGFloat { isFocus ? MapPatchThumbnail.focusSide : MapPatchThumbnail.side }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        isFocus = reuseIdentifier == Self.focusIdentifier
        let extent = isFocus ? MapPatchThumbnail.focusSide + 12 : 44
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier, size: CGSize(width: extent, height: extent))
        // MapKit reads this as the view is given its annotation, and it never changes for a view of this identifier.
        clusteringIdentifier = isFocus ? nil : "sightings"
        collisionMode = isFocus ? .none : .circle
        displayPriority = isFocus ? .required : .defaultHigh
        zPriority = isFocus ? .max : .defaultUnselected
        accessibilityIdentifier = "map-patch"
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    override var accessibilityLabel: String? {
        get {
            guard let pin = annotation as? SightingPin else { return nil }
            return "\(pin.name), \(pin.confirmedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        set {}
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let pin = annotation as? SightingPin else { return }
        let edition = PatchEdition.of(setID: pin.setID)
        let side = side
        show(MapPatchThumbnail.immediate(art: pin.art, edition: edition, side: side))
        showChosen(animated: false)
        loading?.cancel()
        loading = nil
        if !MapPatchThumbnail.isFinished(art: pin.art, edition: edition, side: side) {
            loading = Task { [weak self] in
                let done = await MapPatchThumbnail.load(art: pin.art, edition: edition, side: side)
                guard !Task.isCancelled else { return }
                self?.show(done)
            }
        }
    }

    /// A ring only for the patch that needs one: thousands of these are made for a map that shows a few.
    private func makeRing(for pin: SightingPin) -> CAShapeLayer {
        let ring = self.ring ?? {
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.lineWidth = 2.5
            ring.actions = ["hidden": NSNull()]
            layer.addSublayer(ring)
            self.ring = ring
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: PatchPinView, _) in
                view.paintRing()
            }
            return ring
        }()
        let edition = PatchEdition.of(setID: pin.setID)
        let rect = MapPatchThumbnail.patchRect(edition: edition, side: side)
        let offset = CGPoint(x: (bounds.width - rect.width) / 2, y: (bounds.height - rect.height) / 2)
        let centred = CGRect(origin: offset, size: rect.size)
        ring.path = PatchOutline(shape: edition.shape).path(in: centred.insetBy(dx: -1.5, dy: -1.5)).cgPath
        return ring
    }

    private func paintRing() {
        guard let pin = annotation as? SightingPin else { return }
        ring?.strokeColor = UIColor(PatchEdition.tint(setID: pin.setID)).resolvedColor(with: traitCollection).cgColor
    }

    func showChosen(animated: Bool) {
        let pin = annotation as? SightingPin
        let isChosen = pin?.isChosen ?? false
        if isChosen, let pin {
            _ = makeRing(for: pin)
            paintRing()
        }
        ring?.isHidden = !isChosen
        // Under the view's own bounds, which MapKit reads.
        let scale = isChosen ? CATransform3DMakeScale(1.2, 1.2, 1) : CATransform3DIdentity
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2) { self.layer.sublayerTransform = scale }
        } else {
            layer.sublayerTransform = scale
        }
    }
}

/// A cluster of sightings: the newest one's patch, with how many.
private final class PatchClusterView: FixedPictureView {
    private var loading: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier, size: MapPatchThumbnail.clusterSize)
        collisionMode = .circle
        displayPriority = .defaultHigh
        accessibilityIdentifier = "map-patch-cluster"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: PatchClusterView, _) in
            view.draw()
        }
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

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
        show(MapPatchThumbnail.cluster(MapPatchThumbnail.immediate(art: newest.art, edition: edition), count: count, tint: tint, ink: ink))
        loading?.cancel()
        loading = nil
        if !MapPatchThumbnail.isFinished(art: newest.art, edition: edition) {
            loading = Task { [weak self] in
                let done = await MapPatchThumbnail.load(art: newest.art, edition: edition)
                guard !Task.isCancelled else { return }
                self?.show(MapPatchThumbnail.cluster(done, count: count, tint: tint, ink: ink))
            }
        }
    }
}
