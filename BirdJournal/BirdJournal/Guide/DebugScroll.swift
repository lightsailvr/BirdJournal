#if DEBUG
import SwiftUI

extension View {
    /// Issue #118's screenshots: once `ready`, scrolls `proxy` to `id` when the launch flag `key` names it (e.g.
    /// `-autoScrollTo guild-feed`), then forgets the flag. Debug builds only.
    func debugScroll(_ proxy: ScrollViewProxy, to id: String, when ready: Bool = true) -> some View {
        task(id: ready) {
            guard ready, UserDefaults.standard.string(forKey: "autoScrollTo") == id else { return }
            try? await Task.sleep(for: .milliseconds(800))
            UserDefaults.standard.removeObject(forKey: "autoScrollTo")
            proxy.scrollTo(id, anchor: .top)
        }
    }
}
#endif
