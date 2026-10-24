// AI Meeting.app（原「会议助手」）的启动面板：填 ModelFold Key、选模型和语言 → 开始 / 停止。
// 真正干活的是包里 Resources/engine/ 下的 run.mjs（采集 → 识别 → 翻译 → 字幕窗口 → 问答），本程序只负责启动、停止和显示日志。
// 界面中英双语，默认英文，右上角切换，选择记在 config.json 的 ui_lang；引擎通过环境变量 AIM_LANG 拿到语言，运行中切换走 stdin 实时通知。
//
// 构建：app/build.sh（编译本文件 + 引擎二进制，拷进 AI Meeting.app，签名）；Intel 版：ARCH=x86_64 app/build.sh（下面 #if arch(x86_64) 的部分）
// 无窗口自检：「AI Meeting」--selftest（文案 / 目录迁移）；--snapshot <目录>（不上屏，把主窗口中英文各渲染一张 PNG）

import AppKit
import AVFoundation
import CryptoKit
import UserNotifications

// ---------- 界面语言 ----------
enum UILang: String, CaseIterable { case en, zh }
var uiLang: UILang = .en

let STR: [UILang: [String: String]] = [
    .en: [
        "app.name": "AI Meeting",
        "tagline": "Captures the sound your Mac plays → live captions → spots questions and suggests answers",
        "key.label": "ModelFold Key",
        "key.placeholder": "Create a key at ai.modelfold.online → API Keys, then paste it here",
        "key.get": "Get key",
        "model.label": "Answer model",
        "lang.label": "Speech language",
        "asr.label": "Speech model",
        "model.deepseek-v4-1-flash": "DeepSeek V4.1 Flash (recommended: fast, cheap)",
        "model.gpt-6-luna": "GPT-6 Luna (reliable)",
        "model.gpt-6-sol": "GPT-6 Sol (stronger)",
        "model.gemini-3-8-flash": "Gemini 3.8 Flash",
        "model.claude-sonnet-5-5": "Claude Sonnet 5.5",
        "lang.auto": "Auto (Chinese / English mixed)",
        "lang.zh": "Chinese",
        "lang.en": "English",
        "asr.small": "Standard · small (more accurate for Chinese, recommended)",
        "asr.base": "Fast · base (quicker, less accurate)",
        "asr.large": "large-v3-turbo",
        "size.large": "about 1.6 GB",
        "size.small": "about 190 MB",
        "size.base": "about 60 MB",
        "translate": "Live translation",
        "translate.hint": "First download Chinese and English in System Settings → General → Language & Region → Translation Languages",
        "translate.hintIntel": "Needs macOS 26 or later. First download Chinese and English in System Settings → General → Language & Region → Translation Languages",
        "mic": "Also capture my microphone",
        "mic.hint": "Computer sound is labeled “Them”, your microphone “Me”. AI answers build on what you have already said. Headphones work best (on speakers, echoes of Them are filtered out).",
        "alert.micOff": "Microphone access is off",
        "alert.micOffDetail": "This time AI Meeting captures only computer sound. To include your own voice (“Me”), allow AI Meeting in System Settings → Privacy & Security → Microphone, then start again.",
        "alert.continue": "Continue without microphone",
        "log.micOff": "Microphone access is off, capturing computer sound only",
        "start": "Start",
        "stop": "Stop",
        "records.open": "Open notes folder",
        "status.idle": "Not running",
        "status.running": "● Running",
        "status.saving": "Saving notes…",
        "status.waitModel": "Waiting for the speech model download",
        "hello": "Fill in your key and click Start. The first Start asks for “Screen & System Audio Recording” permission (needed to record system sound): allow it, then click Start again.",
        "helloDl": "On first use the speech model ({size}) downloads automatically in the background; Start becomes available when it is done. You can fill in your key meanwhile.",
        "dl.connecting": "Preparing to download the speech model ({size}, first use only)…",
        "dl.progress": "Downloading speech model (first use only): {pct}% · {done} / {total} MB · {speed} · {eta}",
        "dl.speed": "{v} MB/s",
        "dl.etaMin": "about {n} min left",
        "dl.etaSec": "about {n} s left",
        "dl.etaUnknown": "estimating time left…",
        "dl.retrying": "Download interrupted ({msg}). Retrying in {n} s; downloaded part is kept ({done} / {total} MB)",
        "dl.verifying": "Checking the downloaded file…",
        "dl.ready": "✓ Speech model ready. You can start now.",
        "dl.failed": "Download failed: {msg}. Check the network and click Retry; the downloaded part is kept.",
        "dl.retry": "Retry",
        "dl.badFile": "downloaded file is damaged, downloading again",
        "notify.title": "Speech model ready",
        "notify.body": "AI Meeting is ready. You can start now.",
        "log.dlStart": "Downloading the speech model ({size}, first use only) from {host}",
        "log.dlResume": "Resuming the speech model download at {done} / {total} MB ({host})",
        "alert.ok": "OK",
        "alert.later": "Later",
        "alert.needKey": "Please enter your ModelFold key",
        "alert.needKeyDetail": "Question answering uses ModelFold chat models.",
        "alert.noNode": "Node.js not found",
        "alert.noNodeDetail": "Install it in Terminal: brew install node",
        "alert.noWhisper": "Speech engine not found",
        "alert.noWhisperDetail": "Install it in Terminal: brew install whisper-cpp",
        "alert.credits": "Out of ModelFold credits",
        "alert.creditsDetail": "Question answering is paused; live captions and notes are not affected.\nNo restart needed after topping up: it resumes the next time someone asks a question.",
        "alert.topUp": "Top up",
        "alert.invalidKey": "ModelFold key is invalid or revoked",
        "alert.invalidKeyDetail": "Question answering is paused. Create a new key in the ModelFold console, then stop, paste it here and start again.",
        "alert.manageKeys": "Manage keys",
        "alert.perm": "“Screen & System Audio Recording” permission needed",
        "alert.permDetail": "AI Meeting records the sound your Mac plays to make captions.\nIn the Settings window that opens, turn on “AI Meeting”, then quit and reopen AI Meeting and click Start again.",
        "alert.openSettings": "Open System Settings",
        "log.loading": "Starting… (loading the speech model takes about 5–10 s)",
        "log.startFail": "Could not start: {msg}",
        "log.ended": "— Stopped (exit code {code}) —",
        "log.dlDone": "Speech model downloaded and verified ✅",
        "log.dlFailed": "Speech model download failed: {msg}",
        "log.migratedSupport": "Carried over settings and speech model from the previous version (会议助手)",
        "log.migratedRecords": "Moved {n} earlier notes to {path}",
        "menu.quit": "Quit AI Meeting",
        "menu.edit": "Edit",
        "menu.cut": "Cut",
        "menu.copy": "Copy",
        "menu.paste": "Paste",
        "menu.selectAll": "Select All",
    ],
    .zh: [
        "app.name": "AI Meeting",
        "tagline": "抓取电脑播放的声音 → 实时字幕 → 自动提炼问题并给出回答",
        "key.label": "ModelFold Key",
        "key.placeholder": "在 ai.modelfold.online →「API Key」页创建后粘贴到这里",
        "key.get": "获取 Key",
        "model.label": "回答模型",
        "lang.label": "识别语言",
        "asr.label": "识别模型",
        "model.deepseek-v4-1-flash": "DeepSeek V4.1 Flash（推荐：快、便宜）",
        "model.gpt-6-luna": "GPT-6 Luna（稳妥）",
        "model.gpt-6-sol": "GPT-6 Sol（更强）",
        "model.gemini-3-8-flash": "Gemini 3.8 Flash",
        "model.claude-sonnet-5-5": "Claude Sonnet 5.5",
        "lang.auto": "自动（中英混说）",
        "lang.zh": "中文",
        "lang.en": "English",
        "asr.small": "标准 small（中文更准，推荐）",
        "asr.base": "快速 base（出字快，准确率低一些）",
        "asr.large": "large-v3-turbo",
        "size.large": "约 1.6GB",
        "size.small": "约 190MB",
        "size.base": "约 60MB",
        "translate": "实时翻译",
        "translate.hint": "需先在 系统设置 → 通用 → 语言与地区 → 翻译语言 下载「中文」和「English」",
        "translate.hintIntel": "需要 macOS 26 或更新；并先在 系统设置 → 通用 → 语言与地区 → 翻译语言 下载「中文」和「English」",
        "mic": "同时录我的麦克风",
        "mic.hint": "电脑里的声音标为「对方」，麦克风标为「我」，AI 回答会接着你前面说过的内容。戴耳机效果最好（外放时会过滤对方的回声）。",
        "alert.micOff": "没有麦克风权限",
        "alert.micOffDetail": "这次只录电脑里的声音。要把自己的声音（「我」）也录进来，请在 系统设置 → 隐私与安全性 → 麦克风 里允许「AI Meeting」，然后重新开始。",
        "alert.continue": "不录麦克风，继续",
        "log.micOff": "没有麦克风权限，只录电脑声音",
        "start": "开始",
        "stop": "停止",
        "records.open": "打开记录文件夹",
        "status.idle": "未运行",
        "status.running": "● 运行中",
        "status.saving": "正在保存记录…",
        "status.waitModel": "等识别模型下载完成",
        "hello": "填好 Key 后点「开始」。第一次开始时 macOS 会请求「屏幕与系统录音」权限（录系统声音需要），允许后重新点「开始」。",
        "helloDl": "第一次使用会在后台自动下载语音识别模型（{size}），下完后「开始」按钮才可用，这期间可以先填 Key。",
        "dl.connecting": "准备下载语音识别模型（{size}，仅第一次）…",
        "dl.progress": "正在下载识别模型（仅第一次）：{pct}% · {done} / {total} MB · {speed} · {eta}",
        "dl.speed": "{v} MB/s",
        "dl.etaMin": "约剩 {n} 分钟",
        "dl.etaSec": "约剩 {n} 秒",
        "dl.etaUnknown": "正在估算剩余时间…",
        "dl.retrying": "下载中断（{msg}），{n} 秒后自动重试，已下载的部分会保留（{done} / {total} MB）",
        "dl.verifying": "正在校验下载的文件…",
        "dl.ready": "✓ 识别模型已就绪，可以开始了。",
        "dl.failed": "下载失败：{msg}。请检查网络后点「重试」，已下载的部分会保留。",
        "dl.retry": "重试",
        "dl.badFile": "下载的文件校验不通过，重新下载",
        "notify.title": "识别模型已就绪",
        "notify.body": "AI Meeting 可以开始使用了。",
        "log.dlStart": "开始下载语音识别模型（{size}，仅第一次）：{host}",
        "log.dlResume": "接着上次的进度继续下载识别模型：{done} / {total} MB（{host}）",
        "alert.ok": "好",
        "alert.later": "稍后",
        "alert.needKey": "请先填写 ModelFold Key",
        "alert.needKeyDetail": "问题回答要用 ModelFold 的对话模型。",
        "alert.noNode": "找不到 Node.js",
        "alert.noNodeDetail": "请先在终端安装：brew install node",
        "alert.noWhisper": "找不到语音识别引擎",
        "alert.noWhisperDetail": "请先在终端安装：brew install whisper-cpp",
        "alert.credits": "ModelFold 积分不足",
        "alert.creditsDetail": "问题回答已暂停，实时字幕和会议记录不受影响。\n充值后无需重启，下一次有人提问时会自动恢复。",
        "alert.topUp": "去充值",
        "alert.invalidKey": "ModelFold Key 无效或已注销",
        "alert.invalidKeyDetail": "问题回答已暂停。请到 ModelFold 控制台新建一个 Key，停止后在这里换上再开始。",
        "alert.manageKeys": "去管理 Key",
        "alert.perm": "需要「屏幕与系统录音」权限",
        "alert.permDetail": "AI Meeting 要录制电脑播放的声音来生成字幕。\n请在打开的设置里把「AI Meeting」的开关打开，然后退出并重新打开 AI Meeting，再点「开始」。",
        "alert.openSettings": "打开系统设置",
        "log.loading": "启动中…（加载识别模型约 5~10 秒）",
        "log.startFail": "启动失败：{msg}",
        "log.ended": "— 已结束（退出码 {code}）—",
        "log.dlDone": "识别模型下载完成并校验通过 ✅",
        "log.dlFailed": "识别模型下载失败：{msg}",
        "log.migratedSupport": "已沿用旧版「会议助手」的设置和识别模型",
        "log.migratedRecords": "已把之前的 {n} 份会议记录移到 {path}",
        "menu.quit": "退出 AI Meeting",
        "menu.edit": "编辑",
        "menu.cut": "剪切",
        "menu.copy": "复制",
        "menu.paste": "粘贴",
        "menu.selectAll": "全选",
    ],
]

