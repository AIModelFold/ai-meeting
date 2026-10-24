// AI Meeting · 字幕窗口：置顶悬浮、半透明，实时滚动显示原文（有译文时跟在下面）
// 界面语言：环境变量 AIM_LANG=en|zh（默认英文），运行中收到 {"type":"lang","lang":"zh"} 实时切换
//
// stdin 每行一个 JSON：
//   {"type":"line","id":1,"t":"09:40:12","text":"原文","who":"them|me"}   who 只在双路（录麦克风）时有：对方 / 我
//   {"type":"tr","id":1,"text":"译文"}
//   {"type":"qa","t":"09:40:15","q":"提炼出的问题","a":"建议回答"}
//   {"type":"status","text":"状态提示"}
//   {"type":"notice","level":"error|warn|ok","text":"账户/网络提示"}  → 顶部横幅（ok 几秒后自动收起）
//   {"type":"lang","lang":"en|zh"}                                  → 切换界面语言
//
// 编译：swiftc -O subtitle.swift -o subtitle
// 窗口可拖动、可拉伸，盖在所有窗口（含全屏会议软件）上面；关窗口不影响后台记录。

import AppKit

var uiLang = ProcessInfo.processInfo.environment["AIM_LANG"] == "zh" ? "zh" : "en"
let STR: [String: [String: String]] = [
    "en": ["title": "AI Meeting · Live transcript / Q&A", "waiting": "Waiting for sound…", "count": "{n} lines · last {t}", "them": "Them", "me": "Me"],
    "zh": ["title": "AI Meeting · 实时原文 / 问题回答", "waiting": "等待声音…", "count": "共 {n} 句 · 最近 {t}", "them": "对方", "me": "我"],
]
func L(_ k: String, _ p: [String: Any] = [:]) -> String {
    var s = STR[uiLang]?[k] ?? STR["en"]?[k] ?? k
    for (key, v) in p { s = s.replacingOccurrences(of: "{\(key)}", with: "\(v)") }
    return s
}

final class Line {
    let id: Int
    let t: String
    let text: String
    var tr: String?
    var answer: String?       // 有值 = 这是一条「问题 + 建议回答」
    var who: String?          // them / me（双路时）
    init(id: Int, t: String, text: String, answer: String? = nil, who: String? = nil) { self.id = id; self.t = t; self.text = text; self.answer = answer; self.who = who }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var textView: NSTextView!
    var scroll: NSScrollView!
    var statusLabel: NSTextField!
    var banner: NSTextField!
    var bannerHide: DispatchWorkItem?
    var lines: [Line] = []
    let maxLines = 300
    var statusIsCount = false   // 状态行当前显示的是句数（切换语言时按新语言重渲染）
    var statusIsWaiting = true
    var lastT = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = min(900, screen.width - 80), h: CGFloat = 220
        let rect = NSRect(x: screen.midX - w / 2, y: screen.minY + 40, width: w, height: h)

        panel = NSPanel(contentRect: rect,
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.title = L("title")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.93)
        panel.isOpaque = false
        panel.minSize = NSSize(width: 360, height: 120)
        panel.setFrameAutosaveName("MeetingAssistantSubtitle")

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.autoresizingMask = [.width, .height]

