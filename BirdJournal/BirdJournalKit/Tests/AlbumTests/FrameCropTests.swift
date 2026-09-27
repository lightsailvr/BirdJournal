import CoreGraphics
import Foundation
import Testing
@testable import Album

// Issue #11: the album shows the 2x center crop of the stored camera frame (spec user story 37), so the crop is a
// pure function over the frame's pixel size and the image, checked here without any view.
@Suite("FrameCrop")
struct FrameCropTests {
    @Test("the 2x center rect is the middle half of each side")
    func centerRect() {
        let rect = FrameCrop.centerRect(in: CGSize(width: 640, height: 480), zoom: 2)
        #expect(rect == CGRect(x: 160, y: 120, width: 320, height: 240))
    }

    @Test("odd sizes round to whole pixels and stay inside the frame")
    func oddSizes() {
        let rect = FrameCrop.centerRect(in: CGSize(width: 7, height: 5), zoom: 2)
        #expect(rect.width == 3 && rect.height == 2)
        #expect(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 7 && rect.maxY <= 5)
        #expect(rect.minX == rect.minX.rounded() && rect.minY == rect.minY.rounded())
    }

    @Test("zoom 1 is the whole frame and zoom below 1 is clamped to it")
    func zoomOneIsIdentity() {
        let size = CGSize(width: 640, height: 480)
        #expect(FrameCrop.centerRect(in: size, zoom: 1) == CGRect(origin: .zero, size: size))
        #expect(FrameCrop.centerRect(in: size, zoom: 0.5) == CGRect(origin: .zero, size: size))
    }

    @Test("cropping a 4 × 4 image keeps its central 2 × 2 pixels")
    func cropsTheCenterPixels() throws {
        // Row-major grey values: pixel (x, y) is 16 * y + x, so the center block is 5, 6, 9, 10.
        let pixels = (0..<16).map(UInt8.init)
        let image = try #require(Self.greyImage(width: 4, height: 4, pixels: pixels))

        let cropped = try #require(FrameCrop.centerCrop(image, zoom: 2))

        #expect(cropped.width == 2 && cropped.height == 2)
        #expect(Self.greyPixels(of: cropped) == [5, 6, 9, 10])
    }

    private static func greyImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func greyPixels(of image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(
            data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}
