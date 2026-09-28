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

struct ThreadMetadata {
    let title: String
    let name: String
    let agentPath: String
    let parentThreadId: String
}

enum ThreadTitleResolver {
    static func firstInput(in logBody: String) -> String? {
        let pattern = #"op: TurnInput.*?Text \{ text: \"((?:\\.|[^\"\\])*)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: logBody,
                  range: NSRange(logBody.startIndex..<logBody.endIndex, in: logBody)
              ),
              let valueRange = Range(match.range(at: 1), in: logBody) else {
            return nil
        }

        let escaped = String(logBody[valueRange])
        let decoded: String
        if let data = "\"\(escaped)\"".data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? String {
            decoded = value
        } else {
            decoded = escaped
                .replacingOccurrences(of: #"\n"#, with: " ")
                .replacingOccurrences(of: #"\r"#, with: " ")
                .replacingOccurrences(of: #"\t"#, with: " ")
                .replacingOccurrences(of: #"\""#, with: #""#)
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
        }

        let normalized = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    static func fallbackTitle(firstInput: String, isForked: Bool) -> String {
        if firstInput.localizedCaseInsensitiveContains("Memory Writing Agent") {
            return "后台任务：记忆整理"
        }

        let limit = 44
        let summary = firstInput.count > limit
            ? String(firstInput.prefix(limit)) + "…"
            : firstInput
        return (isForked ? "派生任务：" : "临时任务：") + summary
    }

    static func subagentTitle(agentPath: String, parentTitle: String) -> String? {
        guard agentPath.hasPrefix("/root/"),
              let agentName = agentPath.split(separator: "/").last,
              !agentName.isEmpty else { return nil }
        let parent = parentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty else { return "子代理：\(agentName)" }
        let summary = parent.count > 32 ? String(parent.prefix(32)) + "…" : parent
        return "子代理：\(agentName) · \(summary)"
    }
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
    private let relayStore = RelayObservationStore()
    private let relayConfiguration = RelayConfigurationManager()
    private let readerQueue = DispatchQueue(label: "io.github.isaacsu95.CodexQuotaBar.reader", qos: .utility)
    private let usageQueue = DispatchQueue(label: "io.github.isaacsu95.CodexQuotaBar.usage", qos: .utility)
    private var localTimer: Timer?
    private var usageTimer: Timer?
    private var latest: MeterData?
    private var liveRate: RateSnapshot?
    private var isReadingLocalData = false
    private var isFetchingUsage = false
    private var relayStatus = "未启用"
    private var popoverController: MeterPopoverViewController?
    private var monitorWindowController: RelayMonitorWindowController?
    private lazy var relayServer: CodexRelayServer = {
        let server = CodexRelayServer(store: relayStore)
        server.stateChanged = { [weak self] in
            self?.updateRelayStatus()
            self?.render()
        }
        return server
    }()

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(relayObservationsChanged),
            name: .relayObservationsChanged,
            object: nil
        )
        if relayConfiguration.isConfigured() {
            relayStatus = "正在启动"
            relayServer.start { [weak self] result in
                self?.handleRelayStart(result, shouldConfigure: false)
            }
        } else {
            updateRelayStatus()
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
        let visibleRelay = relayViewState()
        updateStatusWarning(visibleRelay.hasVisibleModelMismatch)

        if let rate = data?.rate, let remaining = rate.remainingPercent {
            let remainingTime = rate.resetsAt.map(TimeRemainingFormatter.compact) ?? ""
            let staleMark = rate.isFresh ? "" : "*"
            statusItem.button?.title = ["\(remaining)%\(staleMark)", remainingTime]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let baseToolTip = rate.isFresh
                ? "剩余额度 \(remaining)% · 距离重置 \(remainingTime)"
                : "显示最后一次成功查询结果，当前数据可能过期"
            statusItem.button?.toolTip = visibleRelay.hasVisibleModelMismatch
                ? "\(baseToolTip) · 检测到请求与上游模型不一致"
                : baseToolTip
        } else {
            statusItem.button?.title = "--"
            statusItem.button?.toolTip = visibleRelay.hasVisibleModelMismatch
                ? "正在查询额度 · 检测到请求与上游模型不一致"
                : "正在查询额度"
        }

        if popover.isShown {
            let controller = popoverController ?? MeterPopoverViewController(data: data, relay: visibleRelay, app: self)
            popoverController = controller
            controller.update(data: data, relay: visibleRelay)
            popover.contentViewController = controller
        }
        if monitorWindowController?.window?.isVisible == true {
            monitorWindowController?.update(relay: relayViewState(limit: 500, todayOnly: false))
        }
    }

    private func updateStatusWarning(_ visible: Bool) {
        guard let button = statusItem.button else { return }
        guard visible else {
            button.image = nil
            return
        }
        let image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "请求模型与上游模型不一致"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let relay = relayViewState()
        let controller = popoverController ?? MeterPopoverViewController(
            data: latest,
            relay: relay,
            app: self
        )
        popoverController = controller
        controller.update(data: latest, relay: relay)
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        refreshLocalData()
    }

    @objc func refreshClicked() {
        refreshLocalData()
        refreshUsage()
    }

    @objc func enableRelayClicked() {
        relayStatus = "正在启动"
        render()
        relayServer.start { [weak self] result in
            self?.handleRelayStart(result, shouldConfigure: true)
        }
    }

    @objc func restoreRelayClicked() {
        do {
            try relayConfiguration.restore()
            relayServer.stop()
            updateRelayStatus()
            render()
        } catch {
            showError(title: "恢复失败", error: error)
        }
    }

    @objc func showMonitorClicked() {
        let controller = monitorWindowController ?? RelayMonitorWindowController(app: self)
        monitorWindowController = controller
        controller.update(relay: relayViewState(limit: 500, todayOnly: false))
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func revealRelayArchiveClicked() {
        do {
            try relayStore.ensureArchiveExists()
            NSWorkspace.shared.activateFileViewerSelecting([relayStore.archiveURL])
        } catch {
            showError(title: "无法打开备查文件", error: error)
        }
    }

    @objc func clearRelayArchiveClicked() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空本地上游记录？"
        alert.informativeText = "将清空 relay-observations.jsonl，此操作无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try relayStore.clear()
            render()
        } catch {
            showError(title: "清空失败", error: error)
        }
    }

    @objc private func relayObservationsChanged() {
        render()
    }

    @objc func quitClicked() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if relayConfiguration.hasBackup {
            do {
                try relayConfiguration.restore()
            } catch {
                showError(title: "退出前无法恢复配置", error: error)
                return .terminateCancel
            }
        }
        relayServer.stop()
        return .terminateNow
    }

    private func handleRelayStart(_ result: Result<Void, Error>, shouldConfigure: Bool) {
        switch result {
        case .success:
            if shouldConfigure {
                do {
                    try relayConfiguration.enable()
                } catch {
                    relayServer.stop()
                    showError(title: "设置失败", error: error)
                }
            }
        case .failure(let error):
            showError(title: "转发器启动失败", error: error)
        }
        updateRelayStatus()
        render()
    }

    private func updateRelayStatus() {
        if relayServer.isRunning && relayConfiguration.isConfigured() {
            relayStatus = "监测中"
        } else if relayConfiguration.isConfigured() {
            relayStatus = "配置已设置，服务未启动"
        } else if relayConfiguration.hasBackup {
            relayStatus = "配置待恢复"
        } else {
            relayStatus = "未启用"
        }
    }

    private func relayViewState(limit: Int = 12, todayOnly: Bool = true) -> RelayViewState {
        let since = todayOnly ? Calendar.current.startOfDay(for: Date()) : nil
        let archive = relayStore.snapshot(limit: limit, since: since)
        return RelayViewState(
            configured: relayConfiguration.isConfigured() || relayConfiguration.hasBackup,
            running: relayServer.isRunning,
            status: relayStatus,
            observations: archive.observations,
            modelBuckets: archive.modelBuckets,
            archiveURL: relayStore.archiveURL,
            archiveCount: archive.totalCount,
            archiveSizeBytes: archive.fileSizeBytes
        )
    }

    private func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

final class MeterPopoverViewController: NSViewController {
    private var data: MeterData?
    private var relay: RelayViewState
    private weak var app: CodexMeterApp?

    init(data: MeterData?, relay: RelayViewState, app: CodexMeterApp) {
        self.data = data
        self.relay = relay
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = MeterPanelView(data: data, relay: relay, app: app)
    }

    func update(data: MeterData?, relay: RelayViewState) {
        let scrollOffset = (isViewLoaded ? view as? MeterPanelView : nil)?.scrollOffset
        self.data = data
        self.relay = relay
        guard isViewLoaded else { return }
        view = MeterPanelView(data: data, relay: relay, app: app, initialScrollOffset: scrollOffset)
    }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class MeterPanelView: NSView {
    private let contentWidth: CGFloat = 358
    private let data: MeterData?
    private let relay: RelayViewState
    private weak var app: CodexMeterApp?
    private weak var scrollView: NSScrollView?
    var scrollOffset: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }

    init(data: MeterData?, relay: RelayViewState, app: CodexMeterApp?, initialScrollOffset: CGFloat? = nil) {
        self.data = data
        self.relay = relay
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 500))
        build(initialScrollOffset: initialScrollOffset)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(initialScrollOffset: CGFloat?) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let scroll = NSScrollView()
        scrollView = scroll
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
        stack.addArrangedSubview(relaySection())
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
            self.layoutSubtreeIfNeeded()
            let maximum = max(0, stack.frame.height - scroll.contentView.bounds.height)
            let offset = min(max(0, initialScrollOffset ?? 0), maximum)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
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
        let models = relay.modelBuckets.isEmpty
            ? (data?.models ?? [])
            : relay.modelBuckets.map {
                ModelBucket(model: $0.model, effort: $0.effort, turns: $0.calls)
            }
        guard !models.isEmpty else {
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
        let threads = data?.threads ?? []
        guard !threads.isEmpty else {
            stack.addArrangedSubview(label("暂无任务记录", size: 13, weight: .regular, color: .secondaryLabelColor))
            return stack
        }
        for item in threads.prefix(30) {
            stack.addArrangedSubview(threadRow(item))
        }
        if threads.count > 30 {
            stack.addArrangedSubview(label(
                "另有 \(threads.count - 30) 条任务未显示",
                size: 12,
                weight: .regular,
                color: .secondaryLabelColor
            ))
        }
        return stack
    }

    private func relaySection() -> NSView {
        let stack = sectionStack(title: "上游模型观察")
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let statusColor: NSColor = relay.running ? .systemGreen : .secondaryLabelColor
        let status = label(relay.status, size: 12, weight: .medium, color: statusColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let action = relay.configured
            ? button("恢复配置", action: #selector(CodexMeterApp.restoreRelayClicked))
            : button("开启监测", action: #selector(CodexMeterApp.enableRelayClicked))
        statusRow.addArrangedSubview(status)
        statusRow.addArrangedSubview(spacer)
        statusRow.addArrangedSubview(action)
        statusRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(statusRow)
        let archiveSize = ByteCountFormatter.string(fromByteCount: relay.archiveSizeBytes, countStyle: .file)
        stack.addArrangedSubview(meta("本地备查", "\(relay.archiveCount) 条 · \(archiveSize)"))

        if relay.observations.isEmpty {
            stack.addArrangedSubview(label("暂无上游模型记录", size: 12, weight: .regular, color: .secondaryLabelColor))
        } else {
            for observation in relay.observations {
                let time = DateFormatters.time.string(from: observation.observedAt)
                let effort = observation.effort.map { " / \($0)" } ?? ""
                let upstream = observation.displayedUpstreamModel ?? "未报告"
                let mismatch = observation.hasModelMismatch
                stack.addArrangedSubview(twoColumn(
                    left: "\(time)  \(observation.requestedModel)\(effort)",
                    right: upstream,
                    leftColor: color(for: observation.requestedModel),
                    rightColor: mismatch ? .systemRed : .labelColor,
                    warning: mismatch
                ))
            }
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
        row.addArrangedSubview(button("监控窗口", action: #selector(CodexMeterApp.showMonitorClicked)))
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

    private func twoColumn(
        left: String,
        right: String,
        leftColor: NSColor,
        rightColor: NSColor = .labelColor,
        warning: Bool = false
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let leftLabel = label(left, size: 13, weight: .medium, color: leftColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rightLabel = label(right, size: 13, weight: .semibold, color: rightColor)
        rightLabel.alignment = .right

        row.addArrangedSubview(leftLabel)
        row.addArrangedSubview(spacer)
        if warning {
            let warningIcon = NSImageView()
            warningIcon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "请求模型与上游模型不一致"
            )
            warningIcon.contentTintColor = .systemRed
            warningIcon.toolTip = "请求模型与上游返回不一致"
            warningIcon.translatesAutoresizingMaskIntoConstraints = false
            warningIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            warningIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            row.addArrangedSubview(warningIcon)
        }
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
        let turnLog = readTurnLog()
        let metadata = readThreadMetadata()
        let modelBuckets = summarizeModels(turnLog.rows)
        let threadBuckets = summarizeThreads(
            turnLog.rows,
            metadata: metadata,
            fallbackTitles: turnLog.fallbackTitles
        )
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

    private func readTurnLog() -> (
        rows: [(threadId: String, turnId: String, model: String, effort: String)],
        fallbackTitles: [String: String]
    ) {
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
        var firstInputs: [String: String] = [:]
        var forkedThreads = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"turn\.id=([a-f0-9-]+) model=(gpt-[a-z0-9.-]+) codex\.turn\.reasoning_effort=([a-z]+)"#)

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let threadId = String(parts[0])
            let body = String(parts[1])
            if !threadId.isEmpty {
                if body.contains(#"rpc.method="thread/fork""#) || body.contains(#"otel.name="thread/fork""#) {
                    forkedThreads.insert(threadId)
                }
                if firstInputs[threadId] == nil,
                   let firstInput = ThreadTitleResolver.firstInput(in: body) {
                    firstInputs[threadId] = firstInput
                }
            }

            guard let regex else { continue }
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
        let fallbackTitles = firstInputs.map { threadId, firstInput in
            return (
                threadId,
                ThreadTitleResolver.fallbackTitle(
                    firstInput: firstInput,
                    isForked: forkedThreads.contains(threadId)
                )
            )
        }
        return (rows, Dictionary(uniqueKeysWithValues: fallbackTitles))
    }

    private func readThreadMetadata() -> [String: ThreadMetadata] {
        let db = home.appendingPathComponent(".codex/state_5.sqlite").path
        let sql = """
        SELECT id || char(9)
            || replace(replace(substr(title, 1, 80), char(10), ' / '), char(9), ' ') || char(9)
            || replace(replace(substr(COALESCE(name, ''), 1, 80), char(10), ' / '), char(9), ' ') || char(9)
            || COALESCE(agent_path, '') || char(9)
            || CASE WHEN json_valid(source)
                THEN COALESCE(json_extract(source, '$.subagent.thread_spawn.parent_thread_id'), '')
                ELSE '' END
        FROM threads;
        """
        let output = runSqlite(db: db, sql: sql)
        var metadata: [String: ThreadMetadata] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 5 else { continue }
            metadata[String(parts[0])] = ThreadMetadata(
                title: String(parts[1]),
                name: String(parts[2]),
                agentPath: String(parts[3]),
                parentThreadId: String(parts[4])
            )
        }
        return metadata
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
        metadata: [String: ThreadMetadata],
        fallbackTitles: [String: String]
    ) -> [ThreadBucket] {
        var counts: [String: Int] = [:]
        for row in rows where !row.threadId.isEmpty {
            counts["\(row.threadId)\t\(row.model)\t\(row.effort)", default: 0] += 1
        }
        return counts.map { key, count in
            let parts = key.split(separator: "\t").map(String.init)
            let threadId = parts[0]
            let thread = metadata[threadId]
            let parent = thread.flatMap { metadata[$0.parentThreadId] }
            let parentTitle = parent.map { $0.name.isEmpty ? $0.title : $0.name } ?? ""
            let subagentTitle = thread.flatMap {
                ThreadTitleResolver.subagentTitle(agentPath: $0.agentPath, parentTitle: parentTitle)
            }
            let formalTitle = thread?.title ?? ""
            return ThreadBucket(
                threadId: threadId,
                title: formalTitle.isEmpty
                    ? subagentTitle ?? fallbackTitles[threadId] ?? "未命名任务"
                    : formalTitle,
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
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-quota-bar","version":"0.6.1"},"capabilities":{"experimentalApi":true}}}"#,
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
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
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

    static let monitor: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
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
    for item in data.threads {
        print("- \(item.threadId.prefix(8)) \(item.model): \(item.turns) - \(item.title)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--relay-only") {
    let store = RelayObservationStore()
    let server = CodexRelayServer(store: store)
    server.start { result in
        switch result {
        case .success:
            print("本地转发器: READY http://127.0.0.1:\(CodexRelayServer.port)")
        case .failure(let error):
            fputs("本地转发器: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = CodexMeterApp()
app.delegate = delegate
app.run()