func L(_ key: String, _ p: [String: Any] = [:]) -> String {
    var s = STR[uiLang]?[key] ?? STR[.en]?[key] ?? key
    for (k, v) in p { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
    return s
}

// ---------- 目录：1.1 起改名 AI Meeting，旧「会议助手」目录自动沿用 ----------
let fm = FileManager.default
let supportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let appSupport = supportRoot.appendingPathComponent("AI Meeting", isDirectory: true)
let legacySupport = supportRoot.appendingPathComponent("会议助手", isDirectory: true)
let configURL = appSupport.appendingPathComponent("config.json")
let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
let recordsDir = documentsDir.appendingPathComponent("AI Meeting Notes", isDirectory: true)
let legacyRecordsDir = documentsDir.appendingPathComponent("会议助手记录", isDirectory: true)
let engineDir = Bundle.main.resourceURL!.appendingPathComponent("engine", isDirectory: true)
let bundledModelsDir = Bundle.main.resourceURL!.appendingPathComponent("models", isDirectory: true)   // build.sh BUNDLE_MODEL=1 时才有

/// 旧版 Application Support/会议助手 → AI Meeting：config.json 复制（新目录已有就不动），识别模型硬链接（不多占空间，旧版也照样能用）
@discardableResult
func migrateSupport(from old: URL, to new: URL) -> [String] {
    var done: [String] = []
    guard fm.fileExists(atPath: old.path) else { return done }
    try? fm.createDirectory(at: new, withIntermediateDirectories: true)
    let oldCfg = old.appendingPathComponent("config.json"), newCfg = new.appendingPathComponent("config.json")
    if fm.fileExists(atPath: oldCfg.path), !fm.fileExists(atPath: newCfg.path), (try? fm.copyItem(at: oldCfg, to: newCfg)) != nil {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: newCfg.path)
        done.append("config.json")
    }
    let oldModels = old.appendingPathComponent("models", isDirectory: true), newModels = new.appendingPathComponent("models", isDirectory: true)
    for f in (try? fm.contentsOfDirectory(atPath: oldModels.path)) ?? [] where !f.hasPrefix(".") {
        let src = oldModels.appendingPathComponent(f), dst = newModels.appendingPathComponent(f)
        guard !fm.fileExists(atPath: dst.path) else { continue }
        try? fm.createDirectory(at: newModels, withIntermediateDirectories: true)
        if (try? fm.linkItem(at: src, to: dst)) != nil || (try? fm.copyItem(at: src, to: dst)) != nil { done.append("models/" + f) }
    }
    return done
}

