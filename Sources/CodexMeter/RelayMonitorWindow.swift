import AppKit
import Foundation

final class RelayMonitorWindowController: NSWindowController {
    private let monitorViewController: RelayMonitorViewController

    init(app: CodexMeterApp) {
        monitorViewController = RelayMonitorViewController(app: app)
        let window = NSWindow(contentViewController: monitorViewController)
        window.title = "Codex Quota Bar · 上游监控"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 700, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(relay: RelayViewState) {
        monitorViewController.update(relay: relay)
    }
}

private final class RelayMonitorViewController: NSViewController {
    private weak var app: CodexMeterApp?
    private var relay: RelayViewState?

    init(app: CodexMeterApp) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = RelayMonitorView(relay: relay, app: app)
    }

    func update(relay: RelayViewState) {
        self.relay = relay
        guard isViewLoaded else { return }
        (view as? RelayMonitorView)?.update(relay: relay)
    }
}

private final class RelayMonitorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private var relay: RelayViewState?
    private weak var app: CodexMeterApp?
    private let tableView = NSTableView()
    private var statusLabel: NSTextField?
    private var detailLabel: NSTextField?

    init(relay: RelayViewState?, app: CodexMeterApp?) {
        self.relay = relay
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        build()
        updateSummary()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(relay: RelayViewState) {
        self.relay = relay
        updateSummary()
        tableView.reloadData()
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = buildHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        configureTable()
        scroll.documentView = tableView
        addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func buildHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let title = label("上游模型持续监控", size: 16, weight: .semibold, color: .labelColor)
        let status = label("正在读取", size: 12, weight: .medium, color: .secondaryLabelColor)
        statusLabel = status
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(status)
        titleRow.addArrangedSubview(spacer)
        titleRow.addArrangedSubview(button("在访达中显示", symbol: "folder", action: #selector(CodexMeterApp.revealRelayArchiveClicked)))
        titleRow.addArrangedSubview(button("清空记录", symbol: "trash", action: #selector(CodexMeterApp.clearRelayArchiveClicked)))

        let detail = label("正在读取本地备查", size: 11, weight: .regular, color: .secondaryLabelColor)
        detailLabel = detail
        detail.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(detail)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [
            ("time", "时间", 130),
            ("requested", "请求模型", 220),
            ("effort", "推理强度", 100),
            ("upstream", "上游声明", 220)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "effort" ? 80 : 110
            column.resizingMask = identifier == "upstream" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
    }

    private func updateSummary() {
        statusLabel?.stringValue = relay?.status ?? "正在读取"
        statusLabel?.textColor = relay?.running == true ? .systemGreen : .secondaryLabelColor
        let count = relay?.archiveCount ?? 0
        let size = ByteCountFormatter.string(fromByteCount: relay?.archiveSizeBytes ?? 0, countStyle: .file)
        let path = relay?.archiveURL.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        ) ?? "~/Library/Application Support/CodexQuotaBar/relay-observations.jsonl"
        detailLabel?.stringValue = "本地备查 \(count) 条 · \(size) · \(path)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        relay?.observations.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let observation = relay?.observations[row], let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        guard let field = cell.textField else { return cell }

        switch identifier.rawValue {
        case "time":
            field.stringValue = DateFormatters.monitor.string(from: observation.observedAt)
            field.textColor = .secondaryLabelColor
        case "requested":
            field.stringValue = observation.requestedModel
            field.textColor = modelColor(observation.requestedModel)
        case "effort":
            field.stringValue = observation.effort ?? "-"
            field.textColor = .secondaryLabelColor
        default:
            field.stringValue = observation.displayedUpstreamModel ?? "未报告"
            field.textColor = observation.hasModelMismatch ? .systemRed : .labelColor
            field.toolTip = observation.hasModelMismatch ? "请求模型与上游返回不一致" : nil
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = label("", size: 12, weight: identifier.rawValue == "requested" ? .medium : .regular, color: .labelColor)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: app, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    private func modelColor(_ model: String) -> NSColor {
        if model.contains("astra") { return .systemPurple }
        if model.contains("sol") { return .systemBlue }
        if model.contains("luna") { return .systemTeal }
        if model.contains("terra") { return .systemBrown }
        return .labelColor
    }
}
