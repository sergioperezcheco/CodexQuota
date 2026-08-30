import Cocoa

// CodexQuota — macOS menu bar quota monitor for AI coding subscriptions.
//   • Codex  (ChatGPT OAuth)   : GET https://chatgpt.com/backend-api/wham/usage
//     Auth: Bearer access_token from ~/.codex/auth.json (+ chatgpt-account-id)
//   • GLM Coding Plan (Zhipu)  : GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
//     Auth: Bearer <API key> read from CUSTOM_OPEN_BIGMODEL_CN_API_KEY in ~/.hermes/.env
//
// Status item shows one line per enabled source: a colored dot (traffic-light)
// + "<Label>:<5h remain%>|<weekly remain%>" in white. Toggle sources from the menu;
// the choice persists in UserDefaults.

final class AppState: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared = AppState()
    static let version = "1.1.0"

    enum Source: String, CaseIterable {
        case codex, glm
        var label: String { self == .codex ? "Codex" : "GLM" }
    }

    // MARK: - UI state

    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var toggleItems: [Source: NSMenuItem] = [:]
    var headerItems: [Source: NSMenuItem] = [:]
    var infoItems: [Source: NSMenuItem] = [:]
    var countdownItems: [Source: NSMenuItem] = [:]
    var refreshItem: NSMenuItem!
    var lastUpdateItem: NSMenuItem!

    let fm = FileManager.default
    let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    let envPath = NSString(string: "~/.hermes/.env").expandingTildeInPath
    var timer: Timer?
    var countdownTimer: Timer?
    var lastUpdate: Date?
    var refreshWorkItem: DispatchWorkItem?

    // MARK: - Data model

    struct WindowRemain {
        var r5: Int          // remaining % in the 5-hour window
        var reset5: Int      // seconds until 5h reset (Codex, relative)
        var r7: Int
        var reset7: Int
    }
    struct CodexData {
        var plan: String
        var win: WindowRemain
        var limitReached: Bool
    }
    struct GlmData {
        var level: String
        var win: WindowRemain
        var reset5Date: Date   // GLM gives absolute reset timestamps (ms epoch)
        var reset7Date: Date
        var c5: Int; var cap5: Int
        var c7: Int; var cap7: Int
    }

    var codex: CodexData?
    var glm: GlmData?
    var errors: [Source: String] = [:]

    var visible: Set<Source> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: "visibleSources") ?? ["codex", "glm"]
            return Set(raw.compactMap { Source(rawValue: $0) })
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: "visibleSources") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self

        func header(_ t: String) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
        }

        // Toggle section
        let toggleTitle = header("状态栏显示:")
        menu.addItem(toggleTitle)
        for s in Source.allCases {
            let item = NSMenuItem(title: s.label, action: #selector(toggleSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = visible.contains(s) ? .on : .off
            toggleItems[s] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Detail section
        for s in Source.allCases {
            headerItems[s] = header("\(s.label) 额度")
            infoItems[s] = header("加载中…")
            countdownItems[s] = header("")
            menu.addItem(headerItems[s]!)
            menu.addItem(infoItems[s]!)
            menu.addItem(countdownItems[s]!)
            menu.addItem(.separator())
        }

        refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        lastUpdateItem = header("")
        menu.addItem(lastUpdateItem)
        menu.addItem(.separator())
        let about = header("CodexQuota v\(AppState.version)")
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        updateTitle()
        updateCountdown()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.updateCountdown() }
    }

    func menuWillOpen(_ menu: NSMenu) { updateCountdown() }
    @objc func refreshNow() { refresh() }

    @objc func toggleSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = Source(rawValue: raw) else { return }
        var v = visible
        if sender.state == .on { v.remove(s) } else { v.insert(s) }
        if v.isEmpty { return }  // keep at least one line
        visible = v
        sender.state = v.contains(s) ? .on : .off
        updateTitle()
    }

    // MARK: - Status item rendering

    func color(for remain: Int, limitReached: Bool) -> NSColor {
        if limitReached { return .systemRed }
        return remain > 40 ? .systemGreen : (remain > 10 ? .systemYellow : .systemRed)
    }

    func updateTitle() {
        var lines: [(String, NSColor)] = []
        for s in Source.allCases where visible.contains(s) {
            switch s {
            case .codex:
                if let q = codex {
                    lines.append(("Codex:\(q.win.r5)%|\(q.win.r7)%", color(for: min(q.win.r5, q.win.r7), limitReached: q.limitReached)))
                } else {
                    lines.append(("Codex:--", errors[s] == nil ? .systemGray : .systemRed))
                }
            case .glm:
                if let g = glm {
                    lines.append(("GLM:\(g.win.r5)%|\(g.win.r7)%", color(for: min(g.win.r5, g.win.r7), limitReached: false)))
                } else {
                    lines.append(("GLM:--", errors[s] == nil ? .systemGray : .systemRed))
                }
            }
        }
        statusItem.button?.image = titleImage(lines: lines)
        statusItem.button?.title = ""
        statusItem.button?.attributedTitle = NSAttributedString()
    }

    /// Render one line per source: colored status dot + white monospace text.
    func titleImage(lines: [(String, NSColor)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 0
        para.alignment = .left
        let lineH: CGFloat = 11
        let dotD: CGFloat = 4.5
        let textX: CGFloat = dotD + 6.5  // wide dot-to-text gap; dot sits further left
        var w: CGFloat = 0
        for (t, _) in lines {
            let sz = (t as NSString).size(withAttributes: [.font: font, .paragraphStyle: para])
            w = max(w, ceil(sz.width))
        }
        let h = CGFloat(lines.count) * lineH
        let img = NSImage(size: NSSize(width: textX + w + 2, height: h))
        img.lockFocusFlipped(true)
        for (i, l) in lines.enumerated() {
            let cy = CGFloat(i) * lineH + 5.75  // dot centered on glyph ink
            l.1.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: cy - dotD / 2, width: dotD, height: dotD)).fill()
            let rect = NSRect(x: textX, y: CGFloat(i) * lineH - 0.5, width: w + 2, height: lineH)
            (l.0 as NSString).draw(in: rect, withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: para
            ])
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
            let c = self.fetchCodex()
            let g = self.fetchGlm()
            let apply: () -> Void = {
                self.refreshItem?.isEnabled = true
                if let q = c { self.codex = q }
                if let q = g { self.glm = q }
                if c != nil || g != nil { self.lastUpdate = Date() }
                self.updateTitle()
                self.updateCountdown()
            }
            DispatchQueue.main.async(execute: apply)
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
            guard let h = headerItems[s], let info = infoItems[s], let cd = countdownItems[s] else { continue }
            switch s {
            case .codex:
                h.title = "Codex 额度" + (codex.map { $0.plan.isEmpty ? "" : " (\($0.plan))" } ?? "")
                if let q = codex {
                    info.title = "5h余 \(q.win.r5)%　7d余 \(q.win.r7)%" + (q.limitReached ? "　⚠️已限流" : "")
                    cd.title = String(format: "5h重置 %@　7d重置 %@", hms(max(0, q.win.reset5 - Int(el))), dhm(max(0, q.win.reset7 - Int(el))))
                } else {
                    info.title = errors[.codex] ?? "加载中…"; cd.title = ""
                }
            case .glm:
                h.title = "GLM Coding" + (glm.map { " (\($0.level))" } ?? "")
                if let g = glm {
                    info.title = "5h余 \(g.win.r5)% (\(g.c5)/\(g.cap5))　7d余 \(g.win.r7)% (\(g.c7)/\(g.cap7))"
                    cd.title = String(format: "5h重置 %@　7d重置 %@",
                                      hms(max(0, Int(g.reset5Date.timeIntervalSinceNow))),
                                      dhm(max(0, Int(g.reset7Date.timeIntervalSinceNow))))
                } else {
                    info.title = errors[.glm] ?? "加载中…"; cd.title = ""
                }
            }
        }
        lastUpdateItem.title = "更新于 " + (lastUpdate.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "-")
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

    // MARK: - Codex (ChatGPT OAuth)

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
                win: WindowRemain(
                    r5: max(0, 100 - ((pw["used_percent"] as? Int) ?? 0)),
                    reset5: (pw["reset_after_seconds"] as? Int) ?? 0,
                    r7: max(0, 100 - ((sw["used_percent"] as? Int) ?? 0)),
                    reset7: (sw["reset_after_seconds"] as? Int) ?? 0
                ),
                limitReached: (rl["limit_reached"] as? Bool) ?? false
            )
        case .failure(let e):
            errors[.codex] = e.localizedDescription
            return nil
        }
    }

    // MARK: - GLM Coding Plan (Zhipu)

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
            var w5: [String: Any]?
            var w7: [String: Any]?
            for l in limits where (l["type"] as? String) == "CREDIT_LIMIT" {
                let n = (l["number"] as? Int) ?? Int((l["number"] as? Double) ?? -1)
                let u = (l["unit"] as? Int) ?? Int((l["unit"] as? Double) ?? -1)
                if n == 5 || u == 3 { w5 = l }   // unit 3 = hour
                if n == 1 || u == 6 { w7 = l }   // unit 6 = week
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
                let ms = (l["nextResetTime"] as? Double) ?? ((l["nextResetTime"] as? Int)?.toDoubleFuzz() ?? 0)
                return Date(timeIntervalSince1970: ms / 1000)
            }
            errors[.glm] = nil
            return GlmData(
                level: (d["level"] as? String) ?? "?",
                win: WindowRemain(r5: pct(a), reset5: 0, r7: pct(b), reset7: 0),
                reset5Date: resetDate(a), reset7Date: resetDate(b),
                c5: (a["remaining"] as? Int) ?? 0, cap5: (a["usage"] as? Int) ?? 0,
                c7: (b["remaining"] as? Int) ?? 0, cap7: (b["usage"] as? Int) ?? 0
            )
        case .failure(let e):
            errors[.glm] = e.localizedDescription
            return nil
        }
    }
}

private extension Int {
    func toDoubleFuzz() -> Double { Double(self) }
}

let app = NSApplication.shared
let delegate = AppState.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
