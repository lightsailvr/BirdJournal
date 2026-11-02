import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The glasses photo as it leaves the phone for an art job (issue #68, spec v2 story 59): every face Vision finds is
/// blurred past recognition, the picture is turned upright, and it is written as a fresh JPEG with no metadata at all
/// (no place, time, device or orientation tags), so strangers are never painted into a card and nothing about the
/// birder rides along. The original on the phone is untouched.
enum ArtPhoto {
    enum Failure: Error, Equatable {
        case unreadable
        case unwritable
    }

    /// How far past Vision's box the blur reaches, of the box's size on each side: the box is tight around the face,
    /// and hair, ears and jaw identify a person too.
    static let faceMargin: CGFloat = 0.35
    static let jpegQuality: CGFloat = 0.9

    /// The prepared JPEG, and how many faces were blurred.
    static func prepare(jpeg: Data) throws -> (jpeg: Data, faces: Int) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        var picture = CIImage(cgImage: image)
        if let orientation, let exif = CGImagePropertyOrientation(rawValue: orientation), exif != .up {
            picture = picture.oriented(exif)
        }
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        let faces = try faceBoxes(in: picture)
        let blurred = blur(faces, in: picture)
        return (try encode(blurred), faces.count)
    }

    /// Every face in the picture, in its pixel coordinates (Core Image's, origin bottom left).
    static func faceBoxes(in picture: CIImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(ciImage: picture, options: [:]).perform([request])
        let size = picture.extent.size
        return (request.results ?? []).map { VNImageRectForNormalizedRect($0.boundingBox, Int(size.width), Int(size.height)) }
    }

    /// The faces pixellated coarsely, then blurred over, inside an ellipse a margin larger than each box.
    static func blur(_ faces: [CGRect], in picture: CIImage) -> CIImage {
        guard !faces.isEmpty else { return picture }
        let extent = picture.extent
        var mask = CIImage(color: .black).cropped(to: extent)
        for face in faces {
            let grown = face.insetBy(dx: -face.width * faceMargin, dy: -face.height * faceMargin).intersection(extent)
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: grown.midX, y: grown.midY)
            let radius = max(grown.width, grown.height) / 2
            gradient.radius0 = Float(radius * 0.85)
            gradient.radius1 = Float(radius)
            gradient.color0 = .white
            gradient.color1 = .black
            if let spot = gradient.outputImage?.cropped(to: extent) {
                mask = spot.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
        }
        let scale = max(extent.width, extent.height)
        let pixellated = picture.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale / 24]).cropped(to: extent)
        let hidden = pixellated.clampedToExtent().applyingGaussianBlur(sigma: Double(scale / 60)).cropped(to: extent)
        return hidden.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: picture, kCIInputMaskImageKey: mask])
    }

    /// A JPEG from the pixels alone: a new image destination with only the quality set, so no source metadata can carry
    /// over.
    static func encode(_ picture: CIImage) throws -> Data {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let rendered = context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw Failure.unwritable
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unwritable }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable }
        return output as Data
    }
}
