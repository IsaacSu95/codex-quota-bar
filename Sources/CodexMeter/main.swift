import AppKit
import Foundation

struct RateSnapshot {
    let usedPercent: Int?
    let resetsAt: Date?
    let resetCredits: Int?
    let resetCreditExpiresAt: Date?
    let observedAt: Date?
    let source: String

    var remainingPercent: Int? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    var isFresh: Bool {
        guard let observedAt else { return false }
        return Date().timeIntervalSince(observedAt) <= 10 * 60
    }
}

struct ModelBucket {
    let model: String
    let effort: String
    var turns: Int
}

struct ThreadBucket {
    let threadId: String
    let title: String
    let model: String
    let effort: String
    var turns: Int
}

struct MeterData {
    let rate: RateSnapshot?
    let models: [ModelBucket]
    let threads: [ThreadBucket]
    let refreshedAt: Date
}

final class CodexMeterApp: NSObject, NSApplicationDelegate {
    private let localRefreshInterval: TimeInterval = 60
    private let usageRefreshInterval: TimeInterval = 5 * 60
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let reader = CodexReader()
    private let usageFetcher = CodexUsageFetcher()
    private let readerQueue = DispatchQueue(label: "io.github.isaacsu95.CodexQuotaBar.reader", qos: .utility)
    private let usageQueue = DispatchQueue(label: "io.github.isaacsu95.CodexQuotaBar.usage", qos: .utility)
    private var localTimer: Timer?
    private var usageTimer: Timer?
    private var latest: MeterData?
    private var liveRate: RateSnapshot?
    private var isReadingLocalData = false
    private var isFetchingUsage = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "--"
        statusItem.button?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        refreshLocalData()
        refreshUsage()
        localTimer = Timer.scheduledTimer(withTimeInterval: localRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshLocalData()
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: usageRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    private func refreshLocalData() {
        guard !isReadingLocalData else { return }
        isReadingLocalData = true
        readerQueue.async { [weak self] in
            guard let self else { return }
            let data = self.reader.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.latest = MeterData(
                    rate: self.liveRate ?? data.rate,
                    models: data.models,
                    threads: data.threads,
                    refreshedAt: data.refreshedAt
                )
                self.isReadingLocalData = false
                self.render()
            }
        }
    }

    private func refreshUsage() {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            let rate = self.usageFetcher.fetch()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFetchingUsage = false
                guard let rate else {
                    self.render()
                    return
                }
                self.liveRate = rate
                let current = self.latest
                self.latest = MeterData(
                    rate: rate,
                    models: current?.models ?? [],
                    threads: current?.threads ?? [],
                    refreshedAt: current?.refreshedAt ?? Date()
                )
                self.render()
            }
        }
    }

    private func render() {
        let data = latest

        if let rate = data?.rate, let remaining = rate.remainingPercent {
            let remainingTime = rate.resetsAt.map(TimeRemainingFormatter.compact) ?? ""
            let staleMark = rate.isFresh ? "" : "*"
            statusItem.button?.title = ["\(remaining)%\(staleMark)", remainingTime]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            statusItem.button?.toolTip = rate.isFresh
                ? "剩余额度 \(remaining)% · 距离重置 \(remainingTime)"
                : "显示最后一次成功查询结果，当前数据可能过期"
        } else {
            statusItem.button?.title = "--"
            statusItem.button?.toolTip = "正在查询额度"
        }

        if popover.isShown {
            popover.contentViewController = MeterPopoverViewController(data: data, app: self)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController = MeterPopoverViewController(data: latest, app: self)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        refreshLocalData()
    }

    @objc func refreshClicked() {
        refreshLocalData()
        refreshUsage()
    }

    @objc func quitClicked() {
        NSApp.terminate(nil)
    }
}

final class MeterPopoverViewController: NSViewController {
    private let data: MeterData?
    private weak var app: CodexMeterApp?

