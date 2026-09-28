import Foundation

struct RelayObservation: Codable {
    let observedAt: Date
    let requestedModel: String
    let responseModel: String?
    let serverModel: String?
    let effort: String?

    var displayedUpstreamModel: String? {
        serverModel ?? responseModel
    }

    var hasModelMismatch: Bool {
        guard let upstream = displayedUpstreamModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !upstream.isEmpty else { return false }
        let requested = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return requested.caseInsensitiveCompare(upstream) != .orderedSame
    }
}

struct RelayViewState {
    let configured: Bool
    let running: Bool
    let status: String
    let observations: [RelayObservation]
    let modelBuckets: [RelayModelBucket]
    let archiveURL: URL
    let archiveCount: Int
    let archiveSizeBytes: Int64

    var hasVisibleModelMismatch: Bool {
        observations.contains { $0.hasModelMismatch }
    }
}

struct RelayModelBucket: Equatable {
    let model: String
    let effort: String
    let calls: Int
}

struct RelayArchiveSnapshot {
    let observations: [RelayObservation]
    let modelBuckets: [RelayModelBucket]
    let totalCount: Int
    let fileSizeBytes: Int64
}

extension Notification.Name {
    static let relayObservationsChanged = Notification.Name("CodexQuotaBar.relayObservationsChanged")
}

final class RelayObservationStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager = FileManager.default
    let archiveURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedObservations: [RelayObservation]?
    private var cachedFileSizeBytes: Int64 = 0

    init(directory: URL? = nil) {
        let support = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuotaBar", isDirectory: true)
        archiveURL = support.appendingPathComponent("relay-observations.jsonl")
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    }

    func append(_ observation: RelayObservation) {
        lock.lock()
        defer { lock.unlock() }

        guard let encoded = try? encoder.encode(observation) else { return }
        var line = encoded
        line.append(0x0A)

        if !fileManager.fileExists(atPath: archiveURL.path) {
            fileManager.createFile(atPath: archiveURL.path, contents: line)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        } else if let handle = try? FileHandle(forWritingTo: archiveURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                return
            }
        }
        if cachedObservations != nil {
            cachedObservations?.append(observation)
            cachedFileSizeBytes += Int64(line.count)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .relayObservationsChanged, object: nil)
        }
    }

    func snapshot(limit: Int, since: Date? = nil) -> RelayArchiveSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let all: [RelayObservation]
        if let cachedObservations {
            all = cachedObservations
        } else if let data = try? Data(contentsOf: archiveURL),
                  let text = String(data: data, encoding: .utf8) {
            all = text.split(separator: "\n")
                .compactMap { try? decoder.decode(RelayObservation.self, from: Data($0.utf8)) }
            self.cachedObservations = all
            cachedFileSizeBytes = Int64(data.count)
        } else {
            all = []
            cachedObservations = []
            cachedFileSizeBytes = 0
        }
        let filtered = since.map { start in
            all.filter { $0.observedAt >= start }
        } ?? all
        return RelayArchiveSnapshot(
            observations: Array(filtered.suffix(max(0, limit)).reversed()),
            modelBuckets: Self.summarizeModels(filtered),
            totalCount: all.count,
            fileSizeBytes: cachedFileSizeBytes
        )
    }

    private static func summarizeModels(_ observations: [RelayObservation]) -> [RelayModelBucket] {
        var counts: [String: Int] = [:]
        for observation in observations {
            let effort = observation.effort ?? "-"
            counts["\(observation.requestedModel)\t\(effort)", default: 0] += 1
        }
        return counts.map { key, calls in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return RelayModelBucket(
                model: parts[0],
                effort: parts.count > 1 ? parts[1] : "-",
                calls: calls
            )
        }
        .sorted { lhs, rhs in
            if lhs.calls != rhs.calls { return lhs.calls > rhs.calls }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.effort < rhs.effort
        }
    }

    func ensureArchiveExists() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !fileManager.fileExists(atPath: archiveURL.path) else { return }
        guard fileManager.createFile(atPath: archiveURL.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        cachedObservations = []
        cachedFileSizeBytes = 0
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: archiveURL.path) {
            try Data().write(to: archiveURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        }
        cachedObservations = []
        cachedFileSizeBytes = 0
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .relayObservationsChanged, object: nil)
        }
    }
}

