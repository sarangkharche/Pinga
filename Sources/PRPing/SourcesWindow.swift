import AppKit
import PRPingCore

@MainActor
final class SourcesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let modeControl = NSSegmentedControl(labels: ["Repositories", "Organisations"], trackingMode: .selectOne, target: nil, action: nil)
    private let entry = NSTextField()
    private let table = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove selected", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save sources", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var entries: [String] = []
    private var drafts: [SourceMode: [String]] = [:]
    private var currentMode: SourceMode = .repositories
    private var saving = false
    private let save: @MainActor (SourceMode, [String]) async throws -> Void

    init(scope: WatchScope?, save: @escaping @MainActor (SourceMode, [String]) async throws -> Void) {
        self.save = save
        currentMode = scope?.mode ?? .repositories
        entries = scope?.sources ?? []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Manage sources"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        let content = window.contentView!
        let heading = NSTextField(labelWithString: "Choose what Pinga watches")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Only your PRs in these sources will appear. Add up to 10 sources. Remove every source to pause monitoring.")
        subtitle.textColor = .secondaryLabelColor
        modeControl.selectedSegment = currentMode == .repositories ? 0 : 1
        modeControl.target = self
        modeControl.action = #selector(sourceModeChanged)
        entry.target = self
        entry.action = #selector(addSource)
        addButton.target = self
        addButton.action = #selector(addSource)
        removeButton.target = self
        removeButton.action = #selector(removeSource)
        removeButton.isEnabled = false
        saveButton.target = self
        saveButton.action = #selector(saveSources)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(closeWindow)
        cancelButton.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [entry, addButton])
        row.orientation = .horizontal
        entry.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.title = "Sources"
        column.isEditable = false
        column.width = 490
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 29
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        for view in [heading, subtitle, modeControl, row, scroll, removeButton, message, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            modeControl.leadingAnchor.constraint(equalTo: heading.leadingAnchor), modeControl.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            row.leadingAnchor.constraint(equalTo: heading.leadingAnchor), row.trailingAnchor.constraint(equalTo: subtitle.trailingAnchor), row.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: row.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: row.trailingAnchor), scroll.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 10), scroll.heightAnchor.constraint(equalToConstant: 150),
            removeButton.leadingAnchor.constraint(equalTo: row.leadingAnchor), removeButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: row.leadingAnchor), message.trailingAnchor.constraint(equalTo: row.trailingAnchor), message.topAnchor.constraint(equalTo: removeButton.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: row.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            message.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -10)
        ])
        updateHint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { NSApp.setActivationPolicy(.regular); showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(entry) }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { entries[row] }
    func tableViewSelectionDidChange(_ notification: Notification) { removeButton.isEnabled = !saving && !table.selectedRowIndexes.isEmpty }
    private func updateHint() {
        message.textColor = .secondaryLabelColor
        entry.placeholderString = currentMode == .repositories ? "owner/repository or GitHub repository URL" : "Organisation name or GitHub organisation URL"
        message.stringValue = currentMode == .repositories ? "Add the exact repositories you want, such as company/platform." : "An organisation includes its repositories that your GitHub account can access."
        table.reloadData()
    }
    @objc private func sourceModeChanged() {
        drafts[currentMode] = entries
        currentMode = modeControl.selectedSegment == 0 ? .repositories : .organisations
        entries = drafts[currentMode] ?? []
        entry.stringValue = ""
        updateHint()
    }
    @objc private func addSource() {
        guard !saving else { return }
        let values = entry.stringValue.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        for value in values where !entries.contains(value) { entries.append(value) }
        entry.stringValue = ""
        updateHint()
    }
    @objc private func removeSource() {
        for row in table.selectedRowIndexes.reversed() { entries.remove(at: row) }
        table.deselectAll(nil)
        updateHint()
    }
    @objc private func closeWindow() { if !saving { close() } }
    @objc private func saveSources() {
        guard !saving else { return }
        if !entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addSource() }
        saving = true
        setControlsEnabled(false)
        message.stringValue = "Checking access and saving…"
        Task {
            do {
                try await save(currentMode, entries)
                saving = false
                close()
            } catch {
                saving = false
                setControlsEnabled(true)
                message.stringValue = error.localizedDescription
                message.textColor = .systemRed
            }
        }
    }
    private func setControlsEnabled(_ enabled: Bool) {
        modeControl.isEnabled = enabled
        entry.isEnabled = enabled
        addButton.isEnabled = enabled
        removeButton.isEnabled = enabled && !table.selectedRowIndexes.isEmpty
        saveButton.isEnabled = enabled
        cancelButton.isEnabled = enabled
        window?.standardWindowButton(.closeButton)?.isEnabled = enabled
    }
}
