import AppKit
import SwiftUI
import Combine
import UserNotifications

// MARK: - 应用代理：状态栏 + 弹窗 + 调度
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var state: AppState!
    private var coordinator: Coordinator!
    private var cancellable: AnyCancellable?

    private var dailyTimer: Timer?
    private var zcodeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        coordinator = Coordinator(state: state)

        setupStatusItem()
        setupPopover()

        // 状态变化 → 刷新托盘图标
        cancellable = state.objectWillChange.sink { [weak self] in
            self?.refreshTray()
        }
        refreshTray()

        setupSchedulers()
        // 启动后稍候执行一次状态扫描
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await coordinator.initialScan() }
    }

    // MARK: 状态栏
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(statusClicked(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 478, height: 568)
        let root = ContentView()
            .environmentObject(state)
            .environmentObject(coordinator)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showMenu() } else { togglePopover() }
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let btn = statusItem.button {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let all = NSMenuItem(title: "立即签到（全部平台）", action: #selector(checkAll), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 TraeSign", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func checkAll() { Task { await coordinator.refreshAll(queryOnly: false) } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLoginItem() {
        if isLoginItemEnabled() { removeLoginItem() } else { installLoginItem() }
    }

    // MARK: 托盘图标
    private func refreshTray() { Task { @MainActor in self.updateTrayIcon() } }

    @MainActor private func updateTrayIcon() {
        let agg = state.aggregate
        let (name, color): (String, NSColor) = {
            switch agg {
            case .allDone:  return ("checkmark.circle.fill", .systemGreen)
            case .error:    return ("exclamationmark.circle.fill", .systemRed)
            case .pending:  return ("circle.fill", .systemYellow)
            case .idle:     return ("circle", .tertiaryLabelColor)
            }
        }()
        statusItem.button?.image = makeTrayImage(systemName: name, color: color)
    }

    private func makeTrayImage(systemName: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let out = NSImage(size: size)
        out.lockFocus()
        color.set()
        let tpl = base.copy() as! NSImage
        tpl.isTemplate = true
        tpl.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    // MARK: 调度
    private func setupSchedulers() {
        scheduleDaily(hour: 0, minute: 5) { [weak self] in
            guard let self else { return }
            if await self.state.isEnabled(.trae) { _ = await self.coordinator.refresh(.trae) }
            if await self.state.isEnabled(.workbuddy) { _ = await self.coordinator.refresh(.workbuddy) }
        }
        zcodeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                if await self.state.isEnabled(.zcode) { _ = await self.coordinator.refresh(.zcode) }
            }
        }
    }

    /// 每天指定时间触发一次，并自动安排次日
    private func scheduleDaily(hour: Int, minute: Int, block: @escaping () async -> Void) {
        let fire = nextFireDate(hour: hour, minute: minute)
        dailyTimer?.invalidate()
        dailyTimer = Timer(fire: fire, interval: 86400, repeats: true) { _ in
            Task { await block() }
        }
        RunLoop.main.add(dailyTimer!, forMode: .common)
    }

    private func nextFireDate(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard var next = Calendar.current.date(from: comps) else { return Date() }
        if next <= Date() { next = Calendar.current.date(byAdding: .day, value: 1, to: next) ?? next }
        return next
    }

    // MARK: 登录项（LaunchAgent）
    private func launchAgentURL() -> URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("LaunchAgents/com.traesign.macos.plist")
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL().path)
    }

    private func installLoginItem() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let plist: [String: Any] = [
            "Label": "com.traesign.macos",
            "ProgramArguments": [bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL())
            notify("已设置登录启动", "TraeSign 将在登录时自动运行")
        } catch { notify("设置失败", error.localizedDescription) }
    }

    private func removeLoginItem() {
        try? FileManager.default.removeItem(at: launchAgentURL())
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
