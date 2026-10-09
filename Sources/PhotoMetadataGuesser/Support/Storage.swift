import Foundation
import Security

/// Saves app data as JSON files in Application Support. Writes happen off the main thread.
final class JSONStore: @unchecked Sendable {
    static let shared = JSONStore()

    let directory: URL
    private let queue = DispatchQueue(label: "PhotoMetadataGuesser.store", qos: .utility)

    init() {
        if let custom = ProcessInfo.processInfo.environment["PDG_DATA_DIR"], !custom.isEmpty {
            // Used by tests so they never touch real app data.
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directory = base.appendingPathComponent("PhotoMetadataGuesser", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable & Sendable>(_ value: T, to name: String) {
        let target = url(name)
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    /// Blocks until queued writes finish (used at quit).
    func flush() { queue.sync {} }
}

/// Stores the Anthropic API key in the login Keychain.
enum Keychain {
    static let service = "PhotoMetadataGuesser"
    static let account = "anthropic-api-key"

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        }
        return key
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
