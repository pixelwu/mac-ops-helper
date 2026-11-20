import Cocoa
import Foundation

enum DaemonState: Equatable {
    case running(projectCount: Int, heartbeatAge: Int)
    case paused(projectCount: Int, heartbeatAge: Int)
    case stopped(projectCount: Int)
    case failed(reason: String, projectCount: Int)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var pollTimer: Timer?
    private let workQueue = DispatchQueue(label: "com.user.ops-menubar.worker", qos: .utility)

    private var currentState: DaemonState = .stopped(projectCount: 0)
    private var currentProjects: [String] = []
    private var graceUntil: Date = Date().addingTimeInterval(10)
    private var hasNotifiedFailure: Bool = false
    private var isPolling: Bool = false

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    private let daemonLabel = "com.user.ops-watch"
    private let heartbeatTimeoutSec = 15

    private var opsBinPath: String { "\(homeDir)/.local/bin/ops" }
    private var stateDir: String { "\(homeDir)/.local/state/ops" }
    private var heartbeatFile: String { "\(stateDir)/heartbeat" }
    private var pausedFile: String { "\(stateDir)/paused" }
    private var stoppedFile: String { "\(stateDir)/stopped_by_user" }
    private var logFile: String { "\(stateDir)/watch-daemon.log" }
    private var projectsFile: String { "\(homeDir)/.ops-watch-projects" }
    private var domainTarget: String { "gui/\(getuid())/\(daemonLabel)" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        updateStatusIcon(for: currentState, inGracePeriod: true)
        pollStatus()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleSystemWake() {
        graceUntil = Date().addingTimeInterval(10)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.pollStatus()
        }
    }

    // MARK: - Polling & State Detection

    private func pollStatus() {
        guard !isPolling else { return }
        isPolling = true

        workQueue.async { [weak self] in
            guard let self = self else { return }
            let projects = self.readProjects()
            let state = self.detectDaemonState(projectCount: projects.count)

            DispatchQueue.main.async {
                self.isPolling = false
                self.currentProjects = projects
                self.applyNewState(state)
            }
        }
    }

    private func detectDaemonState(projectCount: Int) -> DaemonState {
        let launchdRunning = isLaunchdRunning()
        let fm = FileManager.default
        let isPaused = fm.fileExists(atPath: pausedFile)
        let isStoppedByUser = fm.fileExists(atPath: stoppedFile)
        let heartbeatAge = readHeartbeatAge()

        if launchdRunning {
            guard let age = heartbeatAge else {
                return .failed(reason: "暂无心跳记录", projectCount: projectCount)
            }
            if age > heartbeatTimeoutSec {
                return .failed(reason: "心跳超时 \(age)s", projectCount: projectCount)
            }
            if isPaused {
                return .paused(projectCount: projectCount, heartbeatAge: age)
            }
            return .running(projectCount: projectCount, heartbeatAge: age)
        } else {
            if isStoppedByUser {
                return .stopped(projectCount: projectCount)
            }
            return .failed(reason: "后台守护未运行", projectCount: projectCount)
        }
    }

    private func isLaunchdRunning() -> Bool {
        let result = runCommand(executable: "/bin/launchctl", arguments: ["print", domainTarget])
        guard result.exitCode == 0 else { return false }
        return result.output.contains("state = running")
    }

    private func readHeartbeatAge() -> Int? {
        guard let content = try? String(contentsOfFile: heartbeatFile, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ts = Int(trimmed) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        return max(0, now - ts)
    }

    private func readProjects() -> [String] {
        guard let content = try? String(contentsOfFile: projectsFile, encoding: .utf8) else {
            return []
        }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func applyNewState(_ newState: DaemonState) {
        let inGrace = Date() < graceUntil
        currentState = newState
        updateStatusIcon(for: newState, inGracePeriod: inGrace)

        switch newState {
        case .failed(let reason, _):
            if !inGrace && !hasNotifiedFailure {
                hasNotifiedFailure = true
                sendFailureNotification(reason: reason)
            }
        case .running, .paused, .stopped:
            hasNotifiedFailure = false
        }
    }

    // MARK: - Icon Rendering (Minimal SF Symbols, Red Only on Failure)

    private func updateStatusIcon(for state: DaemonState, inGracePeriod: Bool) {
        guard let button = statusItem.button else { return }

        switch state {
        case .running:
            button.image = makeTemplateSymbol(name: "bolt.circle.fill")
            button.alphaValue = 1.0
            button.toolTip = "ops 守护运行中"

        case .paused:
            button.image = makeTemplateSymbol(name: "pause.circle")
            button.alphaValue = 0.55
            button.toolTip = "ops 守护已暂停监听"

        case .stopped:
            button.image = makeTemplateSymbol(name: "circle.slash")
            button.alphaValue = 0.50
            button.toolTip = "ops 守护已手动停止"

        case .failed(let reason, _):
            if inGracePeriod {
                button.image = makeTemplateSymbol(name: "bolt.circle")
                button.alphaValue = 0.55
                button.toolTip = "ops 正在检测状态..."
            } else {
                button.image = makeRedAlertSymbol(name: "exclamationmark.triangle.fill")
                button.alphaValue = 1.0
                button.toolTip = "ops 守护异常：\(reason)（点击恢复）"
            }
        }
    }

    private func makeTemplateSymbol(name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "ops")?.withSymbolConfiguration(config) else {
            return nil
        }
        img.isTemplate = true
        return img
    }

    private func makeRedAlertSymbol(name: String) -> NSImage? {
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let combined = sizeConfig.applying(colorConfig)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "ops 异常")?.withSymbolConfiguration(combined) else {
            return nil
        }
        img.isTemplate = false
        return img
    }

