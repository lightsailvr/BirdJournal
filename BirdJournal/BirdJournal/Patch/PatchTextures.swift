import ImageIO
import OSLog
import Pack
import SwiftUI

/// A patch's painting on the phone (the pack's `PackPatch`), what `PatchView` lights.
nonisolated struct PatchArt: Hashable, Sendable {
    let colour: URL
    /// Height in red, the cord in green, the stitch order in blue, at half size.
    let layers: URL
    /// The bare twill's colour: what an unstitched pattern shows.
    let ground: String
    /// Where each stitch layer starts on the order's 0...255, the last being 255 (`PackPatch`): the stitch-in's threads.
    var stitchBounds: [Int] = []
}

/// What stands where a found bird's painting goes (issue #138, guide page 15). It's only ever a bird you did find: one you
/// haven't has no patch at all.
nonisolated enum PatchArtState: Hashable, Sendable {
    case painted(PatchArt)
    /// The sighting is saved and the edition's pack is on its way: the blank, saying "Being sewn", until it arrives.
    case beingSewn
    /// Nothing is coming: Uncharted, a pack that isn't on the phone, a bird it has no painting of. The blank with the bird's
    /// name on a paper tag. Never an error patch: the sighting and the paper card are complete.
    case tagged

    var art: PatchArt? {
        if case .painted(let art) = self { return art }
        return nil
    }

    static func of(art: PatchArt?, setID: String?, transfer: PackLibrary.Status?) -> PatchArtState {
        if let art { return .painted(art) }
        guard setID != nil else { return .tagged }
        switch transfer {
        case .downloading, .installing: return .beingSewn
        default: return .tagged
        }
    }
}

extension PackLibrary {
    /// A bird's painting in one edition; nil when that edition's pack isn't on the phone, or it has no painting of the
    /// bird, or the patch is Uncharted. A patch is never drawn with another edition's painting (guide page 7).
    func patchArt(scientificName: String, setID: String?) -> PatchArt? {
        #if DEBUG
        if FakePatchArt.current != nil { return nil }
        #endif
        return patch(scientificName: scientificName, setID: setID).map { found in
            PatchArt(colour: found.pack.patchURL(for: found.patch), layers: found.pack.patchLayersURL(for: found.patch), ground: found.patch.ground, stitchBounds: found.patch.stitchBounds)
        }
    }

    /// What a found bird's patch shows in one edition.
    func patchArtState(scientificName: String, setID: String?) -> PatchArtState {
        #if DEBUG
        if FakePatchArt.current == .sewing, setID != nil { return .beingSewn }
        #endif
        let transfer = setID.flatMap { id in index?.descriptor(id: id).map(status(of:)) }
        return .of(art: patchArt(scientificName: scientificName, setID: setID), setID: setID, transfer: transfer)
    }
}

#if DEBUG
/// `-fakePatchArt missing|sewing` (issue #138): every patch without its painting, as when its pack hasn't come or is on its
/// way, for the states' UI tests and screenshots: the bundled pack is always on the simulator.
enum FakePatchArt: String {
    case missing, sewing

    static var current: FakePatchArt? {
        UserDefaults.standard.string(forKey: "fakePatchArt").flatMap(FakePatchArt.init(rawValue:))
    }
}
#endif

/// The decoded pictures of a patch at one of two sizes, decoded off the main thread and kept while memory allows. A
/// board's thumbnails decode smaller than a page's patch: at 30 on screen the shader's cost is their pixels (guide page 18).
@MainActor
enum PatchTextures {
    enum Size: Sendable {
        case thumbnail, full

        var colourPixels: Int { self == .thumbnail ? 360 : 720 }
        var layerPixels: Int { self == .thumbnail ? 180 : 360 }
    }

    nonisolated final class Loaded: Sendable {
        let colour: Image
        let layers: Image
        /// One layer pixel in the 0...1 of the shader's `uv`.
        let texel: CGSize
        /// The same pictures' pixels, which the images above hold anyway: what the stitch-in reads its threads from.
        let colourBitmap: CGImage
        let layersBitmap: CGImage

        init(colour: CGImage, layers: CGImage) {
            self.colour = Image(decorative: colour, scale: 1)
            self.layers = Image(decorative: layers, scale: 1)
            texel = CGSize(width: 1 / CGFloat(layers.width), height: 1 / CGFloat(layers.height))
            colourBitmap = colour
            layersBitmap = layers
        }
    }

    /// Safe from the decoding queue, which reads and fills it there: a screen of rows showing one patch asks for it once per row,
    /// and only the two decoding at once can miss each other.
    private nonisolated(unsafe) static let cache = NSCache<NSString, Loaded>()

    static func cached(_ art: PatchArt, size: Size) -> Loaded? {
        cache.object(forKey: key(art, size))
    }

    static func load(_ art: PatchArt, size: Size) async -> Loaded? {
        if let hit = cached(art, size: size) { return hit }
        let colourPixels = size.colourPixels, layerPixels = size.layerPixels
        let cacheKey = key(art, size)
        let flag = CancelFlag()
        let loaded: Loaded? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decoding.addOperation {
                    if let hit = cache.object(forKey: cacheKey) {
                        continuation.resume(returning: hit)
                        return
                    }
                    guard !flag.isCancelled, let colour = decode(art.colour, maxPixels: colourPixels), let layers = decode(art.layers, maxPixels: layerPixels) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let loaded = Loaded(colour: colour, layers: layers)
                    cache.setObject(loaded, forKey: cacheKey)
                    continuation.resume(returning: loaded)
                }
            }
        } onCancel: {
            flag.cancel()
        }
        return loaded
    }

    /// The patch's threads, for its stitch-in: every pixel of its layers is read, so it's off the main thread too.
    nonisolated static func threads(of loaded: Loaded, art: PatchArt) async -> [StitchThread] {
        await withCheckedContinuation { continuation in
            decoding.addOperation {
                continuation.resume(returning: StitchThread.threads(colour: loaded.colourBitmap, layers: loaded.layersBitmap, bounds: art.stitchBounds))
            }
        }
    }

    /// Decodes block their thread, so they run here and never on Swift's cooperative pool: a board asks for a dozen at
    /// once, which on the pool held every thread until the decoders' own work couldn't run (the app's test host hung).
    /// Two at a time, and one scrolled away before its turn is skipped.
    private nonisolated static let decoding: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "patch decoding"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private nonisolated final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    private static func key(_ art: PatchArt, _ size: Size) -> NSString {
        "\(art.colour.path(percentEncoded: false))|\(size.colourPixels)" as NSString
    }

    private nonisolated static func decode(_ url: URL, maxPixels: Int) -> CGImage? {
        #if DEBUG
        // Issue #150: what a sweep counts, with patches on rows that refresh every second. A thumbnail that's stayed lazy shows up
        // in the same log as the decoder's own lines.
        if UserDefaults.standard.bool(forKey: "patchDecodeLog") {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "patch-decode").info("decode \(url.lastPathComponent, privacy: .public)")
        }
        #endif
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(bitmap)
    }

    /// The same pixels in plain memory. A thumbnail from ImageIO can stay a lazy provider that decodes the file again when
    /// the renderer asks for its pixels, and a moving light rebuilds the shader, so it asked on every frame for every patch
    /// on screen (about 120 AV1 decodes a second, seen in the log while the light swept). A still light hid it.
    private nonisolated static func bitmap(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
