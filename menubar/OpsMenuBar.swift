import Cocoa
import Foundation

struct PresenceStatus: Decodable {
    let declared_mode: String
    let effective_mode: String
    let effective_plan: String
    let idle_seconds: Int
    let online_fallback_seconds: Int
    let away_grace_seconds: Int
    let auto_idle_seconds: Int
    let reason: String
    let last_transition: String
    let handoff_requested: Bool
    let daemon_status: String
    let heartbeat_age: Int
}

final class OpsMenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var pollTimer: Timer?
    private var currentStatus: PresenceStatus?
    private var lastDaemonStatus: String = "UNKNOWN"
    private var lastWakeTime: Date = Date.distantPast
    private let opsBin: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/ops"
    }()
    private let daemonLogPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/state/ops/watch-daemon.log"
    }()

    override init() {
        super.init()
        setupStatusItem()
        observeWakeNotifications()
        refreshStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.title = " ops"
            button.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "ops")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func observeWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleSystemWake() {
        lastWakeTime = Date()
    }

    private func runOps(_ args: [String], completion: ((Int32, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [opsBin] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [opsBin] + args

            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["HOME"] = home
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion?(process.terminationStatus, out)
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(-1, error.localizedDescription)
                }
            }
        }
    }

    private func refreshStatus() {
        runOps(["presence", "status", "--json"]) { [weak self] code, output in
            guard let self = self else { return }
            guard code == 0, let data = output.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(PresenceStatus.self, from: data) else {
                self.updateButtonOffline()
                return
            }

            // 休眠唤醒后 10 秒内防误报
            let inWakeGrace = Date().timeIntervalSince(self.lastWakeTime) < 10.0
            if !inWakeGrace && parsed.daemon_status == "FAILED" && self.lastDaemonStatus != "FAILED" {
                self.sendAlertNotification(
                    title: "ops 后台守护异常",
                    body: "检测到 ops daemon 未运行或心跳超时，请点击顶栏图标一键恢复。"
                )
            }
            self.lastDaemonStatus = parsed.daemon_status
            self.currentStatus = parsed
            self.updateButton(with: parsed)
        }
    }

    private func updateButtonOffline() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "ops error")
        button.contentTintColor = .systemRed
        button.title = " ops!"
    }

    private func updateButton(with st: PresenceStatus) {
        guard let button = statusItem.button else { return }

        if st.daemon_status == "FAILED" {
            let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Daemon Failed")
            img?.isTemplate = false
            button.image = img
            button.contentTintColor = .systemRed
            button.title = " 异常"
            return
        }

        if st.daemon_status == "PAUSED" {
            let img = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = nil
            button.title = " 暂停"
            return
        }

        if st.daemon_status == "STOPPED" {
            let img = NSImage(systemSymbolName: "circle.slash", accessibilityDescription: "Stopped")
            img?.isTemplate = true
            button.image = img
            button.contentTintColor = nil
            button.title = " 停用"
            return
        }

        // Daemon RUNNING -> 按当前在线/托管/自动模式展示
        button.contentTintColor = nil
        switch st.declared_mode {
        case "online":
            let img = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "Online")
            img?.isTemplate = true
            button.image = img
            button.title = " 在线"
        case "away":
            let img = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Away Auto")
            img?.isTemplate = true
            button.image = img
            button.title = " 托管"
        default:
            let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Smart Auto")
            img?.isTemplate = true
            button.image = img
            button.title = " 自动"
        }
    }

    private func sendAlertNotification(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let st = currentStatus else {
            let item = NSMenuItem(title: "正在读取 ops 状态…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            menu.addItem(makeActionItem("刷新状态", action: #selector(actionRefresh)))
            menu.addItem(makeActionItem("退出顶栏图标", action: #selector(actionQuit)))
            return
        }

        // 状态摘要
        let modeDesc: String
        switch st.declared_mode {
        case "online": modeDesc = "人在线（手动优先）"
        case "away": modeDesc = "人不在线（全自动托管）"
        default: modeDesc = "智能自动（动态检测）"
        }
        let planDesc = st.effective_plan == "b" ? "方案 B（全自动）" : "方案 A（人工确认）"
        let header1 = NSMenuItem(title: "模式: \(modeDesc) · 守护: \(st.daemon_status)", action: nil, keyEquivalent: "")
        header1.isEnabled = false
        menu.addItem(header1)

        let header2 = NSMenuItem(title: "当前策略: \(planDesc) · 空闲 \(st.idle_seconds)s", action: nil, keyEquivalent: "")
        header2.isEnabled = false
        menu.addItem(header2)

        if !st.last_transition.isEmpty {
            let transItem = NSMenuItem(title: "最近切换: \(st.last_transition)", action: nil, keyEquivalent: "")
            transItem.isEnabled = false
            menu.addItem(transItem)
        }

        menu.addItem(.separator())

        // 显式模式切换
        let onlineItem = makeActionItem("🟢 人在线（手动优先，超时自动接管）", action: #selector(actionSetOnline))
        onlineItem.state = (st.declared_mode == "online") ? .on : .off
        menu.addItem(onlineItem)

        let awayItem = makeActionItem("🤖 人不在线（全自动托管，回来自动交接）", action: #selector(actionSetAway))
        awayItem.state = (st.declared_mode == "away") ? .on : .off
        menu.addItem(awayItem)

        let autoItem = makeActionItem("⚡ 智能自动（按空闲阈值动态分流）", action: #selector(actionSetAuto))
        autoItem.state = (st.declared_mode == "auto") ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        // 阈值动态配置子菜单
        let thresholdRoot = NSMenuItem(title: "阈值设置（动态可调）", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()

        // 1) 在线超时兜底
        let fallbackRoot = NSMenuItem(title: "在线超时兜底（当前 \(formatDuration(st.online_fallback_seconds))）", action: nil, keyEquivalent: "")
        let fallbackMenu = NSMenu()
        for mins in [1, 3, 5, 10, 15] {
            let secs = mins * 60
            let title = mins == 5 ? "\(mins) 分钟（默认）" : "\(mins) 分钟"
            let item = makeActionItem(title, action: #selector(actionSetOnlineFallback(_:)))
            item.tag = secs
            item.state = (st.online_fallback_seconds == secs) ? .on : .off
            fallbackMenu.addItem(item)
        }
        fallbackMenu.addItem(.separator())
        fallbackMenu.addItem(makeActionItem("自定义输入（分钟）…", action: #selector(actionPromptOnlineFallback)))
        fallbackRoot.submenu = fallbackMenu
        thresholdMenu.addItem(fallbackRoot)

        // 2) 离开防误触缓冲
        let graceRoot = NSMenuItem(title: "离开防误触缓冲（当前 \(st.away_grace_seconds) 秒）", action: nil, keyEquivalent: "")
        let graceMenu = NSMenu()
        for secs in [15, 30, 60] {
            let title = secs == 30 ? "\(secs) 秒（默认）" : "\(secs) 秒"
            let item = makeActionItem(title, action: #selector(actionSetAwayGrace(_:)))
            item.tag = secs
            item.state = (st.away_grace_seconds == secs) ? .on : .off
            graceMenu.addItem(item)
        }
        graceMenu.addItem(.separator())
        graceMenu.addItem(makeActionItem("自定义输入（秒）…", action: #selector(actionPromptAwayGrace)))
        graceRoot.submenu = graceMenu
        thresholdMenu.addItem(graceRoot)

        // 3) 智能自动空闲阈值
        let autoIdleRoot = NSMenuItem(title: "智能自动空闲阈值（当前 \(st.auto_idle_seconds) 秒）", action: nil, keyEquivalent: "")
        let autoIdleMenu = NSMenu()
        for secs in [10, 15, 30, 60] {
            let title = secs == 15 ? "\(secs) 秒（默认）" : "\(secs) 秒"
            let item = makeActionItem(title, action: #selector(actionSetAutoIdle(_:)))
            item.tag = secs
            item.state = (st.auto_idle_seconds == secs) ? .on : .off
            autoIdleMenu.addItem(item)
        }
        autoIdleMenu.addItem(.separator())
        autoIdleMenu.addItem(makeActionItem("自定义输入（秒）…", action: #selector(actionPromptAutoIdle)))
        autoIdleRoot.submenu = autoIdleMenu
        thresholdMenu.addItem(autoIdleRoot)

        thresholdRoot.submenu = thresholdMenu
        menu.addItem(thresholdRoot)

        menu.addItem(.separator())

        // 后台守护控制
        if st.daemon_status == "PAUSED" {
            menu.addItem(makeActionItem("恢复后台监听", action: #selector(actionDaemonResume)))
        } else if st.daemon_status == "RUNNING" {
            menu.addItem(makeActionItem("暂停后台监听", action: #selector(actionDaemonPause)))
        }

        if st.daemon_status == "STOPPED" || st.daemon_status == "FAILED" {
            menu.addItem(makeActionItem("启动 / 恢复后台守护", action: #selector(actionDaemonStart)))
        } else {
            menu.addItem(makeActionItem("重启后台守护", action: #selector(actionDaemonRestart)))
            menu.addItem(makeActionItem("停止后台守护", action: #selector(actionDaemonStop)))
        }

        menu.addItem(makeActionItem("查看守护日志", action: #selector(actionOpenLog)))
        menu.addItem(.separator())
        menu.addItem(makeActionItem("退出顶栏图标（守护继续运行）", action: #selector(actionQuit)))
    }

    private func makeActionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 60 && seconds % 60 == 0 {
            return "\(seconds / 60) 分钟"
        }
        return "\(seconds) 秒"
    }

    private func promptInteger(title: String, message: String, defaultValue: Int, minVal: Int) -> Int? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        input.stringValue = "\(defaultValue)"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            if let val = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), val >= minVal {
                return val
            }
        }
        return nil
    }

    // MARK: - Actions

    @objc private func actionSetOnline() {
        runOps(["presence", "online"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionSetAway() {
        runOps(["presence", "away"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionSetAuto() {
        runOps(["presence", "auto"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionSetOnlineFallback(_ sender: NSMenuItem) {
        runOps(["presence", "config", "--online-fallback", "\(sender.tag)"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionPromptOnlineFallback() {
        let curMins = max(1, (currentStatus?.online_fallback_seconds ?? 300) / 60)
        if let mins = promptInteger(
            title: "设置「在线超时兜底」",
            message: "选了「人在线」但连续无人操作多少分钟后，自动切入全自动托管？（最小 1 分钟）",
            defaultValue: curMins,
            minVal: 1
        ) {
            runOps(["presence", "config", "--online-fallback", "\(mins * 60)"]) { [weak self] _, _ in self?.refreshStatus() }
        }
    }

    @objc private func actionSetAwayGrace(_ sender: NSMenuItem) {
        runOps(["presence", "config", "--away-grace", "\(sender.tag)"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionPromptAwayGrace() {
        let cur = currentStatus?.away_grace_seconds ?? 30
        if let secs = promptInteger(
            title: "设置「离开防误触缓冲」",
            message: "点击「人不在线」后多少秒内忽略键鼠操作，防止离开瞬间误触发回切？（最小 5 秒）",
            defaultValue: cur,
            minVal: 5
        ) {
            runOps(["presence", "config", "--away-grace", "\(secs)"]) { [weak self] _, _ in self?.refreshStatus() }
        }
    }

    @objc private func actionSetAutoIdle(_ sender: NSMenuItem) {
        runOps(["presence", "config", "--auto-idle", "\(sender.tag)"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionPromptAutoIdle() {
        let cur = currentStatus?.auto_idle_seconds ?? 15
        if let secs = promptInteger(
            title: "设置「智能自动空闲阈值」",
            message: "智能自动模式下，键鼠空闲多少秒后允许自动走方案 B？（最小 5 秒）",
            defaultValue: cur,
            minVal: 5
        ) {
            runOps(["presence", "config", "--auto-idle", "\(secs)"]) { [weak self] _, _ in self?.refreshStatus() }
        }
    }

    @objc private func actionDaemonPause() {
        runOps(["daemon", "pause"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionDaemonResume() {
        runOps(["daemon", "resume"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionDaemonStart() {
        runOps(["daemon", "start"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionDaemonRestart() {
        runOps(["daemon", "restart"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionDaemonStop() {
        runOps(["daemon", "stop"]) { [weak self] _, _ in self?.refreshStatus() }
    }

    @objc private func actionOpenLog() {
        if !FileManager.default.fileExists(atPath: daemonLogPath) {
            FileManager.default.createFile(atPath: daemonLogPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: daemonLogPath))
    }

    @objc private func actionRefresh() {
        refreshStatus()
    }

    @objc private func actionQuit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = OpsMenuBarController()
app.delegate = nil
withExtendedLifetime(controller) {
    app.run()
}
