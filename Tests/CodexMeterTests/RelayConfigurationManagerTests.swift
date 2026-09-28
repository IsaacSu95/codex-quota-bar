import Foundation
import Testing
@testable import CodexMeter

struct RelayConfigurationManagerTests {
    @Test func enableAndRestorePreservesOriginalConfigExactly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "xhigh"

        [features]
        memories = true
        """
        try fixture.writeConfig(original)

        try fixture.manager.enable()

        let configured = try fixture.readConfig()
        #expect(configured.contains("openai_base_url = \"http://127.0.0.1:43187\""))
        #expect(configured.range(of: "openai_base_url")!.lowerBound < configured.range(of: "[features]")!.lowerBound)
        #expect(fixture.manager.isConfigured())
        #expect(fixture.manager.hasBackup)

        try fixture.manager.restore()

        #expect(try fixture.readConfig() == original)
        #expect(!fixture.manager.hasBackup)
    }

    @Test func existingBaseURLIsRestored() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "openai_base_url = \"https://example.test/v1\"\nmodel = \"gpt-5.6-sol\"\n"
        try fixture.writeConfig(original)

        try fixture.manager.enable()
        let configured = try fixture.readConfig()
        #expect(configured.components(separatedBy: "openai_base_url").count == 2)
        #expect(fixture.manager.isConfigured())

        try fixture.manager.restore()
        #expect(try fixture.readConfig() == original)
    }

    @Test func restoreRemovesConfigThatDidNotPreviouslyExist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.manager.enable()
        #expect(fixture.manager.isConfigured())

        try fixture.manager.restore()
        #expect(!FileManager.default.fileExists(atPath: fixture.configURL.path))
    }
}

struct RelayObservationStoreTests {
    @Test func modelMismatchRequiresReportedDifferentModel() {
        let matching = RelayObservation(
            observedAt: Date(),
            requestedModel: "gpt-5.6-sol",
            responseModel: "GPT-5.6-SOL",
            serverModel: nil,
            effort: "high"
        )
        let missing = RelayObservation(
            observedAt: Date(),
            requestedModel: "gpt-5.6-sol",
            responseModel: nil,
            serverModel: nil,
            effort: "high"
        )
        let different = RelayObservation(
            observedAt: Date(),
            requestedModel: "gpt-5.7-terra",
            responseModel: "gpt-6-sol",
            serverModel: nil,
            effort: "medium"
        )

        #expect(!matching.hasModelMismatch)
        #expect(!missing.hasModelMismatch)
        #expect(different.hasModelMismatch)
    }

    @Test func archivePersistsFiltersAndClears() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-quota-bar-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RelayObservationStore(directory: root)
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        store.append(RelayObservation(
            observedAt: yesterday,
            requestedModel: "gpt-old",
            responseModel: "gpt-old-upstream",
            serverModel: nil,
            effort: "low"
        ))
        store.append(RelayObservation(
            observedAt: today,
            requestedModel: "gpt-current",
            responseModel: nil,
            serverModel: "gpt-current-upstream",
            effort: "high"
        ))
        store.append(RelayObservation(
            observedAt: today.addingTimeInterval(1),
            requestedModel: "gpt-latest",
            responseModel: nil,
            serverModel: "gpt-latest-upstream",
            effort: "xhigh"
        ))
        store.append(RelayObservation(
            observedAt: today.addingTimeInterval(2),
            requestedModel: "gpt-current",
            responseModel: "gpt-current",
            serverModel: nil,
            effort: "high"
        ))

        let todayOnly = store.snapshot(
            limit: 20,
            since: Calendar.current.startOfDay(for: today)
        )
        #expect(todayOnly.totalCount == 4)
        #expect(todayOnly.observations.count == 3)
        #expect(todayOnly.observations.map(\.requestedModel) == ["gpt-current", "gpt-latest", "gpt-current"])
        #expect(todayOnly.modelBuckets == [
            RelayModelBucket(model: "gpt-current", effort: "high", calls: 2),
            RelayModelBucket(model: "gpt-latest", effort: "xhigh", calls: 1)
        ])
        #expect(todayOnly.fileSizeBytes > 0)

        store.append(RelayObservation(
            observedAt: today.addingTimeInterval(3),
            requestedModel: "gpt-cached",
            responseModel: "gpt-cached-upstream",
            serverModel: nil,
            effort: "medium"
        ))
        let afterCachedAppend = store.snapshot(limit: 20)
        #expect(afterCachedAppend.totalCount == 5)
        #expect(afterCachedAppend.observations.first?.requestedModel == "gpt-cached")

        try store.clear()
        let cleared = store.snapshot(limit: 20)
        #expect(cleared.totalCount == 0)
        #expect(cleared.modelBuckets.isEmpty)
        #expect(cleared.fileSizeBytes == 0)
        #expect(FileManager.default.fileExists(atPath: store.archiveURL.path))
    }
}

struct ThreadTitleResolverTests {
    @Test func extractsForkedTaskTitleFromTurnInputLog() {
        let body = "session_loop: Submission sub=Submission { op: TurnInput { request: TurnInputRequest { input: UserInput { content: [Text { text: \"解释示例字段\\n\", text_elements: [] }] } } } }"
        let input = ThreadTitleResolver.firstInput(in: body)

        #expect(input == "解释示例字段")
        #expect(ThreadTitleResolver.fallbackTitle(firstInput: input!, isForked: true) == "派生任务：解释示例字段")
    }

    @Test func labelsMemoryWriterAsBackgroundTask() {
        let body = "Submission { op: TurnInput { input: [Text { text: \"## Memory Writing Agent: Phase 2 (Consolidation)\\nYou are a Memory Writing Agent.\", text_elements: [] }] } }"
        let input = ThreadTitleResolver.firstInput(in: body)

        #expect(input != nil)
        #expect(ThreadTitleResolver.fallbackTitle(firstInput: input!, isForked: false) == "后台任务：记忆整理")
    }

    @Test func displaysSubagentWithItsParentTask() {
        #expect(ThreadTitleResolver.subagentTitle(
            agentPath: "/root/row10_repair",
            parentTitle: "检查示例项目"
        ) == "子代理：row10_repair · 检查示例项目")
        #expect(ThreadTitleResolver.subagentTitle(
            agentPath: "/root/standard_qa",
            parentTitle: ""
        ) == "子代理：standard_qa")
        #expect(ThreadTitleResolver.subagentTitle(agentPath: "", parentTitle: "任务") == nil)
    }
}

private struct Fixture {
    let root: URL
    let home: URL
    let support: URL
    let manager: RelayConfigurationManager

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-quota-bar-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )
        manager = RelayConfigurationManager(homeDirectory: home, supportDirectory: support)
    }

    var configURL: URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    func readConfig() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
