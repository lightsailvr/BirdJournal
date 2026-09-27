import Album
import SwiftUI

extension EnvironmentValues {
    /// Where the album's camera frames are (`FrameStore`), for the screens that show them. Nil until the app sets it.
    @Entry var frameStore: FrameStore? = nil
}
