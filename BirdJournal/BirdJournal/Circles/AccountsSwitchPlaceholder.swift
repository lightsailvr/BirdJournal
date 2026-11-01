// Placeholder for issue #88's switch so this branch compiles before #88 lands. #88 defines
// `AccountSession.isEnabledInThisBuild` (the ACCOUNTS_ENABLED compilation condition, Debug only); when this branch is
// rebased onto it, delete this file: the duplicate definition fails the build until it is gone.
extension AccountSession {
    #if DEBUG
    static let isEnabledInThisBuild = true
    #else
    static let isEnabledInThisBuild = false
    #endif
}
