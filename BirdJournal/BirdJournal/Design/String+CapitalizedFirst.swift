extension String {
    /// "Oak woodland", from "oak woodland": the first letter uppercased, the rest as written.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