    // MARK: - Notifications (osascript for reliable unsigned local delivery)

    private func sendFailureNotification(reason: String) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let escapedReason = reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "display notification \"\(escapedReason)，点击顶栏图标可一键恢复\" with title \"ops 守护异常\""
            _ = self.runCommand(executable: "/usr/bin/osascript", arguments: ["-e", script])
        }
    }

    // MARK: - Menu Construction

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        pollStatus()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Section 1: Status Header
        let headerTitle: String
        switch currentState {
        case .running(let count, _):
            headerTitle = "● 运行中 · 监听 \(count) 个项目"
        case .paused(let count, _):
            headerTitle = "⏸ 已暂停监听 · 监听 \(count) 个项目"
        case .stopped:
            headerTitle = "○ 已手动停止后台守护"
        case .failed(let reason, _):
            headerTitle = "▲ 守护异常 · \(reason)"
        }
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Section 2: Dynamic Daemon Controls
        switch currentState {
        case .failed, .stopped:
            let startItem = NSMenuItem(title: "一键恢复并启动守护", action: #selector(startDaemon), keyEquivalent: "r")
            startItem.target = self
            menu.addItem(startItem)

        case .running:
            let pauseItem = NSMenuItem(title: "暂停监听", action: #selector(pauseDaemon), keyEquivalent: "p")
            pauseItem.target = self
            menu.addItem(pauseItem)

            let restartItem = NSMenuItem(title: "重启守护", action: #selector(restartDaemon), keyEquivalent: "r")
            restartItem.target = self
            menu.addItem(restartItem)

            let stopItem = NSMenuItem(title: "停止后台守护", action: #selector(stopDaemon), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)

        case .paused:
            let resumeItem = NSMenuItem(title: "恢复监听", action: #selector(resumeDaemon), keyEquivalent: "p")
            resumeItem.target = self
            menu.addItem(resumeItem)

            let restartItem = NSMenuItem(title: "重启守护", action: #selector(restartDaemon), keyEquivalent: "r")
            restartItem.target = self
            menu.addItem(restartItem)

            let stopItem = NSMenuItem(title: "停止后台守护", action: #selector(stopDaemon), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Section 3: Projects, Logs & Quit
        let projectsRoot = NSMenuItem(title: "监听项目 (\(currentProjects.count))", action: nil, keyEquivalent: "")
        let projectsSubmenu = NSMenu()
        if currentProjects.isEmpty {
            let emptyItem = NSMenuItem(title: "暂无监听项目", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            projectsSubmenu.addItem(emptyItem)
        } else {
            for path in currentProjects {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let exists = FileManager.default.fileExists(atPath: path)
                let label = exists ? name : "\(name) [目录不存在]"
                let item = NSMenuItem(title: label, action: #selector(openProjectFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path
                item.isEnabled = exists
                projectsSubmenu.addItem(item)
            }
        }
        projectsRoot.submenu = projectsSubmenu
        menu.addItem(projectsRoot)

        let logItem = NSMenuItem(title: "查看守护日志", action: #selector(openDaemonLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        let refreshItem = NSMenuItem(title: "立即刷新状态", action: #selector(manualRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出顶栏图标", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.toolTip = "仅关闭顶栏图标，不影响后台 ops daemon 继续运行"
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func startDaemon() {
        graceUntil = Date().addingTimeInterval(6)
        hasNotifiedFailure = false
        runOpsDaemonAction("start")
    }

    @objc private func restartDaemon() {
        graceUntil = Date().addingTimeInterval(6)
        hasNotifiedFailure = false
        runOpsDaemonAction("restart")
    }

    @objc private func pauseDaemon() {
        runOpsDaemonAction("pause")
    }

    @objc private func resumeDaemon() {
        runOpsDaemonAction("resume")
    }

    @objc private func stopDaemon() {
        hasNotifiedFailure = false
        runOpsDaemonAction("stop")
    }

    @objc private func manualRefresh() {
        pollStatus()
    }

    @objc private func openProjectFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openDaemonLog() {
        let fm = FileManager.default
        if fm.fileExists(atPath: logFile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logFile))
        } else if fm.fileExists(atPath: stateDir) {
            NSWorkspace.shared.open(URL(fileURLWithPath: stateDir))
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func runOpsDaemonAction(_ subcommand: String) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.runCommand(
                executable: "/bin/bash",
                arguments: [self.opsBinPath, "daemon", subcommand]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.pollStatus()
            }
        }
    }

    private func runCommand(executable: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = homeDir
        env["PATH"] = "\(homeDir)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, out)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
