import Foundation
import Security
import Supabase

/// Keychain-only credentials, including migration of earlier plaintext copies.
/// The SDK swallows storage errors, so SessionService also checks storage health.
final class ResilientAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let keychain: any AuthLocalStorage
    private let fallback: UserDefaults
    private let lock = NSRecursiveLock()
    private var failed = false
    private let fallbackPrefix = "albus.auth."

    init(service: String = "com.felipegutierrez.albus.auth",
         fallback: UserDefaults = .standard,
         keychain: (any AuthLocalStorage)? = nil) {
        self.keychain = keychain ?? SessionKeychain(service: service)
        self.fallback = fallback
    }

    /// Called before an explicit sign-in attempt; automatic SDK operations cannot
    /// clear an earlier failure by successfully reading an older credential.
    func beginAttempt() throws {
        lock.lock()
        defer { lock.unlock() }
        failed = false
        for name in fallback.dictionaryRepresentation().keys where name.hasPrefix(fallbackPrefix) {
            // Visit every copy even if one migration fails; failure stays latched.
            _ = try? retrieve(key: String(name.dropFirst(fallbackPrefix.count)))
        }
        try checkHealth()
    }

    func checkHealth() throws {
        lock.lock()
        defer { lock.unlock() }
        if failed { throw SessionStorageUnavailable() }
    }

    /// Check secure writes before asking the server to create an account.
    func checkWritable() throws {
        let key = "albus.storage-probe.\(UUID().uuidString)"
        try store(key: key, value: Data([0]))
        try remove(key: key)
    }

    func store(key: String, value: Data) throws {
        try operation(key: key) { try keychain.store(key: key, value: value) }
    }

    func retrieve(key: String) throws -> Data? {
        try operation(key: key) {
            if let data = try keychain.retrieve(key: key), !data.isEmpty { return data }
            guard let legacy = fallback.data(forKey: fallbackPrefix + key), !legacy.isEmpty else { return nil }
            // Only return an old session after it has been secured successfully.
            try keychain.store(key: key, value: legacy)
            return legacy
        }
    }

    func remove(key: String) throws {
        try operation(key: key) { try keychain.remove(key: key) }
    }

    private func operation<T>(key: String, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        do {
            let result = try body()
            // Preserve an unmigrated legacy credential if secure storage is
            // temporarily unavailable. Never return it or write a new copy.
            fallback.removeObject(forKey: fallbackPrefix + key)
            return result
        }
        catch {
            failed = true
            throw SessionStorageUnavailable()
        }
    }
}

struct SessionStorageUnavailable: LocalizedError {
    var errorDescription: String? {
        "Secure sign-in is unavailable. Unlock your device and try signing in again."
    }
}

/// Match the existing SDK service/account representation and accessibility.
/// Missing items are distinct from a locked or unavailable Keychain.
struct SessionKeychain: AuthLocalStorage {
    let service: String
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func store(key: String, value: Data) throws {
        var add = query(key)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try requireSuccess(SecItemUpdate(query(key) as CFDictionary,
                [kSecValueData as String: value] as CFDictionary))
        } else { try requireSuccess(status) }
    }

    func retrieve(key: String) throws -> Data? {
        var read = query(key)
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try requireSuccess(status)
        guard let data = result as? Data else { throw SessionStorageUnavailable() }
        return data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound { try requireSuccess(status) }
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw SessionStorageUnavailable() }
    }
}
