import Cocoa
import ServiceManagement

// CodexQuota — macOS menu bar quota monitor for AI coding subscriptions.
//
// On launch the app AUTO-DETECTS which supported services are configured on
// this machine (credential probing only — no data leaves the machine), lists
// them in the menu, and lets the user tick which ones appear in the status bar.
//
//   • Codex (ChatGPT OAuth)   : GET https://chatgpt.com/backend-api/wham/usage
//     Credential: ~/.codex/auth.json → tokens.access_token (+ chatgpt-account-id)
//   • GLM Coding Plan (Zhipu) : GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
//     Credential: GLM_API_KEY env var, or CUSTOM_OPEN_BIGMODEL_CN_API_KEY in ~/.hermes/.env
//     A second GLM account is supported too (shown as "GLM2"): GLM_ALT_API_KEY
//     env var, or CUSTOM_OPEN_BIGMODEL_CN_ALT_API_KEY in ~/.hermes/.env
//
//   • OpenCode Go (opencode.ai) : GET https://opencode.ai/zen/go/v1/usage
//     Credential: OPENCODE_GO_API_KEY, OPENCODE_XIANYU_API_KEY or
//     OPENCODE_API_KEY env var / ~/.hermes/.env. Keys are probed in that order
//     and the first one the API accepts is used — a subscription that lapses
//     simply falls through to the next key instead of showing an error.
//
// Adding a new provider: add a case to `Source`, a branch in `detectSources()`
// and `refresh()`/`fetch…()`. Everything else (menu, persistence, rendering)
// is generic.
//
// Status item renders one line per enabled source — a colored dot (traffic
// light) + "Label:" + aligned "5h-remain%|week-remain%" in white. With 3+
// sources the lines split into two side-by-side columns so the type stays
// legible instead of shrinking to fit four stacked rows.