/// 旧记录文件夹 ~/Documents/会议助手记录 → ~/Documents/AI Meeting Notes：新文件夹不存在就整个改名，存在就把没有重名的文件移过去；返回移动的文件数
@discardableResult
func migrateRecords(from old: URL, to new: URL) -> Int {
    guard let files = try? fm.contentsOfDirectory(atPath: old.path) else { return 0 }
    let real = files.filter { !$0.hasPrefix(".") }
    if !fm.fileExists(atPath: new.path) {
        if (try? fm.moveItem(at: old, to: new)) != nil { return real.count }
    }
    try? fm.createDirectory(at: new, withIntermediateDirectories: true)
    var n = 0
    for f in real {
        let dst = new.appendingPathComponent(f)
        if !fm.fileExists(atPath: dst.path), (try? fm.moveItem(at: old.appendingPathComponent(f), to: dst)) != nil { n += 1 }
    }
    let left = ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter { $0 != ".DS_Store" }
    if left.isEmpty { try? fm.removeItem(at: old) }
    return n
}

// ---------- 识别模型 ----------
// Apple 芯片：large-v3-turbo（1.6GB，GPU 跑得动）。Intel：没有 Apple 芯片的 GPU，纯 CPU 跑 large 一句要十几秒，改用小模型：
//   默认 small（量化版 190MB，中文明显比 base 准）；低配机（MacBook Air 等）可在面板里切到 base（60MB，快约 3 倍）。
// 模型默认不进安装包（安装包保持小）：App 一打开发现没有模型就在后台下载到 Application Support/AI Meeting/models，
//   断点续传（.part 文件 + HTTP Range，退出 / 断网后接着下），huggingface 不通换 hf-mirror，下完按 SHA256 校验（与 huggingface 公布的一致）。
// build.sh BUNDLE_MODEL=1 打的「含模型版」放在包里 Resources/models/，有就直接用、不下载。
struct AsrModel { let id: String; let file: String; let bytes: Int64; let sha256: String; let sizeKey: String; var minBytes: Int64 { bytes } }
#if arch(x86_64)
let asrModels = [
    AsrModel(id: "small", file: "ggml-small-q5_1.bin", bytes: 190_085_487, sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", sizeKey: "size.small"),
    AsrModel(id: "base", file: "ggml-base-q5_1.bin", bytes: 59_707_625, sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", sizeKey: "size.base"),
]
#else
let asrModels = [AsrModel(id: "large", file: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", sizeKey: "size.large")]
#endif
var asrModel = asrModels[0]

func fileSize(_ u: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
var downloadedModelURL: URL { appSupport.appendingPathComponent("models/" + asrModel.file) }
var bundledModelURL: URL { bundledModelsDir.appendingPathComponent(asrModel.file) }
var modelURL: URL { fileSize(bundledModelURL) >= asrModel.minBytes ? bundledModelURL : downloadedModelURL }
func modelSources(_ m: AsrModel) -> [URL] {
    ["huggingface.co", "hf-mirror.com"].map { URL(string: "https://\($0)/ggerganov/whisper.cpp/resolve/main/\(m.file)")! }
}
func modelReady() -> Bool { fileSize(modelURL) >= asrModel.minBytes }

func sha256Hex(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while true {
        let more: Bool = autoreleasepool {
            guard let d = try? h.read(upToCount: 8 << 20), !d.isEmpty else { return false }
            hasher.update(data: d)
            return true
        }
        if !more { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// 断点续传下载：数据边收边写进 <目标>.part，每次（重新）连接都带 Range: bytes=<已有大小>-；
/// 断网 / 超时 / 服务器出错自动重试（有进展就原源立即重试，没进展就换源并退避），换源也保留进度；
/// 服务器不认 Range（回 200）就从头来；收完校验大小 + SHA256，通过才改名成目标文件。
final class ModelDownloader: NSObject, URLSessionDataDelegate {
    struct Progress { let done: Int64; let total: Int64; let speed: Double; let eta: Double? }
    enum State { case connecting(resumeFrom: Int64, host: String), running, retrying(after: Double, reason: String), verifying, done, failed(String) }

    let sources: [URL], dest: URL, expectedSize: Int64, sha256: String?
    var part: URL { dest.appendingPathExtension("part") }
    var onProgress: ((Progress) -> Void)?
    var onState: ((State) -> Void)?
    var retryBase = Double(ProcessInfo.processInfo.environment["AIM_DL_RETRY_BASE"] ?? "") ?? 2
    var maxFailures = Int(ProcessInfo.processInfo.environment["AIM_DL_MAX_FAILURES"] ?? "") ?? 10   // 连续这么多次毫无进展才算失败
    var timeout = Double(ProcessInfo.processInfo.environment["AIM_DL_TIMEOUT"] ?? "") ?? 30
    private(set) var done: Int64 = 0
    private(set) var running = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var src = 0
    private var failures = 0
    private var gotBytes = false
    private var badStatus: String?
    private var notSatisfiable = false
    private var samples: [(t: Date, bytes: Int64)] = []
    private var lastEmit = Date.distantPast

    init(sources: [URL], dest: URL, expectedSize: Int64, sha256: String?) {
        self.sources = sources; self.dest = dest; self.expectedSize = expectedSize; self.sha256 = sha256
    }

    func start() {
        guard !running else { return }
        running = true
        failures = 0
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        attempt()
    }

    /// 停下（.part 保留，下次 start 接着下）
    func cancel() {
        running = false
        task?.cancel(); task = nil
        closeHandle()
        session?.invalidateAndCancel(); session = nil
    }

    private func closeHandle() { try? handle?.close(); handle = nil }

    private func attempt() {
        guard running, let session else { return }
        done = fileSize(part)
        if done > expectedSize { try? fm.removeItem(at: part); done = 0 }
        if done == expectedSize { verify(); return }   // 上次收完了还没来得及校验
        var req = URLRequest(url: sources[src])
        if done > 0 { req.setValue("bytes=\(done)-", forHTTPHeaderField: "Range") }
        badStatus = nil; gotBytes = false; notSatisfiable = false
        samples = [(Date(), done)]
        onState?(.connecting(resumeFrom: done, host: sources[src].host ?? ""))
        task = session.dataTask(with: req)
        task?.resume()
    }

    // 跳转（huggingface → CDN）时把 Range 带上
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") { r.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { badStatus = "no HTTP response"; completionHandler(.cancel); return }
        var total: Int64 = -1
        switch http.statusCode {
        case 206:
            // Content-Range: bytes <起>-<止>/<总>
            let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let nums = cr.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
            guard nums.count == 3, nums[0] == done else { badStatus = "bad Content-Range \(cr)"; try? fm.removeItem(at: part); completionHandler(.cancel); return }
            total = nums[2]
        case 200:
            if done > 0 { try? fm.removeItem(at: part); done = 0 }   // 不支持续传：从头来
            total = http.expectedContentLength
        case 416:
            notSatisfiable = true; completionHandler(.cancel); return
        default:
            badStatus = "HTTP \(http.statusCode)"; completionHandler(.cancel); return
        }
        if total > 0, total != expectedSize { badStatus = "unexpected size \(total)"; completionHandler(.cancel); return }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: part) else { badStatus = "cannot write \(part.path)"; completionHandler(.cancel); return }
        _ = try? h.seekToEnd()
        handle = h
        onState?(.running)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do { try handle.write(contentsOf: data) } catch { badStatus = error.localizedDescription; dataTask.cancel(); return }
        done += Int64(data.count)
        gotBytes = true
        let now = Date()
        if now.timeIntervalSince(lastEmit) >= 0.25 || done == expectedSize {
            lastEmit = now
            samples.append((now, done))
            while let f = samples.first, now.timeIntervalSince(f.t) > 6, samples.count > 2 { samples.removeFirst() }
            var speed = 0.0
            if let f = samples.first, now.timeIntervalSince(f.t) > 0.5 { speed = Double(done - f.bytes) / now.timeIntervalSince(f.t) }
            onProgress?(Progress(done: done, total: expectedSize, speed: speed, eta: speed > 1000 ? Double(expectedSize - done) / speed : nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closeHandle()
        self.task = nil
        guard running else { return }
        done = fileSize(part)
        if notSatisfiable {   // .part 已经是整个文件（或更大）：交给校验；不对就删了重来
            if done == expectedSize { verify() } else { try? fm.removeItem(at: part); retry(reason: "HTTP 416") }
            return
        }
        if error == nil, badStatus == nil, done == expectedSize { verify(); return }
        retry(reason: badStatus ?? error?.localizedDescription ?? "connection closed")
    }

    private func retry(reason: String) {
        if gotBytes { failures = 0 } else { failures += 1; src = (src + 1) % sources.count }   // 没进展就换源（进度保留）
        if failures >= maxFailures { running = false; session?.invalidateAndCancel(); session = nil; onState?(.failed(reason)); return }
        let delay = gotBytes ? min(retryBase, 1) : min(30, retryBase * pow(2, Double(max(0, failures - 1))))
        onState?(.retrying(after: delay, reason: reason))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.attempt() }
    }

    private func verify() {
        onState?(.verifying)
        let part = self.part, dest = self.dest, want = sha256, size = expectedSize
        DispatchQueue.global(qos: .utility).async {
            let ok = fileSize(part) == size && (want == nil || sha256Hex(part) == want)
            DispatchQueue.main.async {
                guard self.running else { return }
                if ok {
                    try? fm.removeItem(at: dest)
                    do { try fm.moveItem(at: part, to: dest) } catch { self.running = false; self.onState?(.failed(error.localizedDescription)); return }
                    self.running = false
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                    self.onState?(.done)
                } else {
                    try? fm.removeItem(at: part)   // 坏文件：删掉从头下
                    self.gotBytes = false
                    self.retry(reason: "checksum mismatch")
                }
            }
        }
    }
}

let models = ["deepseek-v4-1-flash", "gpt-6-luna", "gpt-6-sol", "gemini-3-8-flash", "claude-sonnet-5-5"]
let langs = ["auto", "zh", "en"]

struct Config: Codable {
    var api_key = ""
    var model = "deepseek-v4-1-flash"
    var lang = "auto"
    var translate = true
    var asr: String? = nil       // Intel 版识别模型 id（small / base）
    var ui_lang: String? = nil   // 界面语言 en / zh，缺省英文
    var mic: Bool? = nil         // 同时录麦克风（缺省开）

    init() {}
    init(api_key: String, model: String, lang: String, translate: Bool, asr: String?, ui_lang: String?, mic: Bool?) {
        self.api_key = api_key; self.model = model; self.lang = lang; self.translate = translate; self.asr = asr; self.ui_lang = ui_lang; self.mic = mic
    }
    // 每个字段都可缺省：旧版 / 手改过的配置文件照样能读，不会因为少一个字段把 Key 丢掉
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        api_key = try c.decodeIfPresent(String.self, forKey: .api_key) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-v4-1-flash"
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? "auto"
        translate = try c.decodeIfPresent(Bool.self, forKey: .translate) ?? true
        asr = try c.decodeIfPresent(String.self, forKey: .asr)
        ui_lang = try c.decodeIfPresent(String.self, forKey: .ui_lang)
        mic = try c.decodeIfPresent(Bool.self, forKey: .mic)
    }
}

func loadConfig(_ url: URL = configURL) -> Config {
    guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
    return c
}

func saveConfig(_ c: Config, _ url: URL = configURL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) {
        try? d.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// 运行日志：~/Library/Logs/AI Meeting.log（排查用，界面上的日志区之外再留一份）
let logURL = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/AI Meeting.log")
func fileLog(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

func findWhisper() -> String? {
    [engineDir.appendingPathComponent("whisper/whisper-server").path, "/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"].first { fm.isExecutableFile(atPath: $0) }
}

/// 优先用包里自带的 Node；没有（开发版）再按常见位置 + 登录 shell 找（GUI 程序拿不到终端的 PATH）
func findNode() -> String? {
    let bundled = engineDir.appendingPathComponent("node").path
    if fm.isExecutableFile(atPath: bundled) { return bundled }
    var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
    let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
    if let vs = try? fm.contentsOfDirectory(atPath: nvm.path) {
        candidates += vs.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.appendingPathComponent("\($0)/bin/node").path }
    }
    if let p = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return p }
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
    sh.arguments = ["-lc", "command -v node"]
    let pipe = Pipe(); sh.standardOutput = pipe
    try? sh.run(); sh.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return fm.isExecutableFile(atPath: out) ? out : nil
}

enum RunStatus { case idle, running, saving, waitModel }
enum DownloadUI { case hidden, connecting, progress(ModelDownloader.Progress), retrying(Double, String, Int64), verifying, ready, failed(String) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var titleLabel: NSTextField!
    var subLabel: NSTextField!
    var langSeg: NSSegmentedControl!
    var keyLabel: NSTextField!, modelLabel: NSTextField!, langLabel: NSTextField!, asrLabel: NSTextField!
    var keyField: NSSecureTextField!
    var keyLink: NSButton!
    var modelPop: NSPopUpButton!
    var langPop: NSPopUpButton!
    var asrPop: NSPopUpButton!
    var translateBox: NSButton!
    var trHint: NSTextField!
    var micBox: NSButton!
    var micHint: NSTextField!
    var startBtn: NSButton!
    var folderBtn: NSButton!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var proc: Process?
    var engineIn: FileHandle?
    var outBuf = Data()
    var lastRecord: String?
    var stopping = false
    var downloader: ModelDownloader?
    var dlRow: NSStackView!
    var dlBar: NSProgressIndicator!
    var dlLabel: NSTextField!
    var dlRetry: NSButton!
    var dlUI: DownloadUI = .hidden
    var status: RunStatus = .idle
    var logOnlyWelcome = true
    var pendingNotes: [String] = []   // 启动时迁移结果，窗口建好后打到日志区

    func applicationDidFinishLaunching(_ n: Notification) {
        fileLog("启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
        if !migrateSupport(from: legacySupport, to: appSupport).isEmpty {
            fileLog("已从旧目录迁移：\(legacySupport.path)")
            pendingNotes.append(L("log.migratedSupport"))
        }
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if keyField.stringValue.isEmpty { window.makeFirstResponder(keyField) }
        UNUserNotificationCenter.current().delegate = self
        ensureModel()   // 没有识别模型就马上在后台下载，不等点「开始」
    }

    func buildWindow() {
        let cfg = loadConfig()
        uiLang = UILang(rawValue: cfg.ui_lang ?? "") ?? .en
        if let a = asrModels.first(where: { $0.id == cfg.asr }) { asrModel = a }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 580, height: 540)
        window.delegate = self
        window.center()

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        subLabel = NSTextField(labelWithString: "")
        subLabel.textColor = .secondaryLabelColor

        langSeg = NSSegmentedControl(labels: ["English", "中文"], trackingMode: .selectOne, target: self, action: #selector(langChanged))
        langSeg.controlSize = .small
        langSeg.selectedSegment = uiLang == .zh ? 1 : 0
        langSeg.translatesAutoresizingMaskIntoConstraints = false

        keyField = NSSecureTextField()
        keyField.stringValue = cfg.api_key
        keyLink = NSButton(title: "", target: self, action: #selector(openKeys))
        keyLink.bezelStyle = .inline

        modelPop = NSPopUpButton()
        for m in models { modelPop.addItem(withTitle: m) }
        modelPop.selectItem(at: models.firstIndex(of: cfg.model) ?? 0)
        langPop = NSPopUpButton()
        for l in langs { langPop.addItem(withTitle: l) }
        langPop.selectItem(at: langs.firstIndex(of: cfg.lang) ?? 0)
        asrPop = NSPopUpButton()
        for m in asrModels { asrPop.addItem(withTitle: m.id) }
        asrPop.selectItem(at: asrModels.firstIndex { $0.id == cfg.asr } ?? 0)
        asrPop.target = self
        asrPop.action = #selector(asrChanged)

        translateBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        translateBox.state = cfg.translate ? .on : .off
        trHint = NSTextField(wrappingLabelWithString: "")
        trHint.font = .systemFont(ofSize: 11)
        trHint.textColor = .tertiaryLabelColor
        trHint.preferredMaxLayoutWidth = 400
        micBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        micBox.state = (cfg.mic ?? true) ? .on : .off
        micHint = NSTextField(wrappingLabelWithString: "")
        micHint.font = .systemFont(ofSize: 11)
        micHint.textColor = .tertiaryLabelColor
        micHint.preferredMaxLayoutWidth = 400

        keyLabel = label(); modelLabel = label(); langLabel = label(); asrLabel = label()
        var rows: [[NSView]] = [
            [keyLabel, stack([keyField, keyLink])],
            [modelLabel, modelPop],
            [langLabel, langPop],
        ]
#if arch(x86_64)
        rows.append([asrLabel, asrPop])
#endif
        rows += [[NSGridCell.emptyContentView, micBox], [NSGridCell.emptyContentView, micHint],
                 [NSGridCell.emptyContentView, translateBox], [NSGridCell.emptyContentView, trHint]]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.row(at: rows.count - 1).topPadding = -6
        grid.row(at: rows.count - 3).topPadding = -6
        keyField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        startBtn = NSButton(title: "", target: self, action: #selector(toggle))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        startBtn.controlSize = .large
        folderBtn = NSButton(title: "", target: self, action: #selector(openRecords))
        folderBtn.controlSize = .large
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        let buttons = stack([startBtn, folderBtn, statusLabel])

        // 识别模型下载进度（只在下载 / 刚下完时显示）
        dlBar = NSProgressIndicator()
        dlBar.style = .bar
        dlBar.isIndeterminate = false
        dlBar.minValue = 0; dlBar.maxValue = 1000
        dlBar.controlSize = .regular
        dlLabel = NSTextField(wrappingLabelWithString: "")
        dlLabel.font = .systemFont(ofSize: 12)
        dlLabel.textColor = .secondaryLabelColor
        dlRetry = NSButton(title: "", target: self, action: #selector(retryDownload))
        dlRetry.bezelStyle = .rounded
        dlRetry.isHidden = true
        dlRow = NSStackView(views: [dlBar, dlLabel, dlRetry])
        dlRow.orientation = .vertical
        dlRow.alignment = .leading
        dlRow.spacing = 4
        dlRow.isHidden = true

        let scroll = NSTextView.scrollableTextView()
        logView = scroll.documentView as? NSTextView
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.borderType = .bezelBorder

        let root = NSStackView(views: [titleLabel, subLabel, grid, dlRow, buttons, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        root.setCustomSpacing(4, after: titleLabel)
        root.setCustomSpacing(18, after: subLabel)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(root)
        content.addSubview(langSeg)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            dlRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44),
            dlBar.widthAnchor.constraint(equalTo: dlRow.widthAnchor),
            dlLabel.widthAnchor.constraint(equalTo: dlRow.widthAnchor),
            langSeg.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            langSeg.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
        ])
        applyLanguage()
        welcome()
        for s in pendingNotes { appendLine(s) }
        pendingNotes = []
    }

    func welcome() {
        appendLine(L("hello"))
        if !modelReady() { appendLine(L("helloDl", ["size": L(asrModel.sizeKey)])) }
        logOnlyWelcome = true
    }

    func label() -> NSTextField { let l = NSTextField(labelWithString: ""); l.textColor = .secondaryLabelColor; return l }
    func stack(_ v: [NSView]) -> NSStackView { let s = NSStackView(views: v); s.spacing = 8; return s }

    /// 把当前语言的文字填到所有控件上（切换语言时原地更新，已填的 Key / 选项都不动）
    func applyLanguage() {
        window.title = L("app.name")
        titleLabel.stringValue = L("app.name")
        subLabel.stringValue = L("tagline")
        keyLabel.stringValue = L("key.label")
        keyField.placeholderString = L("key.placeholder")
        keyLink.title = L("key.get")
        modelLabel.stringValue = L("model.label")
        langLabel.stringValue = L("lang.label")
        asrLabel.stringValue = L("asr.label")
        for (i, m) in models.enumerated() { modelPop.item(at: i)?.title = L("model." + m) }
        for (i, l) in langs.enumerated() { langPop.item(at: i)?.title = L("lang." + l) }
        for (i, m) in asrModels.enumerated() { asrPop.item(at: i)?.title = L("asr." + m.id) }
        translateBox.title = L("translate")
        micBox.title = L("mic")
        micHint.stringValue = L("mic.hint")
#if arch(x86_64)
        trHint.stringValue = L("translate.hintIntel")
#else
        trHint.stringValue = L("translate.hint")
#endif
        folderBtn.title = L("records.open")
        startBtn.title = (proc?.isRunning == true) ? L("stop") : L("start")
        dlRetry.title = L("dl.retry")
        renderStatus()
        renderDownload()
        applyMenuLanguage()
    }

    func renderStatus() {
        switch status {
        case .idle: statusLabel.stringValue = L("status.idle")
        case .running: statusLabel.stringValue = L("status.running")
        case .saving: statusLabel.stringValue = L("status.saving")
        case .waitModel: statusLabel.stringValue = L("status.waitModel")
        }
        if case .running = status { statusLabel.textColor = .systemGreen } else { statusLabel.textColor = .secondaryLabelColor }
    }

    func setStatus(_ s: RunStatus) { status = s; renderStatus() }

    @objc func langChanged() {
        let lang: UILang = langSeg.selectedSegment == 1 ? .zh : .en
        guard lang != uiLang else { return }
        uiLang = lang
        var cfg = loadConfig(); cfg.ui_lang = lang.rawValue; saveConfig(cfg)   // 只改语言这一项，记住选择
        fileLog("界面语言切换为 \(lang.rawValue)")
        applyLanguage()
        if logOnlyWelcome { logView.string = ""; welcome() }
        // 运行中：通知引擎（字幕窗、后续日志、问答提示跟着换）
        if let h = engineIn, proc?.isRunning == true { try? h.write(contentsOf: (#"{"lang":"\#(lang.rawValue)"}"# + "\n").data(using: .utf8)!) }
    }

    func currentConfig() -> Config {
        Config(api_key: keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
               model: models[max(0, modelPop.indexOfSelectedItem)],
               lang: langs[max(0, langPop.indexOfSelectedItem)],
               translate: translateBox.state == .on,
               asr: asrModels.count > 1 ? asrModels[max(0, asrPop.indexOfSelectedItem)].id : loadConfig().asr,
               ui_lang: uiLang.rawValue,
               mic: micBox.state == .on)
    }

    // ---------- 日志区 ----------
    func appendLine(_ s: String) { appendRaw(s + "\n") }

    func appendRaw(_ s: String) {
        logOnlyWelcome = false
        let clean = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)   // 去掉终端颜色码
        fileLog(clean.trimmingCharacters(in: .newlines))
        logView.textStorage?.append(NSAttributedString(string: clean, attributes: [.font: logView.font!, .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
    }

    /// 引擎输出按整行处理（按字节切行，中文不会被拆坏）；@@ 开头的是给本程序的控制行，不原样显示
    func engineOutput(_ d: Data) {
        outBuf.append(d)
        while let i = outBuf.firstIndex(of: 0x0A) {
            let lineData = outBuf.subdata(in: outBuf.startIndex..<i)
            outBuf.removeSubrange(outBuf.startIndex...i)
            engineLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    func engineLine(_ line: String) {
        if line.hasPrefix("@@record ") { lastRecord = String(line.dropFirst(9)); return }
        if line.hasPrefix("@@perm") { permissionHelp(); return }
        if line.hasPrefix("@@micdenied") { return }   // capture 已经打了一行说明
        if line.hasPrefix("@@notice ") {
            // @@notice <级别> <代码> <文字>
            let parts = line.dropFirst(9).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return }
            appendLine((parts[0] == "ok" ? "✓ " : "⚠ ") + parts[2])
            if parts[0] == "error", ["insufficient_credits", "invalid_key"].contains(parts[1]) { accountAlert(code: parts[1]) }
            return
        }
        appendLine(line)
        if line.contains("TCC") { permissionHelp() }
    }

    func setRunning(_ on: Bool) {
        startBtn.title = on ? L("stop") : L("start")
        for c in [keyField, modelPop, langPop, asrPop, translateBox, micBox] as [NSControl] { c.isEnabled = !on }
        setStatus(on ? .running : .idle)
    }

    @objc func toggle() {
        if let p = proc, p.isRunning { stop(); return }
        if !modelReady() { ensureModel(); return }   // 模型还在下载：按钮本来就是灰的，这里兜底
        let cfg = currentConfig()
        if cfg.api_key.isEmpty {
            alert(L("alert.needKey"), L("alert.needKeyDetail"))
            window.makeFirstResponder(keyField); return
        }
        saveConfig(cfg)
        asrModel = asrModels.first { $0.id == cfg.asr } ?? asrModels[0]   // 下载中不会走到这里（上面已 return），不会中途换文件
        guard let node = findNode() else { alert(L("alert.noNode"), L("alert.noNodeDetail")); return }
        guard findWhisper() != nil else { alert(L("alert.noWhisper"), L("alert.noWhisperDetail")); return }
        if cfg.mic ?? true {
            // 麦克风权限：第一次在这里由系统弹窗询问；被拒过就提示一下，可以不录麦克风继续（不影响已有的录屏 / 系统录音权限）
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: launch(cfg, node: node, mic: true)
            case .notDetermined:
                startBtn.isEnabled = false
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        self.startBtn.isEnabled = true
                        fileLog("麦克风授权结果：\(ok)")
                        if !ok { self.appendLine(L("log.micOff")) }
                        self.launch(cfg, node: node, mic: ok)
                    }
                }
            default:
                let a = NSAlert()
                a.messageText = L("alert.micOff"); a.informativeText = L("alert.micOffDetail")
                a.addButton(withTitle: L("alert.continue"))
                a.addButton(withTitle: L("alert.openSettings"))
                if a.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    return
                }
                appendLine(L("log.micOff"))
                launch(cfg, node: node, mic: false)
            }
            return
        }
        launch(cfg, node: node, mic: false)
    }

    func launch(_ cfg: Config, node: String, mic: Bool) {
        guard proc?.isRunning != true else { return }
        prepareRecordsDir()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        var args = [engineDir.appendingPathComponent("run.mjs").path, "--lang", cfg.lang, "--out", recordsDir.path,
                    "--model", modelURL.path]
        if !cfg.translate { args.append("--no-translate") }
        if mic { args.append("--mic") }
        p.arguments = args
        p.currentDirectoryURL = engineDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + URL(fileURLWithPath: node).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["MODELFOLD_API_KEY"] = cfg.api_key
        env["MODELFOLD_MODEL"] = cfg.model
        env["AIM_LANG"] = uiLang.rawValue
        env["AIM_APP"] = "1"
        p.environment = env
        let pipe = Pipe(), input = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = input
        outBuf = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { self?.engineOutput(d) }
        }
        p.terminationHandler = { [weak self] pr in
            fileLog("引擎退出 status=\(pr.terminationStatus) reason=\(pr.terminationReason == .uncaughtSignal ? "signal" : "exit")")
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { self.engineOutput(rest) }
                if !self.outBuf.isEmpty { self.engineOutput(Data([0x0A])) }
                self.engineIn = nil
                self.setRunning(false)
                self.appendLine("\n" + L("log.ended", ["code": pr.terminationStatus]))
                if self.stopping, let r = self.lastRecord { self.openRecord(URL(fileURLWithPath: r)) }
                self.stopping = false
                if NSApp.isTerminatingSoon { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        do {
            try p.run()
            proc = p
            engineIn = input.fileHandleForWriting
            lastRecord = nil
            accountAlerted = []
            setRunning(true)
            appendLine("\n" + L("log.loading"))
        } catch {
            appendLine(L("log.startFail", ["msg": error.localizedDescription]))
        }
    }

    func stop() {
        fileLog("用户点了停止")
        guard let p = proc, p.isRunning else { return }
        stopping = true
        setStatus(.saving)
        p.interrupt()   // SIGINT：run.mjs 收尾、写完记录再退出
    }

    func prepareRecordsDir() {
        let n = migrateRecords(from: legacyRecordsDir, to: recordsDir)
        if n > 0 { appendLine(L("log.migratedRecords", ["n": n, "path": recordsDir.path])) }
        try? fm.createDirectory(at: recordsDir, withIntermediateDirectories: true)
    }

    func alert(_ title: String, _ detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.addButton(withTitle: L("alert.ok")); a.runModal()
    }

    // ---------- 识别模型：后台下载（断点续传）+ 进度条 ----------
    /// 当前选的识别模型不在就开始 / 继续下载；在就把「开始」放开
    func ensureModel() {
        if modelReady() {
            if downloader != nil { downloader?.cancel(); downloader = nil }
            updateStartEnabled()
            return
        }
        if let d = downloader, d.running, d.dest == downloadedModelURL { return }
        downloader?.cancel()
        let m = asrModel
        let d = ModelDownloader(sources: modelSources(m), dest: downloadedModelURL, expectedSize: m.bytes, sha256: m.sha256)
        var logged = false
        d.onState = { [weak self, weak d] st in
            guard let self, let d, d === self.downloader else { return }
            switch st {
            case let .connecting(from, host):
                if !logged {
                    logged = true
                    self.appendLine(from > 0 ? L("log.dlResume", ["done": from / 1_000_000, "total": m.bytes / 1_000_000, "host": host])
                                             : L("log.dlStart", ["size": L(m.sizeKey), "host": host]))
                }
                if case .progress = self.dlUI {} else { self.setDownloadUI(from > 0 ? .progress(.init(done: from, total: m.bytes, speed: 0, eta: nil)) : .connecting) }
            case .running: break
            case let .retrying(after, reason): self.setDownloadUI(.retrying(after, reason, d.done))
            case .verifying: self.setDownloadUI(.verifying)
            case .done:
                fileLog("识别模型下载完成：\(downloadedModelURL.path)")
                self.downloader = nil
                self.appendLine(L("log.dlDone"))
                self.setDownloadUI(.ready)
                self.notifyReady()
            case let .failed(msg):
                fileLog("识别模型下载失败：\(msg)")
                self.appendLine(L("log.dlFailed", ["msg": msg]))
                self.setDownloadUI(.failed(msg))
            }
        }
        d.onProgress = { [weak self, weak d] p in
            guard let self, let d, d === self.downloader else { return }
            self.setDownloadUI(.progress(p))
        }
        downloader = d
        requestNotificationPermission()
        setDownloadUI(.connecting)
        d.start()
    }

    /// Intel 版换识别模型：没下过的马上开始下（另一个没下完的 .part 留着，切回来接着下）
    @objc func asrChanged() {
        asrModel = asrModels[max(0, asrPop.indexOfSelectedItem)]
        var cfg = loadConfig(); cfg.asr = asrModel.id; saveConfig(cfg)
        downloader?.cancel(); downloader = nil
        if modelReady() { setDownloadUI(.hidden) }
        ensureModel()
    }

    @objc func retryDownload() { downloader?.cancel(); downloader = nil; ensureModel() }

    var dlActivity: NSObjectProtocol?
    func setDownloadUI(_ s: DownloadUI) {
        dlUI = s; renderDownload(); updateStartEnabled()
        // 下载期间别让 App Nap / 闲置睡眠把下载拖慢
        switch s {
        case .connecting, .progress, .retrying, .verifying:
            if dlActivity == nil { dlActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading speech model") }
        default:
            if let a = dlActivity { ProcessInfo.processInfo.endActivity(a); dlActivity = nil }
        }
    }

    func renderDownload() {
        guard dlRow != nil else { return }
        let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_000_000) }
        let clean = { (m: String) in m.trimmingCharacters(in: CharacterSet(charactersIn: ".。 ")) }   // 系统错误文字自带句号
        dlRetry.isHidden = true
        dlLabel.textColor = .secondaryLabelColor
        switch dlUI {
        case .hidden:
            dlRow.isHidden = true
        case .connecting:
            dlRow.isHidden = false
            dlBar.isHidden = false; dlBar.doubleValue = 0
            dlLabel.stringValue = L("dl.connecting", ["size": L(asrModel.sizeKey)])
        case let .progress(p):
            dlRow.isHidden = false
            dlBar.isHidden = false
            let frac = p.total > 0 ? Double(p.done) / Double(p.total) : 0
            dlBar.doubleValue = frac * 1000
            var eta = L("dl.etaUnknown")
            if let e = p.eta { eta = e >= 90 ? L("dl.etaMin", ["n": Int((e / 60).rounded())]) : L("dl.etaSec", ["n": max(1, Int(e.rounded()))]) }
            dlLabel.stringValue = L("dl.progress", ["pct": Int(frac * 100), "done": mb(p.done), "total": mb(p.total),
                                                    "speed": L("dl.speed", ["v": String(format: "%.1f", p.speed / 1_000_000)]), "eta": eta])
        case let .retrying(after, reason, done):
            dlRow.isHidden = false
            dlLabel.stringValue = L("dl.retrying", ["msg": clean(reason), "n": Int(after.rounded(.up)), "done": mb(done), "total": mb(asrModel.bytes)])
        case .verifying:
            dlRow.isHidden = false
            dlBar.doubleValue = 1000
            dlLabel.stringValue = L("dl.verifying")
        case .ready:
            dlRow.isHidden = false
            dlBar.isHidden = true
            dlLabel.stringValue = L("dl.ready")
            dlLabel.textColor = .systemGreen
        case let .failed(msg):
            dlRow.isHidden = false
            dlLabel.stringValue = L("dl.failed", ["msg": clean(msg)])
            dlLabel.textColor = .systemRed
            dlRetry.isHidden = false
        }
    }

    /// 「开始」只在模型就绪时可点；下载中旁边写明原因
    func updateStartEnabled() {
        guard startBtn != nil, proc?.isRunning != true else { return }
        let ready = modelReady()
        startBtn.isEnabled = ready
        if !ready { setStatus(.waitModel) } else if case .waitModel = status { setStatus(.idle) }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            fileLog("通知授权：\(ok) \(err?.localizedDescription ?? "")")
        }
    }

    func notifyReady() {
        let c = UNMutableNotificationContent()
        c.title = L("notify.title")
        c.body = L("notify.body")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "model-ready", content: c, trigger: nil)) { err in
            if let err { fileLog("通知发送失败：\(err.localizedDescription)") }
        }
    }

    // App 在前台时也显示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 积分不足 / Key 无效：每次运行只弹一次（字幕窗顶部另有横幅常驻提示）
    var accountAlerted: Set<String> = []
    func accountAlert(code: String) {
        guard !accountAlerted.contains(code) else { return }
        accountAlerted.insert(code)
        DispatchQueue.main.async {
            let a = NSAlert()
            if code == "insufficient_credits" {
                a.messageText = L("alert.credits")
                a.informativeText = L("alert.creditsDetail")
                a.addButton(withTitle: L("alert.topUp"))
            } else {
                a.messageText = L("alert.invalidKey")
                a.informativeText = L("alert.invalidKeyDetail")
                a.addButton(withTitle: L("alert.manageKeys"))
            }
            a.addButton(withTitle: L("alert.later"))
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://ai.modelfold.online/account?tab=keys&utm_source=github&utm_medium=readme")!)
            }
        }
    }

    var permissionAsked = false
    func permissionHelp() {
        guard !permissionAsked else { return }
        permissionAsked = true
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = L("alert.perm")
            a.informativeText = L("alert.permDetail")
            a.addButton(withTitle: L("alert.openSettings"))
            a.addButton(withTitle: L("alert.later"))
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            self.permissionAsked = false
        }
    }

    /// 会议记录是 .md：很多 Mac 上 .md 默认由 Xcode 打开（会弹安装组件提示），固定用「文本编辑」
    func openRecord(_ url: URL) {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openRecords() {
        prepareRecordsDir()
        NSWorkspace.shared.open(recordsDir)
    }

    @objc func openKeys() { NSWorkspace.shared.open(URL(string: "https://ai.modelfold.online/account?tab=keys&utm_source=github&utm_medium=readme")!) }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func windowWillClose(_ n: Notification) { fileLog("主窗口被关闭") }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        fileLog("收到退出请求（运行中：\(proc?.isRunning == true)）")
        guard let p = proc, p.isRunning else { return .terminateNow }
        NSApp.isTerminatingSoon = true
        stopping = false
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if p.isRunning { p.terminate() } }
        return .terminateLater
    }

    // ---------- 菜单 ----------
    var quitItem: NSMenuItem!, editMenu: NSMenu!, cutItem: NSMenuItem!, copyItem: NSMenuItem!, pasteItem: NSMenuItem!, selectAllItem: NSMenuItem!

    /// 最小菜单：让 ⌘Q / ⌘C / ⌘V 能用（粘贴 Key 要用）
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        quitItem = appMenu.addItem(withTitle: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); menu.addItem(editItem)
        editMenu = NSMenu(title: "")
        cutItem = editMenu.addItem(withTitle: "", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        copyItem = editMenu.addItem(withTitle: "", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        pasteItem = editMenu.addItem(withTitle: "", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        selectAllItem = editMenu.addItem(withTitle: "", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        applyMenuLanguage()
        return menu
    }

    func applyMenuLanguage() {
        guard quitItem != nil else { return }
        quitItem.title = L("menu.quit")
        editMenu.title = L("menu.edit")
        cutItem.title = L("menu.cut"); copyItem.title = L("menu.copy"); pasteItem.title = L("menu.paste"); selectAllItem.title = L("menu.selectAll")
    }

    // ---------- 无窗口截图（--snapshot）：窗口不上屏，直接把内容视图渲染成 PNG ----------
    func snapshot(to dir: URL) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let states: [(String, DownloadUI)] = [
            ("", .hidden),
            ("-dl", .progress(.init(done: asrModel.bytes * 45 / 100, total: asrModel.bytes, speed: 8_200_000, eta: Double(asrModel.bytes * 55 / 100) / 8_200_000))),
            ("-retry", .retrying(8, "The network connection was lost.", asrModel.bytes * 45 / 100)),
            ("-failed", .failed("The Internet connection appears to be offline.")),
            ("-ready", .ready),
        ]
        for lang in UILang.allCases {
            for (suffix, st) in states {
                langSeg.selectedSegment = lang == .zh ? 1 : 0
                uiLang = lang
                applyLanguage()
                setDownloadUI(st)
                if case .ready = st { startBtn.isEnabled = true; setStatus(.idle) }
                logView.string = ""
                welcome()
                let v = window.contentView!
                v.layoutSubtreeIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = dir.appendingPathComponent("main-\(lang.rawValue)\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                print(out.path)
            }
        }
    }
}

extension NSApplication {
    private static var terminatingKey = false
    var isTerminatingSoon: Bool {
        get { NSApplication.terminatingKey }
        set { NSApplication.terminatingKey = newValue }
    }
}

// ---------- 自检（--selftest）：不开窗口，检查文案齐全 + 旧目录迁移 ----------
func selftest() -> Int32 {
    var fail = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { fail += 1 } }
    let en = Set(STR[.en]!.keys), zh = Set(STR[.zh]!.keys)
    check(en == zh, "en/zh 文案键一致（只在 en：\(en.subtracting(zh).sorted())，只在 zh：\(zh.subtracting(en).sorted())）")
    for m in models { check(en.contains("model." + m), "模型文案 \(m)") }
    for l in langs { check(en.contains("lang." + l), "语言文案 \(l)") }
    for m in asrModels { check(en.contains("asr." + m.id) && en.contains(m.sizeKey), "识别模型文案 \(m.id)") }
    for k in en.sorted() { print("key \(k)") }   // 给 test-i18n.mjs 比对源码里用到的键

    let tmp = fm.temporaryDirectory.appendingPathComponent("aim-selftest-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? fm.removeItem(at: tmp) }
    let oldS = tmp.appendingPathComponent("会议助手"), newS = tmp.appendingPathComponent("AI Meeting")
    try? fm.createDirectory(at: oldS.appendingPathComponent("models"), withIntermediateDirectories: true)
    try? #"{"api_key":"test-old","model":"gpt-6-luna","lang":"zh","translate":false}"#.write(to: oldS.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    try? Data(repeating: 7, count: 4096).write(to: oldS.appendingPathComponent("models/m.bin"))
    let moved = migrateSupport(from: oldS, to: newS)
    check(moved.sorted() == ["config.json", "models/m.bin"], "迁移 Application Support：\(moved)")
    let c = loadConfig(newS.appendingPathComponent("config.json"))
    check(c.api_key == "test-old" && c.model == "gpt-6-luna" && c.lang == "zh" && !c.translate && c.ui_lang == nil, "旧 config.json 读得出（Key / 模型 / 语言 / 翻译开关，ui_lang 缺省）")
    let ino = { (u: URL) in ((try? fm.attributesOfItem(atPath: u.path)[.systemFileNumber]) as? NSNumber)?.intValue ?? -1 }
    check(ino(oldS.appendingPathComponent("models/m.bin")) == ino(newS.appendingPathComponent("models/m.bin")), "模型是硬链接（不多占空间）")
    check(fm.fileExists(atPath: oldS.appendingPathComponent("config.json").path), "旧目录原样保留（旧版照样能用）")
    let perm = ((try? fm.attributesOfItem(atPath: newS.appendingPathComponent("config.json").path)[.posixPermissions]) as? NSNumber)?.intValue
    check(perm == 0o600, "新 config.json 权限 600")
    try? #"{"api_key":"test-new"}"#.write(to: newS.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    check(migrateSupport(from: oldS, to: newS).isEmpty && loadConfig(newS.appendingPathComponent("config.json")).api_key == "test-new", "新目录已有配置时不覆盖，重复迁移无动作")
    let partial = loadConfig(newS.appendingPathComponent("config.json"))
    check(partial.model == "deepseek-v4-1-flash" && partial.translate, "字段不全的配置也能读（缺省值补上）")
    var s = partial; s.ui_lang = "zh"; saveConfig(s, newS.appendingPathComponent("config.json"))
    check(loadConfig(newS.appendingPathComponent("config.json")).ui_lang == "zh", "ui_lang 存取")

    let oldR = tmp.appendingPathComponent("会议助手记录"), newR = tmp.appendingPathComponent("AI Meeting Notes")
    try? fm.createDirectory(at: oldR, withIntermediateDirectories: true)
    for f in ["a.md", "b.md"] { try? f.write(to: oldR.appendingPathComponent(f), atomically: true, encoding: .utf8) }
    check(migrateRecords(from: oldR, to: newR) == 2 && !fm.fileExists(atPath: oldR.path) && fm.fileExists(atPath: newR.appendingPathComponent("b.md").path), "记录文件夹整体改名")
    try? fm.createDirectory(at: oldR, withIntermediateDirectories: true)
    for f in ["a.md", "c.md"] { try? "old".write(to: oldR.appendingPathComponent(f), atomically: true, encoding: .utf8) }
    let n2 = migrateRecords(from: oldR, to: newR)
    check(n2 == 1 && (try? String(contentsOf: newR.appendingPathComponent("a.md"), encoding: .utf8)) == "a.md" && fm.fileExists(atPath: oldR.appendingPathComponent("a.md").path), "两边都有时只移不重名的，同名文件不覆盖、留在原处")
    check(migrateRecords(from: tmp.appendingPathComponent("不存在"), to: newR) == 0, "没有旧记录时无动作")
    // 包内带模型（BUNDLE_MODEL=1）时：每个识别模型都必须优先用包里的，不走下载
    if fm.fileExists(atPath: bundledModelsDir.path) {
        for m in asrModels {
            asrModel = m
            check(modelURL == bundledModelURL && modelReady(), "包内识别模型优先：\(m.file)（\(fileSize(bundledModelURL) / 1_000_000)MB）")
        }
        asrModel = asrModels[0]
    } else { print("info 包内没有识别模型（精简包 / 开发版），用 \(downloadedModelURL.path)") }
    print(fail == 0 ? "selftest 全部通过" : "selftest 失败 \(fail) 项")
    return fail == 0 ? 0 : 1
}

let argv = CommandLine.arguments
if argv.contains("--selftest") { exit(selftest()) }

// 下载器自测（--download-test --url U [--url U2] --dest 路径 --size 字节数 [--sha 十六进制]）：不开窗口，进度和结果打到 stdout
if argv.contains("--download-test") {
    var urls: [URL] = [], dest = "", size: Int64 = 0, sha: String? = nil
    var k = 1
    while k < argv.count {
        let v = k + 1 < argv.count ? argv[k + 1] : ""
        switch argv[k] {
        case "--url": urls.append(URL(string: v)!); k += 2
        case "--dest": dest = v; k += 2
        case "--size": size = Int64(v) ?? 0; k += 2
        case "--sha": sha = v; k += 2
        default: k += 1
        }
    }
    let d = ModelDownloader(sources: urls, dest: URL(fileURLWithPath: dest), expectedSize: size, sha256: sha)
    func out(_ s: String) { print(s); fflush(stdout) }
    d.onProgress = { p in out("progress \(p.done) \(p.total) \(Int(p.speed)) \(p.eta.map { String(Int($0)) } ?? "-")") }
    d.onState = { st in
        switch st {
        case let .connecting(from, host): out("connecting \(from) \(host)")
        case .running: out("running")
        case let .retrying(after, reason): out("retrying \(after) \(reason)")
        case .verifying: out("verifying")
        case .done: out("RESULT ok"); exit(0)
        case let .failed(m): out("RESULT fail \(m)"); exit(1)
        }
    }
    d.start()
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
if let i = argv.firstIndex(of: "--snapshot"), i + 1 < argv.count {
    app.setActivationPolicy(.prohibited)   // 不进 Dock、窗口不上屏
    app.mainMenu = delegate.buildMenu()
    delegate.buildWindow()
    delegate.snapshot(to: URL(fileURLWithPath: argv[i + 1]))
    exit(0)
}
app.setActivationPolicy(.regular)
app.delegate = delegate
app.mainMenu = delegate.buildMenu()
app.run()
