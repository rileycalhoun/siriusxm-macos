import Foundation
import SiriusXMCore

/// The one shape a session takes when it is written to disk.
///
/// `SessionMaterial` deliberately does not conform to `Codable`, because a
/// `Codable` conformance is an invitation. Encoding lives here instead, in
/// exactly one file, so that "what is written to the keychain" is one small
/// thing to read rather than a property of the value type.
///
/// There is no password field here, and adding one would make this type
/// refuse to encode rather than store it.
struct StoredSessionPayload: Codable, Sendable {
    var token: String?
    var gupID: String?
    var cookieNames: [String]
    var issuedAt: Date?
    var expiresAt: Date?
    var schemaVersion: Int

    init(_ material: SessionMaterial) {
        token = material.resolvedToken
        gupID = material.resolvedGupID
        cookieNames = material.resolvedCookieNames
        issuedAt = material.resolvedIssuedAt
        expiresAt = material.resolvedExpiresAt
        schemaVersion = material.resolvedSchemaVersion
    }

    var material: SessionMaterial {
        SessionMaterial(
            token: token,
            gupID: gupID,
            cookieNames: cookieNames,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            schemaVersion: schemaVersion
        )
    }
}

/// A session store that keeps the session in memory only.
///
/// Used by tests, by SwiftUI previews, and as the fallback on a platform where
/// the keychain is not available. It is not a persistence story and does not
/// pretend to be one.
public final class EphemeralSessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SessionMaterial?

    public init() {}

    /// How many times a session was written. Lets a test assert that a signed
    /// out app never wrote anything at all.
    public private(set) var writeCount: Int = 0

    public func load() throws -> SessionMaterial? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func save(_ material: SessionMaterial) throws {
        lock.lock()
        stored = material
        writeCount += 1
        lock.unlock()
    }

    public func clear() throws {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}

#if canImport(Security)
import Security

/// The keychain-backed session store.
///
/// Three properties this file exists to hold:
///
///   - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and nothing else.
///     A background token refresh has to be able to read this item while the
///     machine is locked but awake, and it must not travel to another machine
///     in a backup.
///   - No `SecAccessControl` and no `kSecUseAuthenticationContext`. There is
///     no biometric gate, because a refresh that stops working when nobody is
///     at the keyboard is a refresh that silently stops happening.
///   - No password field. This stores a session, and a session is not a
///     password.
public final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(service: String = "com.rileycalhoun.siriusxm.session", account: String = "primary") {
        self.service = service
        self.account = account
    }

    public func load() throws -> SessionMaterial? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainStoreError.unreadable }
            return try decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.status(status)
        }
    }

    public func save(_ material: SessionMaterial) throws {
        let data = try encode(material)
        var query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
        default:
            throw KeychainStoreError.status(updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainStoreError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func encode(_ material: SessionMaterial) throws -> Data {
        do {
            return try JSONEncoder().encode(StoredSessionPayload(material))
        } catch {
            throw KeychainStoreError.encodingFailed
        }
    }

    private func decode(_ data: Data) throws -> SessionMaterial {
        do {
            return try JSONDecoder().decode(StoredSessionPayload.self, from: data).material
        } catch {
            throw KeychainStoreError.unreadable
        }
    }
}

/// Keychain failures, reduced to slugs. An `OSStatus` is safe to print; the
/// `SecCopyErrorMessageString` for it is not something this app wants to put
/// in a user-facing error.
public enum KeychainStoreError: Error, Sendable, Hashable, CustomStringConvertible {
    case status(Int32)
    case unreadable
    case encodingFailed

    public var description: String {
        switch self {
        case .status(let code): return "keychain-status(\(code))"
        case .unreadable: return "keychain-unreadable"
        case .encodingFailed: return "keychain-encoding-failed"
        }
    }
}
#endif