final class AppState: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared = AppState()
    static let version = "1.6.0"

    // MARK: - Provider registry

    enum Source: String, CaseIterable {
        case codex, glm, glmAlt, opencode

        var label: String {        // short label in the status bar
            switch self {
            case .codex:    return "Codex"
            case .glm:      return "GLM"
            case .glmAlt:   return "GLM2"
            case .opencode: return "OpenCode"
            }
        }
        var menuName: String {     // full name in the menu
            switch self {
            case .codex:    return "Codex (ChatGPT 订阅)"
            case .glm:      return "GLM Coding Plan (智谱)"
            case .glmAlt:   return "GLM Coding Plan (智谱·备用)"
            case .opencode: return "OpenCode Go (opencode.ai)"
            }
        }
        var missingHint: String {
            switch self {
            case .codex:    return "未配置 — 登录 Codex CLI 后点「重新扫描」"
            case .glm:      return "未配置 — 设置 GLM_API_KEY 后点「重新扫描」"
            case .glmAlt:   return "未配置 — 设置 GLM_ALT_API_KEY 后点「重新扫描」"
            case .opencode: return "未配置 — 设置 OPENCODE_API_KEY 后点「重新扫描」"
            }
        }
    }

    // MARK: - UI state

    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var refreshItem: NSMenuItem!
    var redetectItem: NSMenuItem!
    var updateItem: NSMenuItem!
    var lastUpdateItem: NSMenuItem!
    var toggleItems: [Source: NSMenuItem] = [:]
    var infoItems: [Source: NSMenuItem] = [:]
    var countdownItems: [Source: NSMenuItem] = [:]

    let fm = FileManager.default
    let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    let envPath = NSString(string: "~/.hermes/.env").expandingTildeInPath
    let repoURL = "https://github.com/sergioperezcheco/CodexQuota"
    var timer: Timer?
    var countdownTimer: Timer?
    var lastUpdate: Date?
    var refreshWorkItem: DispatchWorkItem?

    /// refresh interval in seconds (persisted; default 5 min)
    var refreshSeconds: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "refreshSeconds")
            return [60, 300, 600, 900, 1800].contains(v) ? v : 300
        }
        set { UserDefaults.standard.set(newValue, forKey: "refreshSeconds") }
    }

    func scheduleRefreshTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshSeconds), repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Discovery

    /// sources whose credentials were found locally (populated at launch)
    var detectedSources: Set<Source> = []

    func isDetected(_ s: Source) -> Bool { detectedSources.contains(s) }

    /// Probe local credential stores. File reads only — instant, no network.
    func detectSources() {
        // Codex: OAuth token present in ~/.codex/auth.json?
        if let raw = fm.contents(atPath: authPath),
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let tokens = obj["tokens"] as? [String: Any],
           (tokens["access_token"] as? String)?.isEmpty == false {
            detectedSources.insert(.codex)
        }
        if glmAPIKey() != nil { detectedSources.insert(.glm) }
        if glmAltAPIKey() != nil { detectedSources.insert(.glmAlt) }
        if openCodeKey() != nil { detectedSources.insert(.opencode) }
    }

    // MARK: - Persistence
    // "disabledSources" = sources the user explicitly hid. Everything else
    // that is detected shows automatically — so a newly configured service
    // appears in the bar without touching defaults.

    var disabled: Set<Source> {
        get {
            return Set((UserDefaults.standard.stringArray(forKey: "disabledSources") ?? [])
                        .compactMap { Source(rawValue: $0) })
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: "disabledSources") }
    }

    func isEnabled(_ s: Source) -> Bool { isDetected(s) && !disabled.contains(s) }
    var visible: Set<Source> { Set(Source.allCases.filter { isEnabled($0) }) }

    // MARK: - Data model

    struct CodexData {
        var plan: String
        var r5: Int; var reset5: Int      // remain %, seconds until reset
        var r7: Int; var reset7: Int
        var limitReached: Bool
    }
    struct GlmData {
        var level: String
        var r5: Int; var reset5Date: Date // remain %, absolute reset times
        var r7: Int; var reset7Date: Date
        var c5: Int; var cap5: Int
        var c7: Int; var cap7: Int
    }
    struct GoData {
        var r5: Int; var reset5Date: Date  // rolling window, remain %
        var r7: Int; var reset7Date: Date  // weekly window, remain %
        var r30: Int? = nil; var reset30Date: Date? = nil  // monthly (menu only)
    }

    var codex: CodexData?
    var glm: GlmData?
    var glmAlt: GlmData?
    var opencode: GoData?
    var errors: [Source: String] = [:]
    /// which of the several OpenCode keys answered last — kept so the menu can
    /// name it and so the next refresh probes that one first
    var openCodeKeyCache: (name: String, key: String)?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false

        detectSources()
        rebuildMenu()

        updateTitle()
        updateCountdown()
        refresh()
        scheduleRefreshTimer()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.updateCountdown() }
        ensureDefaultLoginItem()
    }

    /// Launch-at-login defaults to ON: register on first run unless the user
    /// has explicitly opted out from the menu.
    func ensureDefaultLoginItem() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginOptOut") else { return }   // user turned it off
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            removeLaunchAgentFallback()      // native mechanism works → drop legacy agent
        } catch {
            // register() throws on ad-hoc/broken signatures (err=4); fall back
            // to a LaunchAgent so launch-at-login still works.
            installLaunchAgentFallback()
        }
    }

    // MARK: - LaunchAgent fallback (signature-proof login mechanism)

    var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.checo.CodexQuota.plist")
    }

    var launchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func installLaunchAgentFallback() {
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else { return }
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.checo.CodexQuota</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        } catch {
            // already bootstrapped (EEXIST) is fine; make sure the label is enabled
            _ = try? run("/bin/launchctl", ["enable", "gui/\(getuid())/com.checo.CodexQuota"])
        }
    }

    func removeLaunchAgentFallback() {
        guard launchAgentInstalled else { return }
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/com.checo.CodexQuota"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    func menuWillOpen(_ menu: NSMenu) { updateCountdown() }

    /// Build the whole menu from current discovery + data state.
    func rebuildMenu() {
        menu.removeAllItems()
        toggleItems.removeAll()
        infoItems.removeAll()
        countdownItems.removeAll()

        func plain(_ t: String) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        }

        // ── toggle section: every known provider, with its detection status
        menu.addItem(plain("监控项（自动检测）:"))
        for s in Source.allCases {
            let detected = isDetected(s)
            let item = NSMenuItem(
                title: detected ? s.menuName : "\(s.menuName) — \(s.missingHint)",
                action: detected ? #selector(toggleSource(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = s.rawValue
            item.isEnabled = detected
            item.state = (detected && !disabled.contains(s)) ? .on : .off
            toggleItems[s] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // ── detail section
        for s in Source.allCases {
            menu.addItem(plain("\(s.menuName)"))
            let info = plain("…")
            let cd = plain("")
            infoItems[s] = info
            countdownItems[s] = cd
            menu.addItem(info)
            menu.addItem(cd)
            menu.addItem(.separator())
        }

        refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true
        menu.addItem(refreshItem)

        // ── settings: refresh interval / launch at login / self-update
        menu.addItem(plain("刷新间隔:"))
        let intervals: [(String, Int)] = [("1 分钟", 60), ("5 分钟", 300), ("10 分钟", 600), ("15 分钟", 900), ("30 分钟", 1800)]
        for (name, secs) in intervals {
            let item = NSMenuItem(title: name, action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            item.state = refreshSeconds == secs ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "开机自启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        let update = NSMenuItem(title: "立即更新", action: #selector(checkForUpdate), keyEquivalent: "u")
        update.target = self
        update.isEnabled = true
        updateItem = update
        menu.addItem(update)

        redetectItem = NSMenuItem(title: "重新检测可用服务", action: #selector(redetect), keyEquivalent: "")
        redetectItem.target = self
        redetectItem.isEnabled = true
        menu.addItem(redetectItem)

        lastUpdateItem = plain("")
        menu.addItem(lastUpdateItem)
        menu.addItem(.separator())
        menu.addItem(plain("CodexQuota v\(AppState.version)"))
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func refreshNow() { refresh() }

    @objc func redetect() {
        detectSources()
        rebuildMenu()
        updateTitle()
        updateCountdown()
        refresh()
    }

    // MARK: - Refresh interval

    @objc func setRefreshInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        refreshSeconds = secs
        scheduleRefreshTimer()
        rebuildMenu()  // update checkmarks
    }

    // MARK: - Launch at login (SMAppService, macOS 13+)

    var loginItemEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return launchAgentInstalled          // LaunchAgent fallback counts as on
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        let target = !loginItemEnabled
        var ok = false
        if target {
            do {
                try SMAppService.mainApp.register()
                removeLaunchAgentFallback()  // prefer the native mechanism
                ok = true
            } catch {
                installLaunchAgentFallback() // signature-proof fallback
                ok = loginItemEnabled
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgentFallback()
            ok = !loginItemEnabled
        }
        // remember the user's explicit choice so the default-on logic respects it
        UserDefaults.standard.set(!target, forKey: "loginOptOut")
        if target && !ok {
            let alert = NSAlert()
            alert.messageText = "注册开机自启动失败"
            alert.informativeText = "可在 系统设置 → 通用 → 登录项 中手动管理。"
            alert.runModal()
        }
        sender.state = loginItemEnabled ? .on : .off
    }

    // MARK: - Self-update
    // Compares Info.plist CFBundleShortVersionString with the repo's latest
    // release tag. To upgrade: downloads the repo tarball, rebuilds, swaps the
    // binary+plist in place, relaunches. Old app untouched on any failure.

    @objc func checkForUpdate() {
        updateItem?.title = "检查更新中…"
        updateItem?.isEnabled = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.performUpdateCheck()
            DispatchQueue.main.async {
                self.updateItem?.isEnabled = true
                let alert = NSAlert()
                switch result {
                case .upToDate:
                    self.updateItem?.title = "立即更新"
                    alert.messageText = "已是最新版本"
                    alert.informativeText = "当前 v\(AppState.version)，远端最新 v\(self.remoteVersion ?? AppState.version)。"
                case .updated(let v):
                    self.updateItem?.title = "立即更新"
                    alert.messageText = "已更新到 v\(v)，应用即将重启。"
                case .failed(let msg):
                    self.updateItem?.title = "重试更新"
                    alert.messageText = "更新失败"
                    alert.informativeText = msg
                }
                alert.runModal()
            }
        }
    }

    enum UpdateResult {
        case upToDate
        case updated(String)
        case failed(String)
    }

    var remoteVersion: String?
    var lastRemoteCheck: Date?

    func latestRemoteVersion() -> String? {
        // cached for 10 min within one session
        if let v = remoteVersion, let t = lastRemoteCheck, Date().timeIntervalSince(t) < 600 { return v }
        guard let url = URL(string: "\(repoURL)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        var finalURL: URL?
        let sem = DispatchSemaphore(value: 0)
        // "…/releases/latest" 302s to "…/releases/tag/vX.Y.Z" — read the final URL
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            finalURL = (resp as? HTTPURLResponse)?.url
            sem.signal()
        }.resume()
        sem.wait()
        guard let last = finalURL?.lastPathComponent, last.hasPrefix("v") else { return nil }
        remoteVersion = String(last.dropFirst())
        lastRemoteCheck = Date()
        return remoteVersion
    }

    func performUpdateCheck() -> UpdateResult {
        guard let remote = latestRemoteVersion() else {
            return .failed("无法获取远端版本（检查网络 / 仓库地址）。")
        }
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        if parts(remote).lexicographicallyPrecedes(parts(AppState.version)) ||
           parts(remote) == parts(AppState.version) {
            return .upToDate
        }
        // download + rebuild
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("CodexQuota-update-\(Int(Date().timeIntervalSince1970))")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let tar = work.appendingPathComponent("repo.tar.gz")
            try? Data(contentsOf: URL(string: "\(repoURL)/archive/refs/heads/main.tar.gz")!)
                .write(to: tar)
            let srcDir = work.appendingPathComponent("src")
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try run("/usr/bin/tar", ["-xzf", tar.path, "-C", srcDir.path, "--strip-components", "1"])
            let bin = work.appendingPathComponent("CodexQuota")
            try run("/usr/bin/swiftc", ["-O", "-o", bin.path,
                                        srcDir.appendingPathComponent("Sources/codex_quota.swift").path])
            // install
            let appPath = Bundle.main.bundlePath
            let contents = srcDir.appendingPathComponent("Info.plist")
            let dest = URL(fileURLWithPath: appPath)
            try? fm.removeItem(at: dest.appendingPathComponent("Contents/MacOS/CodexQuota"))
            try fm.copyItem(at: bin, to: dest.appendingPathComponent("Contents/MacOS/CodexQuota"))
            try? fm.removeItem(at: dest.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: contents, to: dest.appendingPathComponent("Contents/Info.plist"))
            // Re-sign the modified bundle. Swapping only the binary leaves a
            // linker-signed executable with unsealed resources; SMAppService
            // register() then fails and launch-at-login silently breaks.
            _ = try? run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", dest.path])
            // relaunch via open(1) after a short delay, then exit
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = "sleep 1; kill \(pid); open \(appPath)"
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/zsh")
            relaunch.arguments = ["-c", script]
            try relaunch.run()
            return .updated(remote)
        } catch {
            return .failed("\(error.localizedDescription)")
        }
    }

    @discardableResult
    func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "cq", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "命令失败"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @objc func toggleSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = Source(rawValue: raw), isDetected(s) else { return }
        var d = disabled
        if d.contains(s) {
            d.remove(s)
        } else {
            if visible.count <= 1 { return }  // keep at least one line in the bar
            d.insert(s)
        }
        disabled = d
        sender.state = d.contains(s) ? .off : .on
        updateTitle()
    }

    // MARK: - Status bar rendering
    // Two aligned columns: labels ("Codex:", "GLM:") share one column so the
    // numeric part starts at the same x on every line, whatever the values.

    func color(for remain: Int, limitReached: Bool) -> NSColor {
        if limitReached { return .systemRed }
        return remain > 40 ? .systemGreen : (remain > 10 ? .systemYellow : .systemRed)
    }

    func updateTitle() {
        var lines: [(label: String, value: String, color: NSColor)] = []
        for s in Source.allCases where visible.contains(s) {
            switch s {
            case .codex:
                if let q = codex {
                    lines.append((s.label + ":", String(format: "%d%%|%d%%", q.r5, q.r7),
                                  color(for: min(q.r5, q.r7), limitReached: q.limitReached)))
                } else {
                    lines.append((s.label + ":", "--", errors[s] == nil ? .systemGray : .systemRed))
                }
            case .glm, .glmAlt:
                let g = s == .glm ? glm : glmAlt
                if let g {
                    lines.append((s.label + ":", String(format: "%d%%|%d%%", g.r5, g.r7),
                                  color(for: min(g.r5, g.r7), limitReached: false)))
                } else {
                    lines.append((s.label + ":", "--", errors[s] == nil ? .systemGray : .systemRed))
                }
            case .opencode:
                if let o = opencode {
                    lines.append((s.label + ":", String(format: "%d%%|%d%%", o.r5, o.r7),
                                  color(for: min(o.r5, o.r7), limitReached: false)))
                } else {
                    lines.append((s.label + ":", "--", errors[s] == nil ? .systemGray : .systemRed))
                }
            }
        }
        statusItem.button?.image = titleImage(lines: lines)
        statusItem.button?.title = ""
        statusItem.button?.attributedTitle = NSAttributedString()
    }

    func titleImage(lines: [(label: String, value: String, color: NSColor)]) -> NSImage {
        // Up to 2 sources stack in one column. 3+ split into two side-by-side
        // columns (2 rows each) instead of squeezing 3–4 rows into the ~30pt
        // menu bar, which used to force 7pt type.
        let n = lines.count
        let colCount = n >= 3 ? 2 : 1
        let rows = max(1, Int(ceil(Double(n) / Double(colCount))))
        // the menu bar is ~30pt tall: 2 lines fit comfortably at 11pt leading,
        // 3 lines need compact metrics (8pt leading / ~7.8pt font); 4 lines only
        // fit with tighter leading (7.3pt / ~7.1pt font) or they get clipped
        let lineH: CGFloat = rows <= 2 ? 11 : (rows == 3 ? 8 : 7.3)
        let dotD: CGFloat = rows <= 2 ? 4.5 : (rows == 3 ? 3.4 : 3.0)
        let fontSize: CGFloat = rows <= 2 ? 9.5 : (rows == 3 ? 7.8 : 7.1)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 0
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.white]

        let labelX: CGFloat = dotD + 6.5
        let colGap: CGFloat = 10      // room for the divider between columns
        let pipeW = ceil(("|" as NSString).size(withAttributes: attrs).width)

        // first column takes `rows` lines, whatever is left overflows right
        var columns: [[(label: String, value: String, color: NSColor)]] = []
        var cursor = 0
        for _ in 0..<colCount {
            let take = min(rows, n - cursor)
            if take <= 0 { break }
            columns.append(Array(lines[cursor..<(cursor + take)]))
            cursor += take
        }

        // per column: labels share one x, and the part before the pipe is
        // right-aligned into its own sub-column so pipes and percentages line
        // up across rows whatever the digit counts
        struct Col {
            var labelW: CGFloat = 0
            var p1W: CGFloat = 0
            var p2W: CGFloat = 0
            var hasPipe = false
            var pipeX: CGFloat = 0
            var width: CGFloat = 0
        }
        var metrics: [Col] = []
        for col in columns {
            var m = Col()
            m.labelW = col.map { ceil(($0.label as NSString).size(withAttributes: attrs).width) }.max() ?? 0
            m.p1W = col.map { ceil(((($0.value.components(separatedBy: "|").first ?? "") as NSString)).size(withAttributes: attrs).width) }.max() ?? 0
            m.p2W = col.map { c -> CGFloat in
                let parts = c.value.components(separatedBy: "|")
                return parts.count > 1 ? ceil((parts[1] as NSString).size(withAttributes: attrs).width) : 0
            }.max() ?? 0
            m.hasPipe = col.contains { $0.value.contains("|") }
            let valueX = labelX + m.labelW + 3
            m.pipeX = valueX + m.p1W + 1
            m.width = m.hasPipe ? m.pipeX + pipeW + 1 + m.p2W : valueX + m.p1W
            metrics.append(m)
        }

        let totalW = metrics.reduce(0) { $0 + $1.width }
                   + colGap * CGFloat(max(0, columns.count - 1)) + 2
        let img = NSImage(size: NSSize(width: totalW, height: CGFloat(rows) * lineH))
        img.lockFocusFlipped(true)
        var x0: CGFloat = 0
        for (ci, col) in columns.enumerated() {
            let m = metrics[ci]
            for (i, l) in col.enumerated() {
                let cy = CGFloat(i) * lineH + lineH * 0.52  // dot centered on glyph ink
                l.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x0, y: cy - dotD / 2, width: dotD, height: dotD)).fill()
                let y = CGFloat(i) * lineH - 0.5
                (l.label as NSString).draw(in: NSRect(x: x0 + labelX, y: y, width: m.labelW + 4, height: lineH),
                                           withAttributes: attrs)
                let parts = l.value.components(separatedBy: "|")
                let p1 = (parts.first ?? "") as NSString
                p1.draw(in: NSRect(x: x0 + m.pipeX - ceil(p1.size(withAttributes: attrs).width) - 1, y: y,
                                   width: m.p1W + 2, height: lineH),
                        withAttributes: attrs)
                if parts.count > 1 {
                    ("|" as NSString).draw(in: NSRect(x: x0 + m.pipeX, y: y, width: pipeW + 1, height: lineH),
                                           withAttributes: attrs)
                    (parts[1] as NSString).draw(in: NSRect(x: x0 + m.pipeX + pipeW + 1, y: y,
                                                           width: m.p2W + 2, height: lineH),
                                                withAttributes: attrs)
                }
            }
            x0 += m.width
            if ci < columns.count - 1 {
                // hairline divider so the two column groups read as separate
                NSColor(white: 1.0, alpha: 0.22).setFill()
                NSRect(x: x0 + colGap / 2, y: lineH * 0.2, width: 1, height: CGFloat(rows) * lineH - lineH * 0.4).fill()
                x0 += colGap
            }
        }
        img.unlockFocus()
        img.isTemplate = false  // keep colors on the dark menu bar
        return img
    }

    // MARK: - Refresh

    func refresh() {
        refreshItem?.isEnabled = false
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let c = self.isDetected(.codex) ? self.fetchCodex() : nil
            let (g, g2) = self.fetchGlmPair()
            let o = self.isDetected(.opencode) ? self.fetchOpenCode() : nil
            DispatchQueue.main.async(execute: { [weak self] in
                guard let self else { return }
                self.refreshItem?.isEnabled = true
                if let q = c { self.codex = q }
                if let q = g { self.glm = q }
                if let q = g2 { self.glmAlt = q }
                if let q = o { self.opencode = q }
                if c != nil || g != nil || g2 != nil || o != nil { self.lastUpdate = Date() }
                self.updateTitle()
                self.updateCountdown()
            })
        }
        refreshWorkItem = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    // MARK: - Menu detail text

    func hms(_ t: Int) -> String { String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
    func dhm(_ t: Int) -> String { String(format: "%dd %dh", t / 86400, (t % 86400) / 3600) }

    func updateCountdown() {
        let el = lastUpdate.map { Date().timeIntervalSince($0) } ?? 0
        for s in Source.allCases {
            guard let info = infoItems[s], let cd = countdownItems[s] else { continue }
            if !isDetected(s) {
                info.title = s.missingHint
                cd.title = ""
                continue
            }
            switch s {
            case .codex:
                if let q = codex {
                    info.title = "5h余 \(q.r5)%　7d余 \(q.r7)%" + (q.plan.isEmpty ? "" : "　(\(q.plan))") + (q.limitReached ? "　⚠️已限流" : "")
                    cd.title = String(format: "5h重置 %@　7d重置 %@", hms(max(0, q.reset5 - Int(el))), dhm(max(0, q.reset7 - Int(el))))
                } else {
                    info.title = errors[s] ?? "加载中…"; cd.title = ""
                }
            case .glm, .glmAlt:
                let g = s == .glm ? glm : glmAlt
                if let g {
                    // point counts only exist on CREDIT_LIMIT plans; TOKENS_LIMIT
                    // plans show bare percentages
                    let p5 = g.cap5 > 0 ? " (\(g.c5)/\(g.cap5))" : ""
                    let p7 = g.cap7 > 0 ? " (\(g.c7)/\(g.cap7))" : ""
                    info.title = "5h余 \(g.r5)%\(p5)　7d余 \(g.r7)%\(p7)　(\(g.level))"
                    cd.title = String(format: "5h重置 %@　7d重置 %@",
                                      hms(max(0, Int(g.reset5Date.timeIntervalSinceNow))),
                                      dhm(max(0, Int(g.reset7Date.timeIntervalSinceNow))))
                } else {
                    info.title = errors[s] ?? "加载中…"; cd.title = ""
                }
            case .opencode:
                if let o = opencode {
                    // name the key that answered: several subscriptions can sit
                    // in ~/.hermes/.env and only one of them is live
                    let which = openCodeKeyCache.map { "　(\($0.name))" } ?? ""
                    info.title = "5h余 \(o.r5)%　7d余 \(o.r7)%"
                               + (o.r30.map { "　30d余 \($0)%" } ?? "") + which
                    var t = String(format: "5h重置 %@　7d重置 %@",
                                   hms(max(0, Int(o.reset5Date.timeIntervalSinceNow))),
                                   dhm(max(0, Int(o.reset7Date.timeIntervalSinceNow))))
                    if let d30 = o.reset30Date {
                        t += "　30d重置 " + dhm(max(0, Int(d30.timeIntervalSinceNow)))
                    }
                    cd.title = t
                } else {
                    info.title = errors[s] ?? "加载中…"; cd.title = ""
                }
            }
        }
        lastUpdateItem?.title = "更新于 " + (lastUpdate.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "-")
    }

    // MARK: - HTTP helper

    func httpGetJSON(url: String, headers: [String: String]) -> Result<[String: Any], Error> {
        guard let u = URL(string: url) else {
            return .failure(NSError(domain: "cq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad URL"]))
        }
        var req = URLRequest(url: u, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var payload: [String: Any]?
        var httpError: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { httpError = err.localizedDescription; return }
            guard let http = resp as? HTTPURLResponse else { httpError = "无响应"; return }
            guard (200..<300).contains(http.statusCode), let data else { httpError = "HTTP \(http.statusCode)"; return }
            payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }.resume()
        sem.wait()
        if let httpError { return .failure(NSError(domain: "cq", code: 2, userInfo: [NSLocalizedDescriptionKey: httpError])) }
        guard let p = payload else { return .failure(NSError(domain: "cq", code: 3, userInfo: [NSLocalizedDescriptionKey: "解析失败"])) }
        return .success(p)
    }

    // MARK: - Codex fetcher

    func fetchCodex() -> CodexData? {
        guard let raw = fm.contents(atPath: authPath),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else {
            errors[.codex] = "读不到 auth.json token"
            return nil
        }
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex_cli_rs"]
        if let acct = tokens["account_id"] as? String { headers["chatgpt-account-id"] = acct }
        switch httpGetJSON(url: "https://chatgpt.com/backend-api/wham/usage", headers: headers) {
        case .success(let p):
            let rl = p["rate_limit"] as? [String: Any] ?? [:]
            let pw = rl["primary_window"] as? [String: Any] ?? [:]
            let sw = rl["secondary_window"] as? [String: Any] ?? [:]
            errors[.codex] = nil
            return CodexData(
                plan: (p["plan_type"] as? String) ?? "",
                r5: max(0, 100 - ((pw["used_percent"] as? Int) ?? 0)),
                reset5: (pw["reset_after_seconds"] as? Int) ?? 0,
                r7: max(0, 100 - ((sw["used_percent"] as? Int) ?? 0)),
                reset7: (sw["reset_after_seconds"] as? Int) ?? 0,
                limitReached: (rl["limit_reached"] as? Bool) ?? false
            )
        case .failure(let e):
            errors[.codex] = e.localizedDescription
            return nil
        }
    }

    // MARK: - GLM fetcher

    /// Read an env var from the process environment first, then from
    /// ~/.hermes/.env. Returns the raw value (already trimmed).
    func envKey(_ name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        guard let raw = fm.contents(atPath: envPath), let s = String(data: raw, encoding: .utf8) else { return nil }
        for ln in s.split(separator: "\n") {
            if ln.hasPrefix("\(name)=") {
                let v = ln.dropFirst(name.count + 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    func glmAPIKey() -> String? {
        // 1) explicit env var wins
        // 2) fall back to ~/.hermes/.env (Hermes users already have the key there)
        envKey("GLM_API_KEY") ?? envKey("CUSTOM_OPEN_BIGMODEL_CN_API_KEY")
    }

    func glmAltAPIKey() -> String? {
        envKey("GLM_ALT_API_KEY") ?? envKey("CUSTOM_OPEN_BIGMODEL_CN_ALT_API_KEY")
    }

    /// Both GLM accounts share one endpoint + response format; they differ only
    /// in the key. Serial would waste a refresh cycle on two round-trips.
    func fetchGlmPair() -> (GlmData?, GlmData?) {
        let group = DispatchGroup()
        let q = DispatchQueue(label: "glm-pair", attributes: .concurrent)
        var main: GlmData?
        var alt: GlmData?
        if isDetected(.glm) {
            group.enter()
            q.async { main = self.fetchGlm(key: self.glmAPIKey(), errKey: .glm); group.leave() }
        }
        if isDetected(.glmAlt) {
            group.enter()
            q.async { alt = self.fetchGlm(key: self.glmAltAPIKey(), errKey: .glmAlt); group.leave() }
        }
        group.wait()
        return (main, alt)
    }

    func fetchGlm(key: String?, errKey: Source) -> GlmData? {
        guard let key else {
            errors[errKey] = "未找到 GLM key"
            return nil
        }
        switch httpGetJSON(url: "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
                           headers: ["Authorization": "Bearer \(key)"]) {
        case .success(let p):
            guard let d = p["data"] as? [String: Any],
                  let limits = d["limits"] as? [[String: Any]] else {
                errors[errKey] = "响应格式不符"
                return nil
            }
            func asInt(_ v: Any?) -> Int? {
                if let i = v as? Int { return i }
                if let d = v as? Double { return Int(d) }
                return nil
            }
            // Preferred: CREDIT_LIMIT entries (usage/remaining point counts).
            // 5h window = unit 3 + number 5, weekly = unit 6 + number 1.
            var w5: [String: Any]?
            var w7: [String: Any]?
            for l in limits where (l["type"] as? String) == "CREDIT_LIMIT" {
                let n = asInt(l["number"]) ?? -1
                let u = asInt(l["unit"]) ?? -1
                if n == 5 || u == 3 { w5 = l }
                if n == 1 || u == 6 { w7 = l }
            }
            // Some plans (e.g. second account) expose no CREDIT_LIMIT at all —
            // they report TOKENS_LIMIT windows with a bare `percentage` instead.
            if w5 == nil || w7 == nil {
                for l in limits where (l["type"] as? String) == "TOKENS_LIMIT" {
                    let u = asInt(l["unit"]) ?? -1
                    if w5 == nil && u == 3 { w5 = l }
                    if w7 == nil && u == 6 { w7 = l }
                }
            }
            guard let a = w5, let b = w7 else {
                errors[errKey] = "缺 5h/7d 额度窗口"
                return nil
            }
            // CREDIT_LIMIT carries usage/remaining; TOKENS_LIMIT only a used-%
            func pct(_ l: [String: Any]) -> Int {
                if let rem = asInt(l["remaining"]), let cap = asInt(l["usage"]), cap > 0 {
                    return Int((Double(rem) / Double(cap) * 100).rounded())
                }
                if let p = asInt(l["percentage"]) { return max(0, 100 - p) }
                return 0
            }
            func resetDate(_ l: [String: Any]) -> Date {
                let ms: Double
                if let d = l["nextResetTime"] as? Double { ms = d }
                else if let i = l["nextResetTime"] as? Int { ms = Double(i) }
                else { ms = 0 }
                return Date(timeIntervalSince1970: ms / 1000)
            }
            errors[errKey] = nil
            return GlmData(
                level: (d["level"] as? String) ?? "?",
                r5: pct(a), reset5Date: resetDate(a),
                r7: pct(b), reset7Date: resetDate(b),
                c5: asInt(a["remaining"]) ?? 0, cap5: asInt(a["usage"]) ?? 0,
                c7: asInt(b["remaining"]) ?? 0, cap7: asInt(b["usage"]) ?? 0
            )
        case .failure(let e):
            errors[errKey] = e.localizedDescription
            return nil
        }
    }

    // MARK: - OpenCode Go (opencode.ai) fetcher
    // One subscription = one key, and keys stop working the moment the plan
    // lapses. Several can coexist in ~/.hermes/.env, so probe them in a fixed
    // order and use the first one the API accepts. The winning key is cached
    // and tried first next time, so a stale key costs one request per refresh
    // at most.

    static let openCodeKeyNames = ["OPENCODE_GO_API_KEY", "OPENCODE_XIANYU_API_KEY", "OPENCODE_API_KEY"]

    /// candidate keys in probe order (name kept for the menu)
    func openCodeKeys() -> [(name: String, key: String)] {
        AppState.openCodeKeyNames.compactMap { name in
            envKey(name).map { (name, $0) }
        }
    }

    func openCodeKey() -> String? { openCodeKeys().first?.key }

    func fetchOpenCode() -> GoData? {
        let candidates = openCodeKeys()
        guard !candidates.isEmpty else {
            errors[.opencode] = "未找到 OpenCode key"
            return nil
        }
        // last known-good key first
        var ordered = candidates
        if let good = openCodeKeyCache, let i = ordered.firstIndex(where: { $0.name == good.name }) {
            ordered.remove(at: i)
            ordered.insert(good, at: 0)
        }
        var lastError = "未知错误"
        for cand in ordered {
            switch fetchOpenCodeOnce(key: cand.key) {
            case .success(let d):
                openCodeKeyCache = cand
                errors[.opencode] = nil
                return d
            case .failure(let e):
                lastError = "\(cand.name): \(e.localizedDescription)"
            }
        }
        errors[.opencode] = lastError
        return nil
    }

    func fetchOpenCodeOnce(key: String) -> Result<GoData, Error> {
        // opencode.ai sits behind Cloudflare — a browser UA is required
        // (plain URL clients get 403 error 1010).
        let headers: [String: String] = [
            "Authorization": "Bearer \(key)",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        ]
        switch httpGetJSON(url: "https://opencode.ai/zen/go/v1/usage", headers: headers) {
        case .success(let p):
            guard let u = p["usage"] as? [String: Any],
                  let rolling = u["rolling"] as? [String: Any],
                  let weekly = u["weekly"] as? [String: Any] else {
                return .failure(NSError(domain: "cq", code: 4,
                                        userInfo: [NSLocalizedDescriptionKey: "响应格式不符"]))
            }
            func window(_ w: [String: Any]) -> (Int, Date) {
                let used = (w["percent"] as? Int) ?? Int((w["percent"] as? Double) ?? 0)
                let iso = (w["resetsAt"] as? String) ?? ""
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = fmt.date(from: iso) ?? Date(timeIntervalSinceNow: 0)
                return (max(0, 100 - used), date)
            }
            let (r5, d5) = window(rolling)
            let (r7, d7) = window(weekly)
            var data = GoData(r5: r5, reset5Date: d5, r7: r7, reset7Date: d7)
            // monthly is not a plan limit on every tier, but when it is present
            // the menu shows it
            if let monthly = u["monthly"] as? [String: Any] {
                let (r30, d30) = window(monthly)
                data.r30 = r30
                data.reset30Date = d30
            }
            return .success(data)
        case .failure(let e):
            return .failure(e)
        }
    }
}

let app = NSApplication.shared
let delegate = AppState.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