enum RelayConfigurationError: LocalizedError {
    case unreadableConfig
    case staleBackup
    case missingBackup

    var errorDescription: String? {
        switch self {
        case .unreadableConfig:
            return "无法读取 Codex 配置文件"
        case .staleBackup:
            return "检测到未完成的旧备份，请先恢复配置"
        case .missingBackup:
            return "没有找到可恢复的配置备份"
        }
    }
}

final class RelayConfigurationManager {
    static let relayBaseURL = "http://127.0.0.1:43187"

    private struct BackupMetadata: Codable {
        let configExisted: Bool
    }

    private let fileManager = FileManager.default
    private let configURL: URL
    private let supportURL: URL
    private let backupURL: URL
    private let metadataURL: URL

    init(homeDirectory: URL? = nil, supportDirectory: URL? = nil) {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".codex/config.toml")
        supportURL = supportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuotaBar", isDirectory: true)
        backupURL = supportURL.appendingPathComponent("config-before-relay.toml")
        metadataURL = supportURL.appendingPathComponent("relay-backup.json")
    }

    var hasBackup: Bool {
        fileManager.fileExists(atPath: metadataURL.path)
    }

    func isConfigured() -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return topLevelValue(for: "openai_base_url", in: text) == Self.relayBaseURL
    }

    func enable() throws {
        if isConfigured() { return }
        if hasBackup { throw RelayConfigurationError.staleBackup }

        let existed = fileManager.fileExists(atPath: configURL.path)
        let original: Data
        if existed {
            guard let data = try? Data(contentsOf: configURL) else {
                throw RelayConfigurationError.unreadableConfig
            }
            original = data
        } else {
            original = Data()
        }

        try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportURL.path)
        try original.write(to: backupURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        let metadata = try JSONEncoder().encode(BackupMetadata(configExisted: existed))
        try metadata.write(to: metadataURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)

        let originalText = String(data: original, encoding: .utf8) ?? ""
        let configured = replacingTopLevelValue(
            for: "openai_base_url",
            with: Self.relayBaseURL,
            in: originalText
        )
        try writeConfig(configured)
    }

    func restore() throws {
        guard hasBackup,
              let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: metadataData),
              let backup = try? Data(contentsOf: backupURL) else {
            throw RelayConfigurationError.missingBackup
        }

        if metadata.configExisted {
            try backup.write(to: configURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } else if fileManager.fileExists(atPath: configURL.path) {
            try fileManager.removeItem(at: configURL)
        }
        try? fileManager.removeItem(at: backupURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    private func writeConfig(_ text: String) throws {
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func replacingTopLevelValue(for key: String, with value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var replaced = false
        var firstTableIndex = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                firstTableIndex = index
                break
            }
            if topLevelKey(in: trimmed) == key {
                lines[index] = "\(key) = \"\(value)\" # Managed by Codex Quota Bar"
                replaced = true
            }
        }

        if !replaced {
            lines.insert("\(key) = \"\(value)\" # Managed by Codex Quota Bar", at: firstTableIndex)
        }
        return lines.joined(separator: "\n")
    }

    private func topLevelValue(for key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            guard topLevelKey(in: trimmed) == key,
                  let equal = trimmed.firstIndex(of: "=") else { continue }
            let raw = trimmed[trimmed.index(after: equal)...]
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private func topLevelKey(in line: String) -> String? {
        guard !line.isEmpty, !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return nil }
        return line[..<equal].trimmingCharacters(in: .whitespaces)
    }
}
