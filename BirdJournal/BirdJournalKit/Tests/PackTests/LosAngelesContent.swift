import Testing

extension Tag {
    /// On a test that pins what the bundled pack holds while that pack is Los Angeles (#209): how many birds, its county,
    /// what it says of a particular bird, its size, the versions its content arrived in. These are the tests to re-pin, in one
    /// pass, when the bundled pack changes (#220); every other test asks `BundledPack` or the pack itself.
    @Tag static var losAngelesContent: Self
}
