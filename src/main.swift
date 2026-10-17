// B站加速: launches 哔哩哔哩 with its Node inspector paused on the first line, injects hook.js
// (redirects overseas CDN nodes to a domestic one), resumes the app and closes the inspector.
// Lives in the menu bar while 哔哩哔哩 runs and quits with it.
import AppKit
import Foundation
import SwiftUI
import Combine

let biliBundleID = "com.bilibili.bilibiliPC"
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BiliCDN")
let configURL = supportDir.appendingPathComponent("config.json")
let statsURL = supportDir.appendingPathComponent("stats.json")

let nodes: [(host: String, label: String)] = [
    ("upos-sz-mirror08c.bilivideo.com", "08c（国内·移动）"),
    ("upos-sz-mirrorhwb.bilivideo.com", "hwb（国内·华为）"),
    ("upos-sz-mirrorhw.bilivideo.com", "hw（国内·华为）"),
]

struct Config: Codable { var target: String; var enabled: Bool }
struct Stats: Codable { var pid: Int32; var target: String?; var enabled: Bool?; var redirects: Int; var err: String? }

func readConfig() -> Config {
    if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
    return Config(target: nodes[0].host, enabled: true)
}
func writeConfig(_ c: Config) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? JSONEncoder().encode(c).write(to: configURL, options: .atomic)
}
func readStats() -> Stats? {
    guard let d = try? Data(contentsOf: statsURL) else { return nil }
    return try? JSONDecoder().decode(Stats.self, from: d)
}

// MARK: - Inspector (Chrome DevTools Protocol over WebSocket)

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let url = supportDir.appendingPathComponent("launcher.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}

final class Inspector {
    let task: URLSessionWebSocketTask
    var nextID = 0
    var events: [String] = []

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    /// Sends a command and waits for its response, skipping events.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await task.send(.string(String(data: body, encoding: .utf8)!))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msg = try await task.receive()
            guard case .string(let s) = msg,
                  let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
            if obj["id"] as? Int == id { return obj }
            if let m = obj["method"] as? String { events.append(m) }
        }
        throw NSError(domain: "BiliCDN", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(method) timed out"])
    }

    /// Waits for an event (e.g. Debugger.paused), including one already received during a call.
    func waitFor(_ method: String, timeout: TimeInterval) async throws -> Bool {
        if events.contains(method) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msg = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { g in
                g.addTask { try await self.task.receive() }
                g.addTask { try await Task.sleep(nanoseconds: UInt64(max(0.05, deadline.timeIntervalSinceNow) * 1e9)); return nil }
                let first = try await g.next()!
                g.cancelAll()
                return first
            }
            guard let msg, case .string(let s) = msg,
                  let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
            if obj["method"] as? String == method { return true }
        }
        return false
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    static func connect(port: Int, timeout: TimeInterval = 20) async throws -> Inspector {
        let listURL = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: listURL),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let ws = list.first?["webSocketDebuggerUrl"] as? String, let url = URL(string: ws) {
                return Inspector(url: url)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NSError(domain: "BiliCDN", code: 2, userInfo: [NSLocalizedDescriptionKey: "哔哩哔哩没有打开调试端口"])
    }
}

