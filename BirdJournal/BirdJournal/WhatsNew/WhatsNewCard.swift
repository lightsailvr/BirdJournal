import SwiftUI
import UIKit

extension View {
    /// The "What's new" card over this screen, bars included: by itself the first time the app is opened after an update, once the
    /// launch has settled, and from Settings any time.
    /// - Parameter isStageClear: nothing else has the birder's attention: no run, no review, no patch being sewn, no link being opened.
    func whatsNewCard(isStageClear: Bool) -> some View {
        modifier(WhatsNewOverlay(isStageClear: isStageClear))
    }
}

private struct WhatsNewOverlay: ViewModifier {
    @Environment(WhatsNewCenter.self) private var whatsNew
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let isStageClear: Bool

    func body(content: Content) -> some View {
        let reduceMotion = PatchMotion.reduces(system: systemReduceMotion)
        let mayArrive = scenePhase == .active && isStageClear && whatsNew.pending != nil
        content
            .overlay {
                // Always here, so the dim and the card each come and go their own way.
                ZStack {
                    if let release = whatsNew.presented {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { whatsNew.dismiss() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                            .zIndex(0)
                        WhatsNewCard(release: release) { whatsNew.dismiss() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            // Down over the tab bar, which would otherwise show its lower half under the card's edge.
                            .ignoresSafeArea(.container, edges: .bottom)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                            .zIndex(1)
                    }
                }
            }
            // Up like a card slid across a table, with a little give; away quicker than it came.
            .animation(
                reduceMotion ? .easeInOut(duration: 0.2) : whatsNew.presented == nil ? .easeIn(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.82),
                value: whatsNew.presented?.id
            )
            // Once the page under it has had a moment, and only over the page: a sheet that's up keeps the stage.
            .task(id: mayArrive) {
                guard mayArrive else { return }
                do { try await Task.sleep(for: WhatsNewCenter.settle) } catch { return }
                guard !RootView.isSomethingPresented else { return }
                whatsNew.presentPending()
            }
    }
}

/// What a release brought, on the paper card a patch is sold on (design guide page 10): the mascot's patch pinned to its top edge,
/// the edition line with the version where a patch's card has its collector number, the title where the bird's name goes, then
/// the changes, numbered so a tester can say which one, each with something to try in the lore's italic. It hugs what it says;
/// with more than fits (a long release, large text) the changes scroll and the button stays in view. Like every paper card it
/// reads the same in both appearances.
struct WhatsNewCard: View {
    let release: ReleaseNotes.Release
    let dismiss: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool
    /// How far a finger has pulled the card from where it rests.
    @State private var pull: CGFloat = 0
    /// The changes rest at their top. Always so when they fit; when they scroll, a pull down from anywhere else scrolls them.
    @State private var changesAtTop = true
    /// Whether the drag under way pulls the card: it began with the changes at their top. Nil between drags.
    @State private var dragPulls: Bool?

    /// The mascot's patch: its side, and how much of it sits on the card rather than above it.
    private static let patchSide: CGFloat = 104
    private static let patchOnCard: CGFloat = 58
    /// A drag this far down, or one thrown this far, puts the card away.
    private static let pullToDismiss: CGFloat = 90

    var body: some View {
        VStack(spacing: 0) {
            // What fits is laid out as it is; what doesn't scrolls.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.visible)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 0.5 } action: { _, atTop in
                        changesAtTop = atTop
                    }
                    .onDisappear { changesAtTop = true }
                    .accessibilityIdentifier("whats-new-scroll")
            }
            Button("Got it", action: dismiss)
                .buttonStyle(.journalPrimary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .accessibilityIdentifier("whats-new-dismiss")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .modifier(CardStockSurface(isPunched: false))
        .overlay(alignment: .top) {
            Image("PerchedFinch")
                .resizable()
                .scaledToFit()
                .frame(width: Self.patchSide, height: Self.patchSide)
                .rotationEffect(.degrees(-5))
                .offset(y: Self.patchOnCard - Self.patchSide)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 16)
        // Room above for the patch, and for the page to show the card is over it.
        .padding(.top, Self.patchSide - Self.patchOnCard + 24)
        // Clear of the home indicator, with the bottom safe area ignored.
        .padding(.bottom, 22)
        .offset(y: pull)
        // Alongside the changes' own scrolling, which would otherwise keep every drag that starts on them: a release with
        // five changes scrolls on a phone, and a pull down has to put that card away too.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                // Down follows the finger; up gives a little and no more. Changes that scroll take the drag for themselves
                // unless it began at their top, and then only its way down.
                .onChanged { drag in
                    let pulls = dragPulls ?? changesAtTop
                    dragPulls = pulls
                    guard pulls else { return }
                    let height = drag.translation.height
                    pull = height > 0 ? height : changesAtTop ? -sqrt(-height) : 0
                }
                // Far enough, or thrown: it goes on down from where it is. Otherwise it settles back.
                .onEnded { drag in
                    let pulled = dragPulls ?? changesAtTop
                    dragPulls = nil
                    if pulled, drag.translation.height > Self.pullToDismiss || drag.predictedEndTranslation.height > Self.pullToDismiss * 3 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pull = 0 }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .accessibilityIdentifier("whats-new-card")
        .onAppear { titleFocused = true }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            editionLine
            VStack(spacing: 3) {
                Text("What’s new")
                    .font(CardFont.birdName)
                    .foregroundStyle(Color.cardInk)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .accessibilityIdentifier("whats-new-title")
                if let headline = release.headline?.nilIfEmpty {
                    Text(headline)
                        .font(CardFont.scientific)
                        .foregroundStyle(Color.cardInkSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            PaperRule()
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(release.items.enumerated()), id: \.element.id) { index, item in
                    WhatsNewRow(number: index + 1, item: item)
                }
            }
            if let note = release.note?.nilIfEmpty {
                PaperRule()
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Color.cardInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whats-new-note")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 15)
        .padding(.bottom, 6)
    }

    /// "FIELD NOTES" and "VERSION 0.2.0" either side of the patch, as a patch's card has its edition and its number; under the
    /// patch, one over the other, once the text is too large to pass it.
    private var editionLine: some View {
        let version = "Version \(release.version)"
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                Text("Field notes").fixedSize()
                Spacer(minLength: Self.patchSide + 8)
                Text(version).fixedSize().monospacedDigit()
            }
            .frame(minHeight: Self.patchOnCard - 22, alignment: .top)
            VStack(spacing: 2) {
                Text("Field notes")
                Text(version).monospacedDigit()
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, Self.patchOnCard - 22)
        }
        .textCase(.uppercase)
        .font(CardFont.editionCompact)
        .tracking(CardFont.editionCompactTracking)
        .foregroundStyle(Color.cardEdge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Field notes, version \(release.version)")
        .accessibilityIdentifier("whats-new-edition")
    }
}

/// One change: its number, what it is, what it means, and something to try.
private struct WhatsNewRow: View {
    let number: Int
    let item: ReleaseNotes.Release.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number, format: .number)
                .font(CardFont.tileName)
                .monospacedDigit()
                .foregroundStyle(Color.cardEdge)
                .frame(minWidth: 14, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(CardFont.tileName)
                    .foregroundStyle(Color.cardInk)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.cardInk)
                if let tryIt = item.tryIt?.nilIfEmpty {
                    Text("Try it: \(tryIt)")
                        .font(.system(.footnote, design: .serif).italic())
                        .foregroundStyle(Color.cardInkSecondary)
                        .padding(.top, 1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spoken(number: number))
        .accessibilityIdentifier("whats-new-item-\(number)")
    }
}
