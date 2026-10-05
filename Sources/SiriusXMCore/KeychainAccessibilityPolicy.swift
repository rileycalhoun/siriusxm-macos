import Foundation

/// The single keychain accessibility class this app will ever request.
///
/// It is an enum with one case on purpose. A policy that can be chosen is a
/// policy that will eventually be chosen wrongly, and the two wrong answers
/// are the expensive ones:
///
///   - `.whenUnlocked` (or the biometric classes) would fail every background
///     token refresh. The app refreshes tokens while playing, while asleep on
///     a timer, and immediately on a 401 from the edge gateway, none of which
///     happen with the keychain unlocked by a person.
///   - `.afterFirstUnlock` without `ThisDeviceOnly` would migrate the session
///     into an iCloud keychain backup and onto a restored machine. A restored
///     machine is a second device for the same subscriber, which is precisely
///     the account condition that gets an account limited.
///
/// The single case maps to the Security framework constant
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The mapping lives with
/// the concrete store, where the Security framework is available; the two
/// invariants below live here so they can be asserted on every platform.
public enum KeychainAccessibilityPolicy: Sendable, Hashable {
    /// Readable after the first unlock following a boot, never synced, never
    /// restored to another machine.
    case afterFirstUnlockThisDeviceOnly

    /// Background work — token refresh, expiry recovery — may read the item
    /// without a person present. This is the whole reason this policy exists.
    public var allowsBackgroundAccess: Bool { true }

    /// No biometric or device-passcode gate. A refresh that stops working
    /// because the Mac woke up locked is a bug, not a security win.
    public var requiresUserPresence: Bool { false }
}

/// Storage for session material.
///
/// Deliberately narrower than it could be. It stores a *session*, and a
/// session is the only credential-shaped value that is allowed to outlive the
/// process. It has no method that accepts, returns, or persists a password,
/// which is how "we will add password storage later" is prevented from being a
/// one-line change.
///
/// The one implementation is platform code and lives in `SiriusXMNet`; the
/// protocol lives here so that the composition root depends on the contract
/// and not on the Security framework.
public protocol SessionStore: Sendable {
    /// Returns the stored session, or `nil` when there is none.
    func load() async -> SessionMaterial?

    /// Replaces the stored session.
    func save(_ session: SessionMaterial) async throws

    /// Removes the stored session. Called when a session is rejected, not only
    /// when the user signs out, so a bad session never becomes sticky.
    func clear() async
}
