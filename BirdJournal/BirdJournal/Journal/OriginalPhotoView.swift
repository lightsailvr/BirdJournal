import Album
import SwiftUI
import UIKit

/// The original photo with the whole screen to itself, whole and unaltered: evidence kept with the sighting, never art.
/// "View original photo" on a sighting's page opens it, and so does the photo at the head of "Name this bird" and "Change
/// bird", where it is a thumbnail and a glasses photo is cropped to its middle. Here the birder sees all of the frame: a
/// pinch brings the bird close enough to name, a drag moves about the zoomed photo, and a double tap zooms in where it
/// lands and back out to the whole photo.
///
/// The photo is read off the main actor, no larger than `maxPixels` on its longer side: a phone's twelve megapixels arrive
/// pixel for pixel, and a larger picture from the library doesn't take the memory its every pixel would.
///
/// It is a cover and not a sheet, so nothing but Close puts it away: a drag down is a drag across the photo. VoiceOver's
/// escape closes it too, and zooms a step at a time from the photo's actions.
struct OriginalPhotoView: View {
    /// The longer side the photo is read at, in pixels: the long side of a phone's 4032 × 3024 capture, so that one and a
    /// glasses photo are never resampled. Read so, a photo is at most 49 MB in memory while it is up.
    static let maxPixels = 4_032
    /// What a sighting's page says under its original photo.
    static let evidenceNote = "The unaltered photo kept with this sighting: evidence, never art."

    @Environment(\.frameStore) private var frameStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The photo, relative to the `FrameStore`.
    let path: String
    /// What VoiceOver calls the picture: "Your photo" while it waits for its name.
    var name = "Original photo"
    /// One line under the photo; nil for a photo that is not yet a sighting's.
    var note: String?
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            // A photo is looked at on black, as the camera that took it showed it.
            Color.black.ignoresSafeArea()
            if let image {
                VStack(spacing: 0) {
                    ZoomablePhoto(image: image, name: name, reduceMotion: PatchMotion.reduces(system: systemReduceMotion))
                        .ignoresSafeArea()
                    if let note {
                        // Under the photo and not over it: zoomed, the photo has every point of its own space.
                        Text(note)
                            .font(JournalFont.attribution)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, JournalLayout.margin)
                            .padding(.vertical, 10)
                            // Past this size it would take the screen from the photo it is a note to.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                            .accessibilityIdentifier("photo-viewer-note")
                    }
                }
            } else if loaded {
                StateNotice("Photo unavailable", message: "The file is no longer on this iPhone.", mark: .symbol("photo"))
                    .statePage()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .topLeading) { closeButton }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { dismiss() }
        .task(id: path) {
            if let url = frameStore?.url(for: path) {
                let side = Self.maxPixels
                image = await Task.detached(priority: .userInitiated) { BirderPhoto.fitted(at: url, maxPixels: side) }.value
            }
            loaded = true
        }
    }

    /// The one way out, in the corner the camera keeps its own: white on a dark disc with a pale edge, so it shows on a
    /// bright sky, on the black around a photo and on the page of a photo that is gone.
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                // A mark in a circle of a fixed size: it stops growing before it would outgrow the circle.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .buttonStyle(.journalPress)
        .accessibilityLabel("Close photo")
        .accessibilityIdentifier("photo-close")
        // Laid over the photo, so it would be read after it: the way out comes first, as it is at the top of the screen.
        .accessibilitySortPriority(1)
        .padding(.leading, 16)
        .padding(.top, 8)
    }
}

/// How far a photo zooms, as plain numbers: the scroll view asks here, and the tests check here.
nonisolated enum PhotoZoom {
    /// Where a double tap on the whole photo goes: the middle third of each side, a little closer than the journal's crop.
    static let doubleTap: CGFloat = 3
    /// The least the furthest zoom can be: a small photo still comes closer, soft as it then is.
    static let leastMaximum: CGFloat = 4

    /// The furthest zoom for a photo `pixels` long on the side that is `points` long on screen when it is shown whole: twice
    /// past the zoom at which one of its pixels is one of the screen's, which is where a bird's markings stop getting clearer.
    static func maximum(pixels: CGFloat, points: CGFloat, displayScale: CGFloat) -> CGFloat {
        guard pixels > 0, points > 0, displayScale > 0 else { return leastMaximum }
        return max(leastMaximum, 2 * pixels / (points * displayScale))
    }

    /// VoiceOver's step from `zoom`: twice as close going in, half coming out, between the whole photo and `maximum`.
    static func stepped(from zoom: CGFloat, in zoomsIn: Bool, maximum: CGFloat) -> CGFloat {
        zoomsIn ? min(zoom * 2, maximum) : max(zoom / 2, 1)
    }

    /// Whether `zoom` is closer than the whole photo, by more than a pinch's rounding.
    static func isZoomed(_ zoom: CGFloat) -> Bool {
        zoom > 1.01
    }

    /// "2 times zoom" or "Whole photo", for VoiceOver.
    static func spoken(_ zoom: CGFloat) -> String {
        isZoomed(zoom) ? "\(CaptureZoom.spoken(Double(zoom))) zoom" : "Whole photo"
    }
}

