import Album
import Foundation
import ImageIO
import SwiftUI

/// What a picture file says of itself (issue #192, of #185): when it was taken and where, read from its EXIF and GPS tags.
/// A photo chosen from the library is read this way, since the system picker hands over the file and nothing about it: the
/// library's own record of the date and place would need permission to read the library, and the picker needs none.
nonisolated struct PhotoFacts: Equatable, Sendable {
    /// When the shutter opened; nil when the file has no date, or one no camera with a set clock would write.
    var takenAt: Date?
    /// Where it was taken, with the fix's accuracy when the file gives it (0 when it doesn't); nil without a fix.
    var place: Coordinate?

    /// The facts of the picture in `data`; nil when `data` is no picture.
    /// - Parameter timeZone: the clock a date written without an offset is read on. Cameras other than phones write local
    ///   time and seldom say which zone; the phone's own is the best guess there is.
    init?(of data: Data, timeZone: TimeZone = .current) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] != nil
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // When the picture was taken, else when it was made a file: a scan or an export has only the second.
        takenAt = Self.date(exif[kCGImagePropertyExifDateTimeOriginal], offset: exif[kCGImagePropertyExifOffsetTimeOriginal], timeZone: timeZone)
            ?? Self.date(exif[kCGImagePropertyExifDateTimeDigitized], offset: exif[kCGImagePropertyExifOffsetTimeDigitized], timeZone: timeZone)
        place = Self.place(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:])
    }

    /// "2026:04:18 06:42:10", with "-07:00" when the camera wrote its offset.
    private static func date(_ text: Any?, offset: Any?, timeZone: TimeZone) -> Date? {
        guard let text = text as? String else { return nil }
        let numbers = text.split(whereSeparator: { $0 == ":" || $0 == " " }).map { Int($0) }
        guard numbers.count == 6, let year = numbers[0], let month = numbers[1], let day = numbers[2], let hour = numbers[3], let minute = numbers[4], let second = numbers[5],
              year >= 1900, (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone(offset) ?? timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        // The 31st of a month with 30 days is no date: the calendar would otherwise roll it into the next month.
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// "+05:30" or "-07:00" as a zone.
    private static func zone(_ offset: Any?) -> TimeZone? {
        guard let offset = (offset as? String)?.trimmingCharacters(in: .whitespaces), let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        let parts = offset.dropFirst().split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hours = parts[0], let minutes = parts[1], hours <= 14, (0...59).contains(minutes) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60))
    }

    /// A fix as EXIF holds it: unsigned degrees with a hemisphere each. A camera with GPS and no fix yet writes 0° N 0° E,
    /// which is in the Gulf of Guinea and nowhere a bird was photographed.
    private static func place(_ gps: [CFString: Any]) -> Coordinate? {
        guard var latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue, var longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { longitude = -longitude }
        guard abs(latitude) <= 90, abs(longitude) <= 180, !(latitude == 0 && longitude == 0) else { return nil }
        let accuracy = (gps[kCGImagePropertyGPSHPositioningError] as? NSNumber)?.doubleValue ?? 0
        return Coordinate(latitude: latitude, longitude: longitude, accuracy: max(accuracy, 0))
    }
}

extension CapturedPhoto {
    /// A photo chosen from the library (issue #192), kept as it came: the file's own bytes. Its sighting takes the date and
    /// the place the picture carries. Without a date of its own it takes `now`; without a place of its own it takes the
    /// current one, which whoever writes it supplies (`place` stays nil). Nil when `data` is no picture.
    ///
    /// A date after `now` is not believed: a camera's clock was wrong, or its local time was read on a phone that has since
    /// travelled west, and a sighting can't be in the future.
    nonisolated static func chosenFromLibrary(_ data: Data, now: Date = .now, timeZone: TimeZone = .current) -> CapturedPhoto? {
        guard let facts = PhotoFacts(of: data, timeZone: timeZone) else { return nil }
        let own = facts.takenAt.flatMap { $0 <= now ? $0 : nil }
        return CapturedPhoto(data: data, takenAt: own ?? now, place: facts.place, origin: .library(carriesDate: own != nil))
    }
}

/// What "Name this bird" says under a photo just chosen from the library (issue #192): the sheet shows the date and place the
/// sighting will record, and this says whether they are the photo's own, since a picture from a real camera often carries a
/// date and no place, and one saved from a message carries neither.
enum LibraryPhotoText {
    /// Nil for the capture camera's photo, which was taken here and now.
    /// - Parameter currentPlace: the place a photo with none of its own is recorded at; nil when there is none.
    nonisolated static func note(for photo: CapturedPhoto, currentPlace: Coordinate?) -> String? {
        note(origin: photo.origin, place: photo.place, currentPlace: currentPlace)
    }

    /// The same, from what a photo says of itself without its picture.
    nonisolated static func note(origin: CapturedPhoto.Origin, place: Coordinate?, currentPlace: Coordinate?) -> String? {
        guard case .library(let carriesDate) = origin else { return nil }
        switch (carriesDate, place != nil, currentPlace != nil) {
        case (true, true, _): return "The sighting takes this photo's own date and place."
        case (true, false, true): return "This photo carries no place, so the sighting takes its date and the place you're at now."
        case (true, false, false): return "This photo carries no place, so the sighting takes its date and records no place."
        case (false, true, _): return "This photo carries no date, so the sighting takes its place and the time now."
        case (false, false, true): return "This photo carries no date or place, so the sighting takes the time and place now."
        case (false, false, false): return "This photo carries no date or place, so the sighting takes the time now and records no place."
        }
    }
}

#if DEBUG
extension DebugSeeds {
    /// A picture as the library would hand one over: the generated frame with a date and a place of its own, the morning of
    /// 18 April 2026 in San Diego. `-fakeLibraryPhoto YES` puts it behind the camera's library button in place of the system
    /// picker, so a UI test knows what the picture it chose carries.
    static func libraryPhotoJPEG() -> Data {
        let frame = frameJPEG()
        let data = NSMutableData()
        guard let source = CGImageSourceCreateWithData(frame as CFData, nil), let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithData(data, type, 1, nil)
        else { return frame }
        let place = DebugPlace.sanDiego.coordinate
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:04:18 06:42:10", kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: abs(place.latitude), kCGImagePropertyGPSLatitudeRef: place.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(place.longitude), kCGImagePropertyGPSLongitudeRef: place.longitude < 0 ? "W" : "E",
            ],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : frame
    }

    static let standInLibraryPhoto: Data? = UserDefaults.standard.bool(forKey: "fakeLibraryPhoto") ? libraryPhotoJPEG() : nil
}

extension EnvironmentValues {
    /// A picture the camera's library button hands over in place of the system picker; nil opens the picker. Set by
    /// `-fakeLibraryPhoto YES`, or by a test.
    @Entry var standInLibraryPhoto: Data? = DebugSeeds.standInLibraryPhoto
}
#endif