        statusLabel = NSTextField(labelWithString: L("waiting"))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.45)
        statusLabel.frame = NSRect(x: 14, y: 6, width: rect.width - 28, height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(statusLabel)

        scroll = NSScrollView(frame: NSRect(x: 0, y: 24, width: rect.width, height: rect.height - 24 - 28))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        content.addSubview(scroll)

        // 顶部横幅：积分不足 / Key 无效 / 网络问题，平时隐藏
        banner = NSTextField(wrappingLabelWithString: "")
        banner.font = .systemFont(ofSize: 13, weight: .semibold)
        banner.textColor = .white
        banner.drawsBackground = true
        banner.isBezeled = false
        banner.alignment = .center
        banner.autoresizingMask = [.width, .minYMargin]
        banner.isHidden = true
        content.addSubview(banner)

        panel.contentView = content
        if let out = snapshotPath { snapshot(to: out); return }
        panel.orderFrontRegardless()

        readStdin()
    }

    func readStdin() {
        DispatchQueue.global().async {
            while let raw = readLine() {
                guard let d = raw.data(using: .utf8),
                      let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                DispatchQueue.main.async { self.handle(m) }
            }
            // 上游结束（引擎退出）→ 窗口也退出
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "line":
            guard let id = m["id"] as? Int, let text = m["text"] as? String else { return }
            lines.append(Line(id: id, t: m["t"] as? String ?? "", text: text, who: m["who"] as? String))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            lastT = m["t"] as? String ?? ""
            showCount()
        case "tr":
            guard let id = m["id"] as? Int, let text = m["text"] as? String, !text.isEmpty,
                  let l = lines.last(where: { $0.id == id && $0.answer == nil }) else { return }
            l.tr = text
        case "qa":
            guard let q = m["q"] as? String, let a = m["a"] as? String else { return }
            lines.append(Line(id: -1, t: m["t"] as? String ?? "", text: q, answer: a))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        case "status":
            statusLabel.stringValue = m["text"] as? String ?? ""
            statusIsCount = false; statusIsWaiting = false
            return
        case "lang":
            uiLang = (m["lang"] as? String) == "zh" ? "zh" : "en"
            panel.title = L("title")
            if statusIsCount { showCount() } else if statusIsWaiting { statusLabel.stringValue = L("waiting") }
            // 说话人标签跟着换语言，往下走 render()
        case "notice":
            showBanner(level: m["level"] as? String ?? "warn", text: m["text"] as? String ?? "")
            return
        default:
            return
        }
        render()
    }

    func showCount() {
        statusLabel.stringValue = L("count", ["n": lines.filter { $0.answer == nil }.count, "t": lastT])
        statusIsCount = true; statusIsWaiting = false
    }

    func showBanner(level: String, text: String) {
        bannerHide?.cancel()
        let colors: [String: NSColor] = [
            "error": NSColor(calibratedRed: 0.78, green: 0.2, blue: 0.22, alpha: 0.95),
            "warn": NSColor(calibratedRed: 0.8, green: 0.55, blue: 0.1, alpha: 0.95),
            "ok": NSColor(calibratedRed: 0.15, green: 0.6, blue: 0.35, alpha: 0.95),
        ]
        banner.backgroundColor = colors[level] ?? colors["warn"]!
        banner.stringValue = (level == "ok" ? "✓ " : "⚠ ") + text
        let w = panel.contentView!.bounds.width, h = panel.contentView!.bounds.height
        banner.preferredMaxLayoutWidth = w - 24
        let bh = max(26, banner.intrinsicContentSize.height + 8)
        banner.frame = NSRect(x: 0, y: h - 28 - bh, width: w, height: bh)
        banner.isHidden = false
        scroll.frame = NSRect(x: 0, y: 24, width: w, height: h - 24 - 28 - bh)
        if level == "ok" {
            let job = DispatchWorkItem { [weak self] in self?.hideBanner() }
            bannerHide = job
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: job)
        }
    }

    func hideBanner() {
        banner.isHidden = true
        let b = panel.contentView!.bounds
        scroll.frame = NSRect(x: 0, y: 24, width: b.width, height: b.height - 24 - 28)
    }

    func render() {
        // 用户往上翻看历史时不强行拉回底部
        let clip = scroll.contentView
        let atBottom = clip.bounds.maxY >= textView.frame.height - 30

        let out = NSMutableAttributedString()
        let timeAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                       .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.4)]
        let textAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .medium),
                                                       .foregroundColor: NSColor.white]
        let oldAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .regular),
                                                      .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.72)]
        let trAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .regular),
                                                     .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.85, blue: 1, alpha: 1)]
        let qAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                                    .foregroundColor: NSColor(calibratedRed: 1, green: 0.78, blue: 0.3, alpha: 1)]
        let aAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .regular),
                                                    .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.6, alpha: 1)]
        let themAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                       .foregroundColor: NSColor(calibratedRed: 1, green: 0.62, blue: 0.45, alpha: 1)]
        let meAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                     .foregroundColor: NSColor(calibratedRed: 0.6, green: 0.75, blue: 1, alpha: 1)]
        let lastText = lines.lastIndex(where: { $0.answer == nil }) ?? -1
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            if let a = l.answer {
                out.append(NSAttributedString(string: "❓ " + l.text, attributes: qAttr))
                out.append(NSAttributedString(string: "\n💡 " + a, attributes: aAttr))
                continue
            }
            let latest = i == lastText
            out.append(NSAttributedString(string: l.t + "  ", attributes: timeAttr))
            if let who = l.who { out.append(NSAttributedString(string: L(who == "me" ? "me" : "them") + "  ", attributes: who == "me" ? meAttr : themAttr)) }
            out.append(NSAttributedString(string: l.text, attributes: latest ? textAttr : oldAttr))
            if let tr = l.tr { out.append(NSAttributedString(string: "\n        " + tr, attributes: trAttr)) }
        }
        textView.textStorage?.setAttributedString(out)
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }
}

extension AppDelegate {
    /// 无窗口自检（--snapshot <png>）：窗口不上屏，灌一段示例对话后把内容渲染成 PNG
    func snapshot(to out: String) {
        let demo: [[String: Any]] = [
            ["type": "line", "id": 1, "t": "10:00:01", "text": "Could you introduce your product's background and tech stack?", "who": "them"],
            ["type": "line", "id": 2, "t": "10:00:09", "text": "Sure. It's a meeting assistant built with Swift and Whisper running locally.", "who": "me"],
            ["type": "tr", "id": 2, "text": "当然。这是一个用 Swift 和本地 Whisper 做的会议助手。"],
            ["type": "line", "id": 3, "t": "10:00:20", "text": "What hard problems did you hit along the way?", "who": "them"],
            ["type": "qa", "t": "10:00:22", "q": "What hard problems did you hit along the way?", "a": "The hardest part was keeping local recognition real-time on the Mac GPU while separating my voice from the call audio."],
            ["type": "notice", "level": "warn", "text": "Only 10 ModelFold credits left, please top up soon"],
        ]
        let v = panel.contentView!
        // 窗口底色不在内容视图里：截图时在最底层垫一块同色的底
        let bg = NSBox(frame: v.bounds)
        bg.boxType = .custom; bg.borderWidth = 0; bg.fillColor = (panel.backgroundColor ?? .black).withAlphaComponent(1)
        v.addSubview(bg, positioned: .below, relativeTo: nil)
        for m in demo { handle(m) }
        v.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.scrollToEndOfDocument(nil)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print(out)
        exit(0)
    }
}

let snapshotPath: String? = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count { return a[i + 1] }
    return nil
}()
let app = NSApplication.shared
app.setActivationPolicy(snapshotPath == nil ? .accessory : .prohibited)   // 不占 Dock、不抢焦点；截图模式完全不显示
let delegate = AppDelegate()
app.delegate = delegate
app.run()
