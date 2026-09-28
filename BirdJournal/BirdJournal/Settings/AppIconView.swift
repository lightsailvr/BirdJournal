import OSLog
import SwiftUI
import UIKit

/// One of the home-screen icons the reader can pick. `name` is the Icon Composer file's name (`<name>.icon` in the
/// project), which is both the alternate icon's name and its thumbnail's name under `AppIconPreview/` in the asset
/// catalog; the target builds every icon in (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`).
struct AppIconChoice: Identifiable, Hashable {
    let name: String
    let title: String

    var id: String { name }

    static let all: [AppIconChoice] = [
        AppIconChoice(name: "MyBirdJournal-RedTailedHawk", title: "Red-tailed Hawk"),
        AppIconChoice(name: "MyBirdJournal-Default", title: "Blue Bird"),
        AppIconChoice(name: "MyBirdJournal-GreatEgret", title: "Great Egret"),
        AppIconChoice(name: "MyBirdJournal-HouseFinch", title: "House Finch"),
        AppIconChoice(name: "MyBirdJournal-ProthonotaryWarbler", title: "Prothonotary Warbler"),
        AppIconChoice(name: "MyBirdJournal-StellersJay", title: "Steller's Jay"),
    ]

    /// The icon the build installs (`ASSETCATALOG_COMPILER_APPICON_NAME`), read from the Info.plist so changing the
    /// build setting needs no change here.
    static var primaryName: String? {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        return primary?["CFBundleIconName"] as? String
    }

    /// The icon on the home screen now.
    @MainActor
    static var current: AppIconChoice? {
        let name = UIApplication.shared.alternateIconName ?? primaryName
        return all.first { $0.name == name }
    }

    /// The name to hand `setAlternateIconName`: nil puts the primary icon back.
    var alternateName: String? {
        name == Self.primaryName ? nil : name
    }

    var preview: Image { Image("AppIconPreview/\(name)") }
}

/// Settings → App icon: the six home-screen icons with a check on the current one. iOS confirms the change with its
/// own alert.
struct AppIconView: View {
    @State private var current = AppIconChoice.current
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(AppIconChoice.all) { choice in
                    Button {
                        Task { await select(choice) }
                    } label: {
                        HStack(spacing: 14) {
                            choice.preview
                                .resizable()
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.rule, lineWidth: 1))
                                .accessibilityHidden(true)
                            Text(choice.title)
                                .font(JournalFont.rowTitle)
                                .foregroundStyle(Color.ink)
                            Spacer()
                            if choice == current {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.moss)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(choice == current ? .isSelected : [])
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .paperList()
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ choice: AppIconChoice) async {
        guard choice != current, UIApplication.shared.supportsAlternateIcons else { return }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateName)
            current = choice
            errorMessage = nil
        } catch {
            Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "settings")
                .error("setAlternateIconName(\(choice.name)) failed: \(error.localizedDescription)")
            errorMessage = "The icon could not be changed. Try again."
        }
    }
}
