import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Invite links (issues #61, #150): `https://featherguild.matthewcelia.com/i/<token>`. The associated-domains entitlement
/// opens them in the app; in a browser the domain shows a page explaining how to get it. Links made on the former host
/// are still out there, on phones and printed as QR codes, so they read the same way.
enum InviteLink {
    static let host = "featherguild.matthewcelia.com"
    static let formerHost = "birdquest.matthewcelia.com"

    /// The invite token in a link, or nil for any other URL.
    static func token(from url: URL) -> String? {
        guard url.scheme == "https", url.host() == host || url.host() == formerHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "i" else { return nil }
        let token = parts[1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !token.isEmpty, token.count <= 64, token.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return token
    }

    static func url(token: String) -> URL {
        URL(string: "https://\(host)/i/\(token)")!
    }
}

/// The QR code for an invite: the link itself, so scanning it opens the same join screen.
enum InviteQRCode {
    /// A crisp black-on-white code, scaled by whole pixels (no smoothing) to at least `side` points.
    static func image(for url: URL, side: CGFloat = 240) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (side * 3 / output.extent.width).rounded(.up))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 3, orientation: .up)
    }

    /// What a QR code in an image says: the tests read the generated code back with it.
    static func decode(_ image: UIImage) -> String? {
        guard let cgImage = image.cgImage,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