/// The photo in a scroll view that zooms: the system's own pinch, pan, bounce and glide, which gestures written here could
/// only imitate.
private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let name: String
    let reduceMotion: Bool

    /// The scroll view and its own delegate. The photo is fitted whole at zoom 1 and kept in the middle of whatever room it
    /// doesn't fill; VoiceOver finds the picture in it, with its zoom as the picture's value and two actions to change it.
    final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
        private let picture = UIImageView()
        /// The size the photo was last fitted to. The phone turning changes it, and the photo is fitted again, whole.
        private var fittedTo = CGSize.zero
        /// Under Reduce Motion a double tap's zoom is there at once, and a pinch past either end stops with no spring back.
        var reduceMotion = false {
            didSet { bouncesZoom = !reduceMotion }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setUp()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setUp()
        }

        private func setUp() {
            delegate = self
            // The photo's own size decides where it sits: the island and the home indicator don't push it about.
            contentInsetAdjustmentBehavior = .never
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            decelerationRate = .fast
            picture.contentMode = .scaleAspectFit
            picture.isAccessibilityElement = true
            picture.accessibilityTraits = .image
            picture.accessibilityIdentifier = "photo-viewer-photo"
            // A pinch is VoiceOver's own gesture while it is on, so the zoom is offered as actions.
            picture.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.step(in: true) ?? false },
                UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.step(in: false) ?? false },
            ]
            addSubview(picture)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        /// Puts `image` in, whole. The same image again changes nothing, so the zoom outlives the view's updates.
        func show(_ image: UIImage, name: String) {
            picture.accessibilityLabel = name
            guard picture.image !== image else { return }
            picture.image = image
            fittedTo = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Every scroll lays out again with the same size; only a new size fits the photo again.
            if bounds.size != fittedTo { fit() }
            centre()
        }

        /// The whole photo as large as the view allows, at zoom 1, with the furthest zoom worked out for that size.
        private func fit() {
            guard let image = picture.image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            fittedTo = bounds.size
            // Back to no zoom first: a zoomed view's frame is not its size.
            zoomScale = 1
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            picture.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            contentOffset = .zero
            maximumZoomScale = PhotoZoom.maximum(pixels: image.size.width * image.scale, points: fitted.width, displayScale: traitCollection.displayScale)
            picture.accessibilityValue = nil
        }

        /// Keeps the photo in the middle of the room it doesn't fill: a scroll view left alone holds it to the top left.
        private func centre() {
            picture.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            picture
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centre()
            picture.accessibilityValue = PhotoZoom.isZoomed(zoomScale) ? PhotoZoom.spoken(zoomScale) : nil
        }

        /// In to where the tap landed, or back out to the whole photo from any zoom.
        @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
            if PhotoZoom.isZoomed(zoomScale) {
                setZoomScale(1, animated: !reduceMotion)
            } else {
                setZoom(PhotoZoom.doubleTap, around: tap.location(in: picture))
            }
        }

        /// Zooms to `scale` with `point`, in the photo's own unzoomed points, in the middle of the view.
        private func setZoom(_ scale: CGFloat, around point: CGPoint) {
            let scale = min(max(scale, minimumZoomScale), maximumZoomScale)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            let shown = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            zoom(to: shown, animated: !reduceMotion)
        }

        /// VoiceOver's zoom, a step about the middle of what is in view, said as it lands; false at either end, where
        /// there is no step to take.
        private func step(in zoomsIn: Bool) -> Bool {
            let target = PhotoZoom.stepped(from: zoomScale, in: zoomsIn, maximum: maximumZoomScale)
            guard abs(target - zoomScale) > 0.001 else { return false }
            setZoom(target, around: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: picture))
            UIAccessibility.post(notification: .announcement, argument: PhotoZoom.spoken(target))
            return true
        }
    }

    func makeUIView(context: Context) -> PhotoScrollView {
        PhotoScrollView()
    }

    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.show(image, name: name)
        view.reduceMotion = reduceMotion
    }
}
