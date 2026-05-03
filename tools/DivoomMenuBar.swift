import AppKit
import Foundation

final class DivoomMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let repo: URL
    let toolRoot: URL
    let supportDir: URL
    var daemonProcess: Process?
    var statusItemViewTimer: Timer?
    var lastMessage = "Ready"

    let address = "B1:21:81:B1:F0:84"
    let channel = "1"
    let daemonPort = "40583"
    var menuLog: URL { supportDir.appendingPathComponent("divoom-menubar.log") }
    var daemonLog: URL { supportDir.appendingPathComponent("divoom-menubar-daemon.log") }
    var daemonPidFile: URL { supportDir.appendingPathComponent("divoom-menubar-daemon.pid") }
    var capturesDir: URL { supportDir.appendingPathComponent("captures/mac-send") }

    override init() {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let resources = Bundle.main.resourceURL
        let bundledTools = resources?.appendingPathComponent("tools")
        if let resources, let bundledTools, fm.fileExists(atPath: bundledTools.appendingPathComponent("divoom-daemon").path) {
            self.repo = resources
            self.toolRoot = bundledTools
        } else {
            self.repo = cwd
            self.toolRoot = cwd.appendingPathComponent("tools")
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? cwd
        self.supportDir = appSupport.appendingPathComponent("DivoomMiniToo", isDirectory: true)
        super.init()
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: capturesDir, withIntermediateDirectories: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appendLog("menubar started repo=\(repo.path)")
        statusItem.button?.title = "◈ Divoom"
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        statusItemViewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        refreshTitle()
        startDaemon(disconnectFirst: true)
    }

    func refreshTitle() {
        let running = isDaemonRunning()
        statusItem.button?.title = running ? "◆ Divoom" : "◇ Divoom"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitle()
        rebuildMenu()
    }

    func rebuildMenu() {
        let daemonRunning = isDaemonRunning()
        let audioConnected = isAudioConnected()
        menu.removeAllItems()
        menu.addItem(disabled("Daemon: \(daemonRunning ? "Running" : "Stopped")"))
        menu.addItem(disabled("Audio profile: \(audioConnected ? "Connected" : "Disconnected")"))
        menu.addItem(disabled("Last: \(shortStatus(lastMessage))"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Send Image/GIF/Video…", #selector(sendImage), enabled: daemonRunning))
        menu.addItem(item("Activate Custom Face 1", #selector(activateCustomFace1), enabled: daemonRunning))
        menu.addItem(item("Activate Custom Face 2", #selector(activateCustomFace2), enabled: daemonRunning))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Start Daemon (only if audio disconnected)", #selector(startDaemonMenu), enabled: !daemonRunning && !audioConnected))
        menu.addItem(item("Disconnect Audio + Start Daemon", #selector(disconnectAndStartMenu), enabled: !daemonRunning))
        menu.addItem(item("Stop Daemon", #selector(stopDaemonMenu), enabled: daemonRunning))
        menu.addItem(item("Restart Daemon", #selector(restartDaemonMenu), enabled: true))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Disconnect Divoom Audio", #selector(disconnectAudioMenu), enabled: audioConnected))
        menu.addItem(item("Reconnect Divoom Audio", #selector(reconnectAudioMenu), enabled: !audioConnected))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Captures Folder", #selector(openCaptures)))
        menu.addItem(item("Open Protocol Notes", #selector(openProtocol)))
        menu.addItem(item("Open Menu Log", #selector(openMenuLog)))
        menu.addItem(item("Open Daemon Log", #selector(openDaemonLog)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Quit", #selector(quit)))
    }

    func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled
        return i
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func shortStatus(_ message: String, limit: Int = 72) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= limit { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }

    func executablePath(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(_ executable: String, _ args: [String], wait: Bool = true) -> (Int32, String) {
        appendLog("run \(executable) \(args.joined(separator: " ")) wait=\(wait)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, String(describing: error)) }
        if wait { p.waitUntilExit() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if wait { appendLog("run exit=\(p.terminationStatus) out=\(String(out.suffix(500)))") }
        return (p.terminationStatus, out)
    }

    func isDaemonRunning() -> Bool {
        if let pidText = try? String(contentsOf: daemonPidFile, encoding: .utf8),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           kill(pid, 0) == 0 {
            return true
        }
        let daemonPath = toolRoot.appendingPathComponent("divoom-daemon").path.replacingOccurrences(of: "'", with: "'\\''")
        let (code, _) = run("/bin/sh", ["-lc", "pgrep -f '\(daemonPath)' >/dev/null || pgrep -f 'divoom-daemon' >/dev/null"], wait: true)
        return code == 0
    }

    func isAudioConnected() -> Bool {
        guard let blueutil = executablePath("blueutil") else { return false }
        let (code, out) = run(blueutil, ["--is-connected", address], wait: true)
        return code == 0 && out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func setStatus(_ message: String) {
        appendLog("status \(message)")
        DispatchQueue.main.async {
            self.lastMessage = self.shortStatus(message, limit: 160)
            self.refreshTitle()
            self.rebuildMenu()
        }
    }

    func startDaemon(disconnectFirst: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            if disconnectFirst, let blueutil = self.executablePath("blueutil") {
                _ = self.run(blueutil, ["--disconnect", self.address])
            }
            Thread.sleep(forTimeInterval: disconnectFirst ? 1.5 : 0.0)
            if self.isDaemonRunning() {
                self.setStatus("Daemon already running")
                return
            }
            let log = self.daemonLog
            let p = Process()
            p.executableURL = self.toolRoot.appendingPathComponent("divoom-daemon")
            p.arguments = [self.address, self.channel, self.daemonPort]
            p.currentDirectoryURL = self.repo
            let logHandle: FileHandle
            FileManager.default.createFile(atPath: log.path, contents: nil)
            do {
                logHandle = try FileHandle(forWritingTo: log)
                logHandle.truncateFile(atOffset: 0)
            } catch {
                self.notify("Failed to open daemon log: \(error)")
                return
            }
            p.standardOutput = logHandle
            p.standardError = logHandle
            do {
                try p.run()
                self.daemonProcess = p
                try? "\(p.processIdentifier)\n".write(to: self.daemonPidFile, atomically: true, encoding: .utf8)
                self.appendLog("daemon launched pid=\(p.processIdentifier) disconnectFirst=\(disconnectFirst)")
                Thread.sleep(forTimeInterval: 2.0)
                if self.isDaemonRunning() {
                    self.setStatus("Daemon started")
                } else {
                    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: self.daemonPidFile)
                    if logText.contains("0x-1ffffd44") {
                        self.setStatus("Start failed: audio/RFCOMM busy; use Disconnect Audio + Start")
                    } else {
                        self.setStatus("Daemon failed; see daemon log")
                    }
                }
            } catch {
                self.setStatus("Start failed: \(error)")
            }
        }
    }

    func stopDaemon() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.daemonProcess?.terminate()
            self.daemonProcess = nil
            _ = self.run("/usr/bin/pkill", ["-f", "divoom-daemon"])
            try? FileManager.default.removeItem(at: self.daemonPidFile)
            self.setStatus("Daemon stopped")
        }
    }

    @objc func startDaemonMenu() { startDaemon(disconnectFirst: false) }
    @objc func disconnectAndStartMenu() { startDaemon(disconnectFirst: true) }
    @objc func stopDaemonMenu() { stopDaemon() }
    @objc func restartDaemonMenu() {
        stopDaemon()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { self.startDaemon(disconnectFirst: true) }
    }

    @objc func disconnectAudioMenu() {
        DispatchQueue.global().async {
            guard let blueutil = self.executablePath("blueutil") else {
                self.setStatus("blueutil not found")
                return
            }
            let (_, out) = self.run(blueutil, ["--disconnect", self.address])
            self.setStatus(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Audio disconnected" : out)
        }
    }

    @objc func reconnectAudioMenu() {
        DispatchQueue.global().async {
            guard let blueutil = self.executablePath("blueutil") else {
                self.setStatus("blueutil not found")
                return
            }
            let (_, out) = self.run(blueutil, ["--connect", self.address])
            self.setStatus(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Audio reconnect requested" : out)
        }
    }

    @objc func sendImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .image, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.isDaemonRunning() {
                self.setStatus("Daemon not running")
                return
            }
            let venvPy = self.repo.appendingPathComponent(".venv/bin/python").path
            let py = FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : (self.executablePath("python3") ?? "/usr/bin/python3")
            let client = self.toolRoot.appendingPathComponent("divoom_send.py").path
            let (code, out) = self.run(py, [client, url.path, "--out-dir", self.capturesDir.path])
            let detail = String(out.suffix(900))
            self.setStatus(code == 0 ? "Media sent" : "Send issue: \(detail)")
        }
    }

    func activateClock(_ shortcut: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.isDaemonRunning() {
                self.setStatus("Daemon not running")
                return
            }
            let venvPy = self.repo.appendingPathComponent(".venv/bin/python").path
            let py = FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : (self.executablePath("python3") ?? "/usr/bin/python3")
            let client = self.toolRoot.appendingPathComponent("divoom_clock.py").path
            let (code, out) = self.run(py, [client, shortcut])
            let detail = String(out.suffix(700))
            self.setStatus(code == 0 ? "Activated custom face \(shortcut)" : "Clock issue: \(detail)")
        }
    }

    @objc func activateCustomFace1() { activateClock("custom1") }
    @objc func activateCustomFace2() { activateClock("custom2") }

    @objc func openCaptures() {
        NSWorkspace.shared.open(capturesDir)
    }

    @objc func openProtocol() {
        let bundled = repo.appendingPathComponent("PROTOCOL.md")
        if FileManager.default.fileExists(atPath: bundled.path) {
            NSWorkspace.shared.open(bundled)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("PROTOCOL.md"))
        }
    }

    @objc func openMenuLog() {
        NSWorkspace.shared.open(menuLog)
    }

    @objc func openDaemonLog() {
        NSWorkspace.shared.open(daemonLog)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func notify(_ title: String, detail: String = "") { setStatus(detail.isEmpty ? title : "\(title): \(detail)") }

    func appendLog(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let text = "[\(ts)] \(line)\n"
        FileManager.default.createFile(atPath: menuLog.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: menuLog) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }
}

let app = NSApplication.shared
let delegate = DivoomMenuBar()
app.delegate = delegate
app.run()
