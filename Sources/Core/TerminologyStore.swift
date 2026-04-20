import Foundation
import Combine

public struct TerminologyEntry: Codable, Identifiable, Hashable {
    public var id: UUID
    public var canonical: String
    public var variants: [String]
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), canonical: String, variants: [String], caseSensitive: Bool = false) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.caseSensitive = caseSensitive
    }
}

public extension Notification.Name {
    static let terminologyChanged = Notification.Name("PushToTalk.terminologyChanged")
    static let terminologyActiveLanguageChanged = Notification.Name("PushToTalk.terminologyActiveLanguageChanged")
}

@MainActor
public final class TerminologyStore: ObservableObject {
    public enum MergeStrategy { case skipExisting, replaceAll }

    public static let shared = TerminologyStore()

    @Published public private(set) var entries: [TerminologyEntry] = []
    @Published public private(set) var activeLanguage: String

    private var cache: [String: [TerminologyEntry]] = [:]

    private let directory: URL
    private let bundle: Bundle
    private let defaultsBundlePrefix: String

    public init(directory: URL = TerminologyStore.defaultDirectory(),
                bundle: Bundle = .main,
                defaultsBundlePrefix: String = "terminology-default",
                legacyFlatFile: URL? = TerminologyStore.legacyFlatFile(),
                initialLanguage: String = "ru") {
        self.directory = directory
        self.bundle = bundle
        self.defaultsBundlePrefix = defaultsBundlePrefix
        self.activeLanguage = initialLanguage
        bootstrap(legacyFlatFile: legacyFlatFile)
        loadActive()
    }

    public nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/terminology")
    }

    public nonisolated static func legacyFlatFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/terminology.json")
    }

    // MARK: - Bootstrap

    private func bootstrap(legacyFlatFile: URL?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let legacy = legacyFlatFile, fm.fileExists(atPath: legacy.path) {
            let target = fileURL(for: "ru")
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: legacy, to: target)
                pttLog("TerminologyStore: migrated legacy terminology.json → terminology/ru.json")
            }
        }
    }

    private func fileURL(for language: String) -> URL {
        directory.appendingPathComponent("\(language).json")
    }

    private func seedURL(for language: String) -> URL? {
        bundle.url(forResource: "\(defaultsBundlePrefix)-\(language)", withExtension: "json")
    }

    public func hasSeed(for language: String) -> Bool { seedURL(for: language) != nil }

    // MARK: - Active language

    public func setActiveLanguage(_ code: String) {
        guard !code.isEmpty, code != activeLanguage else { return }
        activeLanguage = code
        loadActive()
        NotificationCenter.default.post(name: .terminologyActiveLanguageChanged, object: nil)
    }

    public func entries(for language: String) -> [TerminologyEntry] {
        if let cached = cache[language] { return cached }
        let loaded = loadFromDisk(language) ?? seedEntries(for: language) ?? []
        cache[language] = loaded
        return loaded
    }

    private func loadActive() {
        let loaded: [TerminologyEntry]
        if let disk = loadFromDisk(activeLanguage) {
            loaded = disk
        } else if let seed = seedEntries(for: activeLanguage) {
            loaded = seed
            writeToDisk(seed, language: activeLanguage)
        } else {
            loaded = []
        }
        cache[activeLanguage] = loaded
        entries = loaded
    }

    private func loadFromDisk(_ language: String) -> [TerminologyEntry]? {
        let url = fileURL(for: language)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TerminologyEntry].self, from: data)
        else { return nil }
        return decoded
    }

    private func seedEntries(for language: String) -> [TerminologyEntry]? {
        guard let url = seedURL(for: language),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TerminologyEntry].self, from: data)
        else { return nil }
        return decoded
    }

    private func writeToDisk(_ entries: [TerminologyEntry], language: String) {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL(for: language), options: .atomic)
        } catch {
            pttLog("TerminologyStore: save error (\(language)): \(error)")
        }
    }

    // MARK: - Mutations on active set

    private func persistActive() {
        cache[activeLanguage] = entries
        writeToDisk(entries, language: activeLanguage)
        NotificationCenter.default.post(name: .terminologyChanged, object: nil)
    }

    public func add(_ entry: TerminologyEntry) {
        entries.append(entry)
        persistActive()
    }

    public func update(_ entry: TerminologyEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        persistActive()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persistActive()
    }

    public func replaceAll(_ newEntries: [TerminologyEntry]) {
        entries = newEntries
        persistActive()
    }

    public func loadDefaults(mergeStrategy: MergeStrategy) {
        guard let defaults = seedEntries(for: activeLanguage) else {
            pttLog("TerminologyStore: no seed for \(activeLanguage)")
            return
        }
        switch mergeStrategy {
        case .replaceAll:
            entries = defaults
        case .skipExisting:
            let existing = Set(entries.map { $0.canonical.lowercased() })
            entries.append(contentsOf: defaults.filter { !existing.contains($0.canonical.lowercased()) })
        }
        persistActive()
    }

    // MARK: - Prompt hint

    /// Comma-joined canonical forms, truncated so that the result fits into roughly `maxChars` characters
    /// (rough proxy for ~200 WhisperKit tokens using ~4 chars/token). Final tokenizer-aware truncation
    /// lives in `TranscriptionEngine.tokenizePrompt`.
    public func promptHint(for language: String? = nil, maxChars: Int = 800) -> String {
        let list = language.map { entries(for: $0) } ?? entries
        var out = ""
        for entry in list {
            let candidate = out.isEmpty ? entry.canonical : out + ", " + entry.canonical
            if candidate.count > maxChars { break }
            out = candidate
        }
        return out
    }
}
