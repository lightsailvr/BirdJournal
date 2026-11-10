import SwiftUI

/// The viewfinder with the camera's controls on it (issue #187, of #185): what the camera sees, a pinch that zooms through
/// every lens, a tap that focuses and exposes where it lands with a square to show where, and along the bottom edge the lens
/// buttons the phone has, in a thumb's reach above the shutter. VoiceOver zooms on the viewfinder itself, a lens at a swipe.
struct CaptureViewfinder: View {
    let camera: any CaptureCamera
    /// Where the zoom stood when the pinch under way began.
    @State private var pinchStart: Double?

    var body: some View {
        let zoom = camera.zoom
        GeometryReader { box in
            ZStack {
                camera.viewfinder
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        camera.focus(at: UnitPoint(x: tap.location.x / max(box.size.width, 1), y: tap.location.y / max(box.size.height, 1)))
                    })
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { pinch in
                                let start = pinchStart ?? zoom.factor
                                pinchStart = start
                                camera.setZoom(start * pinch.magnification, smoothly: false)
                            }
                            .onEnded { _ in pinchStart = nil }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Viewfinder")
                    .accessibilityValue(CaptureCameraText.viewfinder(zoom: zoom.factor, focusHeld: camera.focusPoint != nil))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: camera.setZoom(camera.zoom.stepped(in: true), smoothly: true)
                        case .decrement: camera.setZoom(camera.zoom.stepped(in: false), smoothly: true)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("capture-viewfinder")
                    // Read before the buttons that lie on it: the picture, then its lenses, then the shutter.
                    .accessibilitySortPriority(1)

                if let point = camera.focusPoint {
                    FocusSquare()
                        .position(x: point.x * box.size.width, y: point.y * box.size.height)
                        // A new tap is a new square, arriving again.
                        .id(point)
                }
            }
            // The picture and the square on it keep to the viewfinder's corners; the buttons don't, so with the phone on
            // its side, where the viewfinder is narrower than the row, every button is still whole and takes its tap.
            .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
            .overlay(alignment: .bottom) {
                LensButtons(zoom: zoom) { camera.setZoom($0, smoothly: true) }
                    .fixedSize()
                    .padding(.bottom, 10)
            }
            .accessibilityElement(children: .contain)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
    }
}

/// The phone's zoom steps along the viewfinder's bottom edge. The lens in use is the white one, and it reads the zoom as it
/// stands, so a pinch between two lenses shows its factor there as it changes; a tap on any of them glides to that lens.
private struct LensButtons: View {
    let zoom: CaptureZoom
    let choose: (Double) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(zoom.lenses, id: \.self) { lens in
                let isCurrent = lens == zoom.currentLens
                let shown = isCurrent ? zoom.factor : lens
                Button {
                    choose(lens)
                } label: {
                    Text(CaptureZoom.text(shown))
                        .font(isCurrent ? .footnote.weight(.bold) : .caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isCurrent ? .black : .white)
                        .padding(.horizontal, 3)
                        .frame(width: isCurrent ? 42 : 34, height: isCurrent ? 42 : 34)
                        .background(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.6)), in: Circle())
                        // The whole 44 points take the thumb, whatever the circle's size.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.journalPress)
                .accessibilityLabel(CaptureCameraText.lens(shown))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Text(CaptureZoom.text(shown)) }
                // By its step, "capture-lens-0.5": the label changes with the zoom.
                .accessibilityIdentifier("capture-lens-\(CaptureZoom.text(lens).dropLast())")
            }
        }
        .padding(3)
        .background(.black.opacity(0.35), in: Capsule())
        // Buttons over the picture: their words stop growing here, and a long press shows them large.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Where focus and exposure are held: it arrives a little large and settles on the spot, then rests dimmer for as long as
/// the hold lasts. Under Reduce Motion it is simply there.
private struct FocusSquare: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var arrived = false
    @State private var rested = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.7), radius: 1.5)
            .frame(width: 76, height: 76)
            .scaleEffect(arrived || PatchMotion.reduces(system: systemReduceMotion) ? 1 : 1.35)
            .opacity(rested ? 0.6 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.22)) { arrived = true }
                withAnimation(.easeOut(duration: 0.4).delay(1.2)) { rested = true }
            }
            // A mark on the picture, not a control: a tap on it is a tap on the viewfinder under it.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .accessibilityIdentifier("capture-focus-square")
    }
}

extension CaptureCameraText {
    /// A lens button for VoiceOver: "0.5 times zoom".
    static func lens(_ factor: Double) -> String {
        "\(CaptureZoom.spoken(factor)) zoom"
    }

    /// What the viewfinder says of itself: its zoom, and that focus is held when the birder has tapped.
    static func viewfinder(zoom: Double, focusHeld: Bool) -> String {
        focusHeld ? "\(lens(zoom)), focus set" : lens(zoom)
    }
}
