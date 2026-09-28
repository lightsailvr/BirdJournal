import Album
import CoreLocation
import MapKit
import Observation

/// Place names for the album's sightings (spec user story 35: "photo, species, date and place"). A sighting stores
/// only a coordinate, so the name comes from reverse geocoding when the phone is online, cached per run, and the
/// row shows the coordinate until then, or for good when offline.
@MainActor
@Observable
final class PlaceNames {
    /// Coordinates within about a hundred metres (0.001°) share one lookup.
    private struct Key: Hashable {
        let latitude: Int
        let longitude: Int

        init(_ coordinate: Coordinate) {
            latitude = Int((coordinate.latitude * 1_000).rounded())
            longitude = Int((coordinate.longitude * 1_000).rounded())
        }
    }

    private var names: [Key: String] = [:]
    @ObservationIgnored private var attempted: Set<Key> = []

    /// The name already known for `coordinate`, e.g. "Griffith Park, Los Angeles".
    func name(for coordinate: Coordinate) -> String? {
        names[Key(coordinate)]
    }

    /// The album's place line: the name when known, the coordinate until then, "No location" without a fix.
    func placeText(for coordinate: Coordinate?) -> String {
        guard let coordinate else { return "No location" }
        return name(for: coordinate) ?? coordinate.formatted
    }

    /// Looks the name up once per coordinate and run; a failure (offline, no result) leaves the coordinate showing.
    func resolve(_ coordinate: Coordinate) async {
        let key = Key(coordinate)
        guard !attempted.contains(key) else { return }
        attempted.insert(key)
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        guard let items = try? await request.mapItems, let item = items.first else { return }
        // A city with its context, or a city, and nothing finer: the name is shown on the phone as the approximate
        // place and shared as the "general area", so a street never comes back from here (issue #28).
        let representations = item.addressRepresentations
        guard let name = representations?.cityWithContext ?? representations?.cityName else { return }
        names[key] = name
    }
}