func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return Int(UInt16(bigEndian: addr.sin_port))
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var biliPID: pid_t?
    var lastError: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        if !FileManager.default.fileExists(atPath: configURL.path) { writeConfig(readConfig()) }
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "B站加速")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        Task { await startBili(askBeforeRestart: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the launcher again while 哔哩哔哩 runs with the hook: open the settings window.
        // (The menu bar icon can end up hidden behind the notch.) Otherwise (re)start 哔哩哔哩.
        if hooked { showSettings() } else { Task { await startBili(askBeforeRestart: true) } }
        return false
    }

    var settingsWindow: NSWindow?

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(status: { [weak self] in self?.statusText() ?? "" },
                                    restart: { [weak self] in self?.restartBili() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "B站加速"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func statusText() -> String {
        let cfg = readConfig()
        if let e = lastError { return "出错：\(e)" }
        if runningBili == nil { return "哔哩哔哩未运行" }
        if !hooked { return "未加速（哔哩哔哩不是从这里启动的）" }
        if !cfg.enabled { return "已暂停，使用 B 站默认节点" }
        return "已加速 · 已转到国内节点 \(readStats()?.redirects ?? 0) 次"
    }

    @objc func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == biliBundleID, app.processIdentifier == biliPID else { return }
        NSApp.terminate(nil)
    }

    var runningBili: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: biliBundleID).first
    }

    /// stats.json records the pid of the Electron main process the hook was injected into.
    var hooked: Bool {
        guard let app = runningBili, let s = readStats() else { return false }
        return s.pid == app.processIdentifier
    }

    @MainActor
    func startBili(askBeforeRestart: Bool) async {
        if let app = runningBili {
            if hooked {
                // Already accelerated (e.g. the launcher was quit and reopened): show the settings.
                biliPID = app.processIdentifier
                showSettings()
                return
            }
            if askBeforeRestart {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "哔哩哔哩已经在运行"
                alert.informativeText = "需要重启哔哩哔哩才能启用 CDN 加速。"
                alert.addButton(withTitle: "重启")
                alert.addButton(withTitle: "取消")
                if alert.runModal() != .alertFirstButtonReturn {
                    if biliPID == nil { NSApp.terminate(nil) }
                    return
                }
            }
            app.terminate()
            for _ in 0..<60 where !app.isTerminated { try? await Task.sleep(nanoseconds: 250_000_000) }
            if !app.isTerminated { app.forceTerminate() }
        }
        await launchHooked()
    }

    @MainActor
    func launchHooked() async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: biliBundleID),
              let hookURL = Bundle.main.url(forResource: "hook", withExtension: "js"),
              let hook = try? String(contentsOf: hookURL, encoding: .utf8) else {
            fail("找不到哔哩哔哩 App 或 hook.js")
            return
        }
        let port = freePort()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--inspect-brk=127.0.0.1:\(port)"]
        cfg.createsNewApplicationInstance = false
        do {
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
            biliPID = app.processIdentifier
            log("launched pid \(app.processIdentifier), inspector port \(port)")
            let insp = try await Inspector.connect(port: port)
            log("inspector connected")
            try await insp.call("Runtime.enable")
            try await insp.call("Debugger.enable")
            try await insp.call("Runtime.runIfWaitingForDebugger")
            let paused = try await insp.waitFor("Debugger.paused", timeout: 5)
            log("paused on first line: \(paused)")
            let r = try await insp.call("Runtime.evaluate", ["expression": hook, "includeCommandLineAPI": true, "returnByValue": true])
            log("inject: \(((r["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] ?? r)")
            try await insp.call("Debugger.resume")
            try await insp.call("Debugger.disable")
            // Shut the inspector port so nothing else on this Mac can attach later.
            _ = try? await insp.call("Runtime.evaluate", ["expression": "setTimeout(() => process._debugEnd(), 500); 0", "includeCommandLineAPI": true], timeout: 3)
            insp.close()
            if let res = r["result"] as? [String: Any], res["exceptionDetails"] != nil {
                fail("注入失败：\(res["exceptionDetails"]!)")
            } else {
                lastError = nil
            }
        } catch {
            log("error: \(error)")
            fail(error.localizedDescription)
        }
    }

    func fail(_ msg: String) {
        lastError = msg
        statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "B站加速出错")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = readConfig()
        let s = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())

        for n in nodes {
            let item = NSMenuItem(title: n.label, action: #selector(pickNode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = n.host
            item.state = cfg.enabled && cfg.target == n.host ? .on : .off
            menu.addItem(item)
        }
        let off = NSMenuItem(title: "暂停（用 B 站默认节点）", action: #selector(pickNode(_:)), keyEquivalent: "")
        off.target = self
        off.state = cfg.enabled ? .off : .on
        menu.addItem(off)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "打开设置窗口…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let restart = NSMenuItem(title: hooked ? "重启哔哩哔哩" : "重启哔哩哔哩并启用加速", action: #selector(restartBili), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let quit = NSMenuItem(title: "退出 B站加速", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func pickNode(_ sender: NSMenuItem) {
        var cfg = readConfig()
        if let host = sender.representedObject as? String { cfg.target = host; cfg.enabled = true }
        else { cfg.enabled = false }
        writeConfig(cfg) // the hook watches this file; no restart needed
    }

    @objc func restartBili() {
        Task { await startBili(askBeforeRestart: false) }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    let status: () -> String
    let restart: () -> Void
    @State private var cfg = readConfig()
    @State private var statusLine = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var choice: Binding<String> {
        Binding(
            get: { cfg.enabled ? cfg.target : "off" },
            set: { v in
                if v == "off" { cfg.enabled = false } else { cfg.target = v; cfg.enabled = true }
                writeConfig(cfg) // the hook watches this file; takes effect without a restart
                statusLine = status()
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(statusLine).font(.headline)
            Picker("视频节点", selection: choice) {
                ForEach(nodes, id: \.host) { Text($0.label).tag($0.host) }
                Text("暂停（用 B 站默认节点）").tag("off")
            }
            .pickerStyle(.radioGroup)
            Text("切换节点立即生效，不用重启。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("重启哔哩哔哩", action: restart)
                Spacer()
                Button("退出 B站加速") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { cfg = readConfig(); statusLine = status() }
        .onReceive(timer) { _ in statusLine = status() }
    }
}

/// `BiliCDN --snapshot out.png ["status line"]`: renders the settings window to a PNG
/// (used for the README screenshot; needs no screen-recording permission).
func renderSnapshot(to path: String, status: String) {
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: SettingsView(status: { status }, restart: {}))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "B站加速"
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5)) // let SwiftUI settle
    guard let frameView = host.superview,
          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(1) }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let status = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : "已加速 · 已转到国内节点 663 次"
    renderSnapshot(to: CommandLine.arguments[i + 1], status: status)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
