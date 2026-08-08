import Foundation

enum PreferencesMigration {
    private static let migrationKey = "migratedFromCodexLimitBar"
    private static let legacyBundleIdentifier = "com.vitashka2001.CodexLimitBar"
    private static let copiedKeys = ["monitoringEnabled", "appLanguage"]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        for key in copiedKeys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}
