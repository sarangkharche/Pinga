import AppKit
import UserNotifications
import PRPingCore
import Darwin
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var openPRs: [OpenPR] = []
    private var activePR: OpenPR?
    private var browserPR: BrowserPR?
    private var browserTimer: Timer?
    private var browserReadInProgress = false
    private var browserDetectionEnabled = UserDefaults.standard.bool(forKey: "browserDetectionEnabled")
    private var selectedPRURL: String? = UserDefaults.standard.string(forKey: "activePRURL") ?? UserDefaults(suiteName: "dev.sarang.prping")?.string(forKey: "activePRURL")
    private var monitor: Monitor!
    private var scope: WatchScope?
    private var canWatch = false
    private var sourceGeneration = 0
    private var sourcesWindow: SourcesWindowController?
    private var busy = false
    private var paused = false
    private var status = "Starting…"
    private var account = "GitHub"
    private var permission = "Checking notification permission…"
    private var recent: [PREvent] = []
    private var nextDelay: TimeInterval = 60
    private var failureCount = 0
    private let center = UNUserNotificationCenter.current()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        let editMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        menuBar.addItem(editMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Pinga", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = menuBar
        if let iconURL = Bundle.main.url(forResource: "PRPing", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PR Ping", isDirectory: true)
        monitor = Monitor(stateURL: directory.appendingPathComponent("state.json"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = PRPingLogo.image()
        statusItem.button?.setAccessibilityLabel("Pinga menu")
        updateActivePR()
        statusItem.button?.toolTip = "Pinga"
        center.delegate = self
        startBrowserDetection()
        rebuildMenu()
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch { status = "Couldn't request notifications" }
            await refreshPermission()
            do {
                scope = try await monitor.sources()
                canWatch = scope?.sources.isEmpty == false
                if let scope { account = scope.login }
                if canWatch { await check() }
                else {
                    status = scope == nil ? "Choose your company sources to start" : "No sources selected. Monitoring paused"
                    center.removeAllDeliveredNotifications()
                    center.removeAllPendingNotificationRequests()
                    rebuildMenu()
                    if scope == nil { manageSources() }
                }
            } catch {
                status = error.localizedDescription
                rebuildMenu()
            }
        }
        if CommandLine.arguments.contains("--test-notification") {
            Task { try? await Task.sleep(for: .seconds(3)); await sendTest() }
        }
    }

    private func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = "Notifications allowed"
        case .denied: permission = "Notifications off: enable in Settings"
        default: permission = "Notifications need permission"
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        func label(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        func action(_ title: String, _ selector: Selector, key: String = "") { let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item) }
        label("Pinga · \(account)")
        label(status)
        label(permission)
        if let scope, !scope.sources.isEmpty { label("Sources: " + scope.sources.joined(separator: ", ")) }
        action("Manage sources…", #selector(manageSources), key: ",")
        action(browserDetectionEnabled ? "Turn off open PR detection" : "Enable open PR detection…", #selector(toggleBrowserDetection))
        if browserDetectionEnabled && !AXIsProcessTrusted() {
            label("Accessibility access needed for open PR detection")
            action("Open Accessibility settings…", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())
        if let browserPR, scope?.allows(url: browserPR.url) == true {
            action("Open current PR · \(browserPR.repository)#\(browserPR.number)", #selector(openBrowserPR))
            menu.addItem(.separator())
        }
        if !openPRs.isEmpty {
            label("Open PRs")
            for pull in openPRs {
                let item = NSMenuItem(title: "\(pull.repository)#\(pull.number) · \(pull.title)", action: #selector(selectPR(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pull.url
                item.state = pull.id == activePR?.id ? .on : .off
                item.toolTip = "Open in GitHub and keep in the menu bar"
                menu.addItem(item)
            }
            menu.addItem(.separator())
        } else if canWatch { label("No open PRs in selected sources") }
        action(busy ? "Checking…" : "Check now", #selector(checkNow), key: "r")
        menu.items.last?.isEnabled = !busy && !paused && canWatch
        if canWatch { action(paused ? "Resume notifications" : "Pause notifications", #selector(togglePause)) }
        action("Send test notification", #selector(testNotification))
        action("Notification settings…", #selector(openSettings))
        if !recent.isEmpty {
            menu.addItem(.separator())
            label("Recent activity")
            for event in recent.prefix(8) {
                let item = NSMenuItem(title: String(event.title.prefix(85)), action: #selector(openEvent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = event.url
                item.toolTip = event.body
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        action("Help and setup…", #selector(openHelp))
        action("Quit Pinga", #selector(quit), key: "q")
        statusItem.menu = menu
        if let browserPR { statusItem.button?.toolTip = "Current PR: \(browserPR.repository)#\(browserPR.number)" }
        else if let pull = activePR { statusItem.button?.toolTip = "Selected PR: \(pull.repository)#\(pull.number) · \(pull.title)" }
        else { statusItem.button?.toolTip = "Pinga: \(status)" }
    }

    private func startBrowserDetection() {
        browserTimer?.invalidate()
        guard browserDetectionEnabled else { browserPR = nil; return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBrowserPR() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        browserTimer = timer
        refreshBrowserPR()
    }

    private func refreshBrowserPR() {
        guard browserDetectionEnabled else { return }
        guard AXIsProcessTrusted(), canWatch, let scope else {
            if browserPR != nil { browserPR = nil; rebuildMenu() }
            return
        }
        guard let pid = BrowserDetector.browserPID() else {
            if browserPR != nil { browserPR = nil; rebuildMenu() }
            return
        }
        guard !browserReadInProgress else { return }
        browserReadInProgress = true
        let generation = sourceGeneration
        Task {
            let detected = await Task.detached(priority: .utility) { BrowserDetector.currentPR(pid: pid, scope: scope) }.value
            browserReadInProgress = false
            guard browserDetectionEnabled, canWatch, generation == sourceGeneration,
                  BrowserDetector.browserPID() == pid else { return }
            if browserPR != detected { browserPR = detected; rebuildMenu() }
        }
    }

    @objc private func toggleBrowserDetection() {
        if browserDetectionEnabled {
            browserDetectionEnabled = false
            UserDefaults.standard.set(false, forKey: "browserDetectionEnabled")
            startBrowserDetection()
            rebuildMenu()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Show the PR open in your browser"
        alert.informativeText = "macOS Accessibility access lets Pinga observe and control this Mac. Pinga uses it to read the current browser tab URL. It only keeps GitHub PR links in your selected sources and doesn't save other page URLs. You can turn detection off in this menu."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        browserDetectionEnabled = true
        UserDefaults.standard.set(true, forKey: "browserDetectionEnabled")
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startBrowserDetection()
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    @objc private func openBrowserPR() {
        guard let browserPR, scope?.allows(url: browserPR.url) == true else { return }
        openGitHub(browserPR.url)
    }

    private func schedule(_ delay: TimeInterval) {
        timer?.invalidate()
        guard !paused && canWatch else { return }
        let timer = Timer(timeInterval: max(60, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = min(15, max(60, delay) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() async {
        guard !busy && !paused && canWatch else { return }
        let generation = sourceGeneration
        busy = true
        status = "Checking your PRs…"
        rebuildMenu()
        await refreshPermission()
        guard generation == sourceGeneration && canWatch && !paused else { busy = false; return }
        do {
            let result = try await monitor.poll()
            guard !paused && generation == sourceGeneration && canWatch else {
                busy = false
                if !canWatch { status = "Choose your company sources to start" }
                else if paused { status = "Paused" }
                rebuildMenu()
                if canWatch && !paused { schedule(60) }
                return
            }
            account = result.login
            openPRs = result.openPRs
            updateActivePR()
            nextDelay = result.nextDelay
            let settings = await center.notificationSettings()
            let canNotify = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if canNotify {
                for event in result.events.prefix(20) {
                    if paused || generation != sourceGeneration || scope?.allows(url: event.url) != true { break }
                    let content = UNMutableNotificationContent()
                    content.title = event.title
                    content.body = String(event.body.prefix(240))
                    content.sound = .default
                    content.userInfo = ["url": event.url.absoluteString]
                    content.threadIdentifier = "pr-ping"
                    let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
                    try await center.add(request)
                    guard generation == sourceGeneration && canWatch && scope?.allows(url: event.url) == true else {
                        center.removeDeliveredNotifications(withIdentifiers: [event.id])
                        center.removePendingNotificationRequests(withIdentifiers: [event.id])
                        break
                    }
                    try await monitor.acknowledge(ids: [event.id])
                    guard generation == sourceGeneration && canWatch else { break }
                    recent.removeAll { $0.id == event.id }
                    recent.insert(event, at: 0)
                    recent = Array(recent.prefix(8))
                }
            }
            guard generation == sourceGeneration else {
                busy = false
                if canWatch && !paused { schedule(60) }
                return
            }
            failureCount = 0
            let time = Date().formatted(date: .omitted, time: .shortened)
            status = "Watching \(result.prCount) PRs · checked \(time)"
            if !canNotify && !result.events.isEmpty { status = "\(result.events.count) alerts waiting for permission" }
            else if result.events.count > 20 { status = "More alerts queued for the next check" }
        } catch {
            if generation != sourceGeneration {
                busy = false
                if canWatch && !paused { schedule(60) }
                return
            }
            if case MonitorError.sourcesRequired = error {
                canWatch = false
                openPRs = []
                browserPR = nil
                recent = []
                updateActivePR()
            }
            failureCount = min(failureCount + 1, 6)
            nextDelay = min(3600, 60 * pow(2, Double(failureCount)))
            if case MonitorError.retryAfter(let delay, _) = error { nextDelay = max(nextDelay, delay) }
            status = String(error.localizedDescription.prefix(130))
        }
        busy = false
        if paused { status = "Paused" }
        rebuildMenu()
        schedule(nextDelay)
    }

    private func updateActivePR() {
        activePR = openPRs.first { $0.url.absoluteString == selectedPRURL } ?? openPRs.first
    }
    @objc private func selectPR(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, openPRs.contains(where: { $0.url == url }) else { return }
        selectedPRURL = url.absoluteString
        UserDefaults.standard.set(selectedPRURL, forKey: "activePRURL")
        updateActivePR()
        rebuildMenu()
        openGitHub(url)
    }

    @objc private func manageSources() {
        if sourcesWindow?.window?.isVisible == true { sourcesWindow?.present(); return }
        sourcesWindow = SourcesWindowController(scope: scope) { [weak self] mode, entries in
            guard let self else { return }
            self.sourceGeneration += 1
            self.timer?.invalidate()
            self.canWatch = false
            self.openPRs = []
            self.browserPR = nil
            self.recent = []
            self.selectedPRURL = nil
            UserDefaults.standard.removeObject(forKey: "activePRURL")
            UserDefaults(suiteName: "dev.sarang.prping")?.removeObject(forKey: "activePRURL")
            self.updateActivePR()
            self.status = "Saving sources…"
            self.rebuildMenu()
            do {
                let saved = try await self.monitor.configure(mode: mode, entries: entries)
                self.scope = saved
                self.account = saved.login
                self.canWatch = !saved.sources.isEmpty
                self.paused = false
                let delivered = await self.center.deliveredNotifications()
                let excluded = delivered.filter { notification in
                    guard let value = notification.request.content.userInfo["url"] as? String, let url = URL(string: value) else { return true }
                    return !saved.allows(url: url)
                }.map { $0.request.identifier }
                self.center.removeDeliveredNotifications(withIdentifiers: excluded)
                let pending = await self.center.pendingNotificationRequests()
                let excludedPending = pending.filter { request in
                    guard let value = request.content.userInfo["url"] as? String, let url = URL(string: value) else { return true }
                    return !saved.allows(url: url)
                }.map { $0.identifier }
                self.center.removePendingNotificationRequests(withIdentifiers: excludedPending)
                self.status = self.canWatch ? "Sources saved. Checking your PRs…" : "No sources selected. Monitoring paused"
                self.rebuildMenu()
                if self.canWatch {
                    self.schedule(60)
                    Task { await self.check() }
                }
            } catch {
                self.status = "Sources not saved. Monitoring paused"
                self.rebuildMenu()
                throw error
            }
        }
        sourcesWindow?.present()
    }

    @objc private func checkNow() { timer?.invalidate(); Task { await check() } }
    @objc private func togglePause() {
        guard canWatch else { manageSources(); return }
        paused.toggle()
        timer?.invalidate()
        status = paused ? "Paused" : "Resuming…"
        rebuildMenu()
        if !paused { Task { await check() } }
    }
    @objc private func testNotification() { Task { await sendTest() } }
    private func sendTest() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshPermission()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                status = "Enable notifications in Settings to test"
                rebuildMenu()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Pinga is ready"
            content.body = "PR comments, reviews and replies will appear here."
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "pr-ping-test", content: content, trigger: nil))
            status = "Test notification sent"
            rebuildMenu()
        } catch { status = "Test failed: \(error.localizedDescription)"; rebuildMenu() }
    }
    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    @objc private func openHelp() {
        let alert = NSAlert()
        alert.messageText = "Pinga"
        alert.informativeText = "Watches PRs you create on github.com, in your selected sources, including recently closed PRs. Choose Manage sources to add or remove repositories or organisations. Checks about once a minute and slows down for errors or rate limits. A full refresh every 15 minutes catches activity missed by GitHub search.\n\nUses your existing GitHub CLI login. If authentication fails, run gh auth login --hostname github.com in Terminal, then choose Check now.\n\nThe first scan is quiet. Your own comments are ignored. Start Pinga again after restarting your Mac."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func openEvent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openGitHub(url) } }
    private func openGitHub(_ url: URL) {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: value) else { return }
        await MainActor.run { self.openGitHub(url) }
    }
}

// A notification probe does not access monitor state and can run alongside the menu app.
if CommandLine.arguments.contains("--notification-probe") {
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.accessory)
    if let iconURL = Bundle.main.url(forResource: "PRPing", withExtension: "icns") {
        probeApp.applicationIconImage = NSImage(contentsOf: iconURL)
    }
    Task {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        print("Notification authorization: \(settings.authorizationStatus.rawValue)")
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { exit(1) }
        do {
            let content = UNMutableNotificationContent()
            content.title = "Pinga is ready"
            content.body = "PR comments, reviews and replies will appear here."
            content.sound = .default
            content.userInfo = ["url": "https://github.com/pulls"]
            try await center.add(UNNotificationRequest(identifier: "pinga-icon-check-\(UUID().uuidString)", content: content, trigger: nil))
            print("Native test notification accepted")
            try await Task.sleep(for: .seconds(3))
            exit(0)
        } catch { print(error.localizedDescription); exit(1) }
    }
    RunLoop.main.run()
}

// Both GUI and diagnostic mode use this lock so two processes cannot overwrite state.
func acquireStateLock() -> Int32 {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PR Ping", isDirectory: true)
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { return -1 }
    let descriptor = open(directory.appendingPathComponent("monitor.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { return -1 }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return -1 }
    return descriptor
}

let stateLock = acquireStateLock()
guard stateLock >= 0 else {
    print("Pinga is already running or its state folder is unavailable")
    exit(1)
}

if CommandLine.arguments.contains("--diagnose") {
    Task {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PR Ping", isDirectory: true)
            let monitor = Monitor(stateURL: directory.appendingPathComponent("state.json"))
            let result = try await monitor.poll()
            print("Account: \(result.login); PRs: \(result.prCount); open PR links: \(result.openPRs.count); pending alerts: \(result.events.count); next check: \(Int(result.nextDelay))s")
            exit(0)
        } catch { print(error.localizedDescription); exit(1) }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
