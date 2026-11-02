extension String {
    /// Nil for the empty string, so optional chains can drop blank text.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
