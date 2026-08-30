import Cocoa

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
//
// Adding a new provider: add a case to `Source`, a branch in `detectSources()`
// and `refresh()`/`fetch…()`. Everything else (menu, persistence, rendering)
// is generic.
//
// Status item renders one line per enabled source — a colored dot (traffic
// light) + "Label:" + aligned "5h-remain%|week-remain%" in white.

final class AppState: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared = AppState()
    static let version = "1.2.0"

    // MARK: - Provider registry

    enum Source: String, CaseIterable {
        case codex, glm

        var label: String {        // short label in the status bar
            switch self {
            case .codex: return "Codex"
            case .glm:   return "GLM"
            }
        }
        var menuName: String {     // full name in the menu
            switch self {
            case .codex: return "Codex (ChatGPT 订阅)"
            case .glm:   return "GLM Coding Plan (智谱)"
            }
        }
        var missingHint: String {
            switch self {
            case .codex: return "未检测到 — 请先在本机登录 Codex CLI"
            case .glm:   return "未检测到 — 未找到 API Key"
            }
        }
    }

    // MARK: - UI state

    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var refreshItem: NSMenuItem!
    var lastUpdateItem: NSMenuItem!
    var toggleItems: [Source: NSMenuItem] = [:]
    var infoItems: [Source: NSMenuItem] = [:]
    var countdownItems: [Source: NSMenuItem] = [:]

    let fm = FileManager.default
    let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    let envPath = NSString(string: "~/.hermes/.env").expandingTildeInPath
    var timer: Timer?
    var countdownTimer: Timer?
    var lastUpdate: Date?
    var refreshWorkItem: DispatchWorkItem?

    // MARK: - Discovery

    /// source → "已检测到(<detail>)" or "未检测到 — …" (populated at launch)
    var discovery: [Source: String] = [:]

    func isDetected(_ s: Source) -> Bool { discovery[s]?.hasPrefix("已检测到") == true }

    /// Probe local credential stores. File reads only — instant, no network.
    func detectSources() {
        // Codex: OAuth token present in ~/.codex/auth.json?
        var codexOK = false
        if let raw = fm.contents(atPath: authPath),
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let tokens = obj["tokens"] as? [String: Any],
           (tokens["access_token"] as? String)?.isEmpty == false {
            codexOK = true
        }
        discovery[.codex] = codexOK ? "已检测到 (OAuth)" : Source.codex.missingHint

        // GLM: API key in env or ~/.hermes/.env?
        discovery[.glm] = (glmAPIKey() != nil) ? "已检测到 (API Key)" : Source.glm.missingHint
    }

    // MARK: - Persistence

    var visible: Set<Source> {
        get {
            if let raw = UserDefaults.standard.stringArray(forKey: "visibleSources") {
                return Set(raw.compactMap { Source(rawValue: $0) })
            }
            // first launch: show everything detected
            return Set(Source.allCases.filter { isDetected($0) })
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: "visibleSources") }
    }

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

    var codex: CodexData?
    var glm: GlmData?
    var errors: [Source: String] = [:]

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
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.updateCountdown() }
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
                title: "\(s.menuName) — \(discovery[s] ?? "…")",
                action: detected ? #selector(toggleSource(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = s.rawValue
            item.isEnabled = detected
            item.state = (detected && visible.contains(s)) ? .on : .off
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

        let redetect = NSMenuItem(title: "重新检测可用服务", action: #selector(redetect), keyEquivalent: "")
        redetect.target = self
        redetect.isEnabled = true
        menu.addItem(redetect)

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

    @objc func toggleSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = Source(rawValue: raw), isDetected(s) else { return }
        var v = visible
        if sender.state == .on { v.remove(s) } else { v.insert(s) }
        if v.isEmpty { return }  // keep at least one line in the bar
        visible = v
        sender.state = v.contains(s) ? .on : .off
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
            case .glm:
                if let g = glm {
                    lines.append((s.label + ":", String(format: "%d%%|%d%%", g.r5, g.r7),
                                  color(for: min(g.r5, g.r7), limitReached: false)))
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 0
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]

        let lineH: CGFloat = 11
        let dotD: CGFloat = 4.5
        let labelX: CGFloat = dotD + 6.5
        // label column width = widest label → values align across lines
        let labelW = lines.map { ceil(($0.label as NSString).size(withAttributes: attrs).width) }.max() ?? 0
        let valueX = labelX + labelW + 3
        let valueW = lines.map { ceil(($0.value as NSString).size(withAttributes: attrs).width) }.max() ?? 0

        let img = NSImage(size: NSSize(width: valueX + valueW + 2, height: CGFloat(lines.count) * lineH))
        img.lockFocusFlipped(true)
        for (i, l) in lines.enumerated() {
            let cy = CGFloat(i) * lineH + 5.75  // dot centered on glyph ink
            l.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: cy - dotD / 2, width: dotD, height: dotD)).fill()
            let y = CGFloat(i) * lineH - 0.5
            (l.label as NSString).draw(in: NSRect(x: labelX, y: y, width: labelW + 4, height: lineH),
                                       withAttributes: attrs)
            (l.value as NSString).draw(in: NSRect(x: valueX, y: y, width: valueW + 2, height: lineH),
                                       withAttributes: attrs)
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
            let g = self.isDetected(.glm) ? self.fetchGlm() : nil
            DispatchQueue.main.async(execute: { [weak self] in
                guard let self else { return }
                self.refreshItem?.isEnabled = true
                if let q = c { self.codex = q }
                if let q = g { self.glm = q }
                if c != nil || g != nil { self.lastUpdate = Date() }
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
                info.title = discovery[s] ?? ""
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
            case .glm:
                if let g = glm {
                    info.title = "5h余 \(g.r5)% (\(g.c5)/\(g.cap5))　7d余 \(g.r7)% (\(g.c7)/\(g.cap7))　(\(g.level))"
                    cd.title = String(format: "5h重置 %@　7d重置 %@",
                                      hms(max(0, Int(g.reset5Date.timeIntervalSinceNow))),
                                      dhm(max(0, Int(g.reset7Date.timeIntervalSinceNow))))
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

    func glmAPIKey() -> String? {
        // 1) explicit env var wins
        if let v = ProcessInfo.processInfo.environment["GLM_API_KEY"], !v.isEmpty { return v }
        // 2) fall back to ~/.hermes/.env (Hermes users already have the key there)
        guard let raw = fm.contents(atPath: envPath), let s = String(data: raw, encoding: .utf8) else { return nil }
        for ln in s.split(separator: "\n") {
            if ln.hasPrefix("CUSTOM_OPEN_BIGMODEL_CN_API_KEY=") {
                let v = ln.dropFirst("CUSTOM_OPEN_BIGMODEL_CN_API_KEY=".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    func fetchGlm() -> GlmData? {
        guard let key = glmAPIKey() else {
            errors[.glm] = "未找到 GLM key"
            return nil
        }
        switch httpGetJSON(url: "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
                           headers: ["Authorization": "Bearer \(key)"]) {
        case .success(let p):
            guard let d = p["data"] as? [String: Any],
                  let limits = d["limits"] as? [[String: Any]] else {
                errors[.glm] = "响应格式不符"
                return nil
            }
            // CREDIT_LIMIT entries: 5h window = unit 3 + number 5, weekly = unit 6 + number 1
            var w5: [String: Any]?
            var w7: [String: Any]?
            for l in limits where (l["type"] as? String) == "CREDIT_LIMIT" {
                let n = (l["number"] as? Int) ?? Int((l["number"] as? Double) ?? -1)
                let u = (l["unit"] as? Int) ?? Int((l["unit"] as? Double) ?? -1)
                if n == 5 || u == 3 { w5 = l }
                if n == 1 || u == 6 { w7 = l }
            }
            guard let a = w5, let b = w7 else {
                errors[.glm] = "缺 CREDIT_LIMIT 窗口"
                return nil
            }
            func pct(_ l: [String: Any]) -> Int {
                let cap = (l["usage"] as? Int) ?? 0
                let rem = (l["remaining"] as? Int) ?? 0
                return cap > 0 ? Int((Double(rem) / Double(cap) * 100).rounded()) : 0
            }
            func resetDate(_ l: [String: Any]) -> Date {
                let ms: Double
                if let d = l["nextResetTime"] as? Double { ms = d }
                else if let i = l["nextResetTime"] as? Int { ms = Double(i) }
                else { ms = 0 }
                return Date(timeIntervalSince1970: ms / 1000)
            }
            errors[.glm] = nil
            return GlmData(
                level: (d["level"] as? String) ?? "?",
                r5: pct(a), reset5Date: resetDate(a),
                r7: pct(b), reset7Date: resetDate(b),
                c5: (a["remaining"] as? Int) ?? 0, cap5: (a["usage"] as? Int) ?? 0,
                c7: (b["remaining"] as? Int) ?? 0, cap7: (b["usage"] as? Int) ?? 0
            )
        case .failure(let e):
            errors[.glm] = e.localizedDescription
            return nil
        }
    }
}

let app = NSApplication.shared
let delegate = AppState.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