    init(data: MeterData?, app: CodexMeterApp) {
        self.data = data
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = MeterPanelView(data: data, app: app)
    }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class MeterPanelView: NSView {
    private let contentWidth: CGFloat = 358
    private let data: MeterData?
    private weak var app: CodexMeterApp?

    init(data: MeterData?, app: CodexMeterApp?) {
        self.data = data
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 500))
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(rateSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(modelSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(threadSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(footer())

        scroll.documentView = stack
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        DispatchQueue.main.async {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func rateSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let rate = data?.rate else {
            stack.addArrangedSubview(label("正在查询额度…", size: 13, weight: .regular, color: .secondaryLabelColor))
            return stack
        }

        let used = rate.usedPercent.map(String.init) ?? "--"
        let remaining = rate.remainingPercent.map(String.init) ?? "--"
        let prefix = rate.isFresh ? "" : "旧数据  "
        let line = label("\(prefix)已用 \(used)%    剩余 \(remaining)%", size: 22, weight: .bold, color: accentColor(for: rate))
        stack.addArrangedSubview(line)

        if let observedAt = rate.observedAt {
            stack.addArrangedSubview(meta("更新于", DateFormatters.local.string(from: observedAt)))
        }
        if let resetsAt = rate.resetsAt {
            let resetText = "\(DateFormatters.monthDayTime.string(from: resetsAt)) · \(TimeRemainingFormatter.compact(until: resetsAt))"
            stack.addArrangedSubview(meta("额度重置", resetText))
        }
        if let resetCredits = rate.resetCredits {
            let expiry = rate.resetCreditExpiresAt.map {
                " · 最近 \(DateFormatters.monthDay.string(from: $0))到期"
            } ?? ""
            stack.addArrangedSubview(meta("重置券", "\(resetCredits) 张\(expiry)"))
        }
        return stack
    }

    private func modelSection() -> NSView {
        let stack = sectionStack(title: "今日模型调用")
        guard let models = data?.models, !models.isEmpty else {
            stack.addArrangedSubview(label("暂无今日模型记录", size: 13, weight: .regular, color: .secondaryLabelColor))
            return stack
        }
        for item in models.prefix(10) {
            stack.addArrangedSubview(twoColumn(
                left: "\(item.model) / \(item.effort)",
                right: "\(item.turns)",
                leftColor: color(for: item.model)
            ))
        }
        return stack
    }

    private func threadSection() -> NSView {
        let stack = sectionStack(title: "今日任务 · 调用次数")
        guard let threads = data?.threads, !threads.isEmpty else {
            stack.addArrangedSubview(label("暂无任务记录", size: 13, weight: .regular, color: .secondaryLabelColor))
            return stack
        }
        for item in threads.prefix(8) {
            stack.addArrangedSubview(threadRow(item))
        }
        return stack
    }

    private func footer() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let refreshed = data.map { DateFormatters.time.string(from: $0.refreshedAt) } ?? "--"
        let time = label("扫描: \(refreshed)", size: 11, weight: .regular, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(time)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(button("刷新", action: #selector(CodexMeterApp.refreshClicked)))
        row.addArrangedSubview(button("退出", action: #selector(CodexMeterApp.quitClicked)))
        return row
    }

    private func sectionStack(title: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label(title, size: 12, weight: .semibold, color: .secondaryLabelColor))
        return stack
    }

    private func twoColumn(left: String, right: String, leftColor: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let leftLabel = label(left, size: 13, weight: .medium, color: leftColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rightLabel = label(right, size: 13, weight: .semibold, color: .labelColor)
        rightLabel.alignment = .right

        row.addArrangedSubview(leftLabel)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(rightLabel)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func meta(_ name: String, _ value: String) -> NSTextField {
        label("\(name): \(value)", size: 12, weight: .regular, color: .secondaryLabelColor)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, lines: Int = 1) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.maximumNumberOfLines = lines
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: app, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    private func threadRow(_ item: ThreadBucket) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        box.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        let id = label(String(item.threadId.prefix(8)), size: 11, weight: .medium, color: .secondaryLabelColor)
        id.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        id.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let model = label(item.model, size: 12, weight: .semibold, color: color(for: item.model))
        model.widthAnchor.constraint(equalToConstant: 104).isActive = true

        let effort = label(item.effort, size: 11, weight: .regular, color: .tertiaryLabelColor)
        effort.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let count = label("\(item.turns) 次", size: 12, weight: .semibold, color: .labelColor)
        count.alignment = .right
        count.widthAnchor.constraint(equalToConstant: 42).isActive = true

        top.addArrangedSubview(id)
        top.addArrangedSubview(model)
        top.addArrangedSubview(effort)
        top.addArrangedSubview(spacer)
        top.addArrangedSubview(count)
        top.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let title = label(item.title, size: 12, weight: .regular, color: .labelColor, lines: 2)
        title.lineBreakMode = .byTruncatingTail
        title.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        box.addArrangedSubview(top)
        box.addArrangedSubview(title)
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    private func accentColor(for rate: RateSnapshot) -> NSColor {
        guard rate.isFresh, let remaining = rate.remainingPercent else { return .secondaryLabelColor }
        if remaining <= 20 { return .systemRed }
        if remaining <= 50 { return .systemOrange }
        return .systemGreen
    }

    private func color(for model: String) -> NSColor {
        if model.contains("astra") { return .systemPurple }
        if model.contains("sol") { return .systemBlue }
        if model.contains("luna") { return .systemTeal }
        if model.contains("terra") { return .systemBrown }
        return .labelColor
    }
}

final class CodexReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let sqlite = "/usr/bin/sqlite3"

    func read() -> MeterData {
        let titles = readThreadTitles()
        let turnRows = readTurnRows()
        let modelBuckets = summarizeModels(turnRows)
        let threadBuckets = summarizeThreads(turnRows, titles: titles)
        return MeterData(
            rate: readRateSnapshot(),
            models: modelBuckets,
            threads: threadBuckets,
            refreshedAt: Date()
        )
    }

    private func readRateSnapshot() -> RateSnapshot? {
        let db = home.appendingPathComponent(".codex/thread_history_1.sqlite").path
        let sql = """
        SELECT created_at_ms || '\t' || replace(replace(json_extract(item_json, '$.result.content[0].text'), char(10), ' '), char(13), ' ')
        FROM thread_items
        WHERE json_extract(item_json, '$.type') = 'mcpToolCall'
          AND json_extract(item_json, '$.tool') = 'get_usage_limits'
          AND json_extract(item_json, '$.status') = 'completed'
        ORDER BY created_at_ms DESC
        LIMIT 20;
        """
        let output = runSqlite(db: db, sql: sql)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let body = String(parts[1])
            let used = firstInt(in: body, patterns: [
                #"usedPercent["\\]*\s*[:=]\s*(\d{1,3})"#,
                #"已用[：:\s`]*(\d{1,3})%"#
            ])
            let reset = firstInt64(in: body, patterns: [
                #"resetsAt["\\]*\s*[:=]\s*(\d{9,12})"#
            ]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let credits = firstInt(in: body, patterns: [
                #"availableCount["\\]*\s*[:=]\s*(\d+)"#,
                #"重置券[：:\s`]*(\d+)"#
            ])
            let observedMs = Double(String(parts[0])) ?? 0
            let observedAt = observedMs > 0 ? Date(timeIntervalSince1970: observedMs / 1000) : nil
            if used != nil || reset != nil || credits != nil {
                return RateSnapshot(
                    usedPercent: used,
                    resetsAt: reset,
                    resetCredits: credits,
                    resetCreditExpiresAt: nil,
                    observedAt: observedAt,
                    source: "Codex 本地用量记录"
                )
            }
        }
        return nil
    }

    private func readTurnRows() -> [(threadId: String, turnId: String, model: String, effort: String)] {
        let db = home.appendingPathComponent(".codex/logs_2.sqlite").path
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let sql = """
        SELECT COALESCE(thread_id, '') || '\t' || replace(replace(feedback_log_body, char(10), ' '), char(13), ' ')
        FROM logs
        WHERE ts >= \(start)
          AND feedback_log_body IS NOT NULL
        ORDER BY ts ASC;
        """
        let output = runSqlite(db: db, sql: sql)
        var seen = Set<String>()
        var rows: [(String, String, String, String)] = []
        let regex = try? NSRegularExpression(pattern: #"turn\.id=([a-f0-9-]+) model=(gpt-[a-z0-9.-]+) codex\.turn\.reasoning_effort=([a-z]+)"#)

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let regex else { continue }
            let threadId = String(parts[0])
            let body = String(parts[1])
            let nsRange = NSRange(body.startIndex..<body.endIndex, in: body)
            guard let match = regex.firstMatch(in: body, range: nsRange),
                  let turnRange = Range(match.range(at: 1), in: body),
                  let modelRange = Range(match.range(at: 2), in: body),
                  let effortRange = Range(match.range(at: 3), in: body) else { continue }
            let turnId = String(body[turnRange])
            let model = String(body[modelRange])
            let effort = String(body[effortRange])
            let key = "\(threadId)\t\(turnId)\t\(model)\t\(effort)"
            if seen.insert(key).inserted {
                rows.append((threadId, turnId, model, effort))
            }
        }
        return rows
    }

    private func readThreadTitles() -> [String: String] {
        let db = home.appendingPathComponent(".codex/state_5.sqlite").path
        let sql = """
        SELECT id || '\t' || replace(substr(title, 1, 80), char(10), ' / ')
        FROM threads;
        """
        let output = runSqlite(db: db, sql: sql)
        var titles: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            titles[String(parts[0])] = String(parts[1])
        }
        return titles
    }

    private func summarizeModels(_ rows: [(threadId: String, turnId: String, model: String, effort: String)]) -> [ModelBucket] {
        var counts: [String: Int] = [:]
        for row in rows {
            counts["\(row.model)\t\(row.effort)", default: 0] += 1
        }
        return counts.map { key, count in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return ModelBucket(model: parts[0], effort: parts.count > 1 ? parts[1] : "-", turns: count)
        }
        .sorted { lhs, rhs in
            if lhs.turns != rhs.turns { return lhs.turns > rhs.turns }
            return lhs.model < rhs.model
        }
    }

    private func summarizeThreads(
        _ rows: [(threadId: String, turnId: String, model: String, effort: String)],
        titles: [String: String]
    ) -> [ThreadBucket] {
        var counts: [String: Int] = [:]
        for row in rows where !row.threadId.isEmpty {
            counts["\(row.threadId)\t\(row.model)\t\(row.effort)", default: 0] += 1
        }
        return counts.map { key, count in
            let parts = key.split(separator: "\t").map(String.init)
            let threadId = parts[0]
            return ThreadBucket(
                threadId: threadId,
                title: titles[threadId] ?? "未命名任务",
                model: parts.count > 1 ? parts[1] : "-",
                effort: parts.count > 2 ? parts[2] : "-",
                turns: count
            )
        }
        .sorted { lhs, rhs in
            if lhs.turns != rhs.turns { return lhs.turns > rhs.turns }
            return lhs.threadId < rhs.threadId
        }
    }

    private func runSqlite(db: String, sql: String) -> String {
        guard FileManager.default.fileExists(atPath: db) else { return "" }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: sqlite)
        process.arguments = ["-readonly", db, sql]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func firstInt(in text: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            if let value = firstMatch(in: text, pattern: pattern).flatMap(Int.init) {
                return value
            }
        }
        return nil
    }

    private func firstInt64(in text: String, patterns: [String]) -> Int64? {
        for pattern in patterns {
            if let value = firstMatch(in: text, pattern: pattern).flatMap(Int64.init) {
                return value
            }
        }
        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[matchRange])
    }

    private func firstDate(in text: String, patterns: [String]) -> Date? {
        for pattern in patterns {
            if let raw = firstMatch(in: text, pattern: pattern),
               let date = DateFormatters.local.date(from: raw) {
                return date
            }
        }
        return nil
    }
}

final class CodexUsageFetcher {
    private let timeout: DispatchTimeInterval = .seconds(20)

    func fetch() -> RateSnapshot? {
        guard let executable = codexExecutable() else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let responseReady = DispatchSemaphore(value: 0)
        let responseLock = NSLock()
        var buffer = Data()
        var snapshot: RateSnapshot?
        var finished = false

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            responseLock.lock()
            defer { responseLock.unlock() }
            buffer.append(data)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                snapshot = Self.parseSnapshot(from: object)
                if !finished {
                    finished = true
                    responseReady.signal()
                }
            }
        }

        do {
            try process.run()
            let requests = [
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-quota-bar","version":"0.4.0"},"capabilities":{"experimentalApi":true}}}"#,
                #"{"method":"initialized"}"#,
                #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":false}}"#
            ].joined(separator: "\n") + "\n"
            input.fileHandleForWriting.write(Data(requests.utf8))
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        _ = responseReady.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        responseLock.lock()
        defer { responseLock.unlock() }
        return snapshot
    }

    private func codexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func parseSnapshot(from response: [String: Any]) -> RateSnapshot? {
        guard let result = response["result"] as? [String: Any] else { return nil }
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let codexBucket = buckets?["codex"] as? [String: Any]
        let legacyBucket = result["rateLimits"] as? [String: Any]
        guard let bucket = codexBucket ?? legacyBucket,
              let primary = bucket["primary"] as? [String: Any],
              let usedPercent = (primary["usedPercent"] as? NSNumber)?.intValue else { return nil }

        let resetsAt = (primary["resetsAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        let resetCreditSummary = result["rateLimitResetCredits"] as? [String: Any]
        let resetCredits = resetCreditSummary?["availableCount"] as? NSNumber
        let resetCreditExpiresAt = (resetCreditSummary?["credits"] as? [[String: Any]])?
            .compactMap { ($0["expiresAt"] as? NSNumber)?.doubleValue }
            .map(Date.init(timeIntervalSince1970:))
            .filter { $0 > Date() }
            .min()

        return RateSnapshot(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            resetCredits: resetCredits?.intValue,
            resetCreditExpiresAt: resetCreditExpiresAt,
            observedAt: Date(),
            source: "Codex 实时查询"
        )
    }
}

enum DateFormatters {
    static let local: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let monthDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

enum TimeRemainingFormatter {
    static func compact(until date: Date) -> String {
        let totalMinutes = max(0, Int(ceil(date.timeIntervalSinceNow / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }
}

if CommandLine.arguments.contains("--fetch-usage") {
    if let rate = CodexUsageFetcher().fetch(),
       let used = rate.usedPercent,
       let remaining = rate.remainingPercent {
        print("实时额度: 已用 \(used)% / 剩余 \(remaining)%")
        if let resetsAt = rate.resetsAt {
            print("重置时间: \(DateFormatters.local.string(from: resetsAt))")
        }
        if let resetCredits = rate.resetCredits {
            let expiry = rate.resetCreditExpiresAt.map {
                " / 最近 \(DateFormatters.local.string(from: $0)) 到期"
            } ?? ""
            print("重置券: \(resetCredits) 张\(expiry)")
        }
        exit(0)
    }
    print("实时额度: 查询失败")
    exit(1)
}

if CommandLine.arguments.contains("--once") {
    let data = CodexReader().read()
    if let rate = data.rate, let used = rate.usedPercent, let remaining = rate.remainingPercent {
        print("额度快照: 已用 \(used)% / 剩余 \(remaining)%")
        if let observedAt = rate.observedAt {
            print("快照时间: \(DateFormatters.local.string(from: observedAt))")
        }
        if let resetsAt = rate.resetsAt {
            print("重置时间: \(DateFormatters.local.string(from: resetsAt))")
        }
    } else {
        print("额度快照: 暂无本地记录")
    }

    print("今日模型调用:")
    for item in data.models {
        print("- \(item.model) / \(item.effort): \(item.turns) turns")
    }

    print("今日任务:")
    for item in data.threads.prefix(8) {
        print("- \(item.threadId.prefix(8)) \(item.model): \(item.turns) - \(item.title)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = CodexMeterApp()
app.delegate = delegate
app.run()
