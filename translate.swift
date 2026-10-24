// AI Meeting · 翻译：Mac 自带的离线翻译（Translation 框架，不联网、免费）
// 提示文字跟环境变量 AIM_LANG=en|zh（默认英文）
//
// 常驻进程：stdin 每行一个 JSON {"id":..,"text":..,"lang":"zh"|"en"|..}，
// stdout 每行回 {"id":..,"text":译文,"to":..}。中文 → 英文，其它语言 → 中文。
//
// 编译：swiftc -O translate.swift -o translate
// 首次用到某个语言对，系统需要已下载对应离线语言包（系统设置 → 通用 → 语言与地区 → 翻译语言）。

import Foundation
import Translation

let ZH = ProcessInfo.processInfo.environment["AIM_LANG"] == "zh"
func L(_ en: String, _ zh: String) -> String { ZH ? zh : en }

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func emit(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), var line = String(data: d, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

let zh = Locale.Language(identifier: "zh-Hans")
let en = Locale.Language(identifier: "en")
var sessions: [String: TranslationSession] = [:]

#if arch(x86_64)
// Intel 版按 macOS 15 编译（Apple 芯片版按本机 macOS 26），而不带界面直接翻译的接口 macOS 26 才有：
// 老系统上每句回一个 error，run.mjs 照常出原文，只是没有译文
@available(macOS 26.0, *)
func session(from: Locale.Language, to: Locale.Language) -> TranslationSession {
    let key = "\(from.minimalIdentifier)>\(to.minimalIdentifier)"
    if let s = sessions[key] { return s }
    let s = TranslationSession(installedSource: from, target: to)
    sessions[key] = s
    return s
}
#else
func session(from: Locale.Language, to: Locale.Language) -> TranslationSession {
    let key = "\(from.minimalIdentifier)>\(to.minimalIdentifier)"
    if let s = sessions[key] { return s }
    let s = TranslationSession(installedSource: from, target: to)
    sessions[key] = s
    return s
}
#endif

Task {
    // 启动时报一下语言包状态，缺了好提示去下载
    let avail = LanguageAvailability()
    for (a, b) in [(zh, en), (en, zh)] {
        let st = await avail.status(from: a, to: b)
        let state = st == .installed ? L("installed", "已安装")
            : st == .supported ? L("not downloaded (download it in System Settings → General → Language & Region → Translation Languages)", "未下载（需在 系统设置 → 通用 → 语言与地区 → 翻译语言 下载）")
            : L("not supported", "不支持")
        log(L("Translation language \(a.minimalIdentifier) → \(b.minimalIdentifier): ", "翻译语言包 \(a.minimalIdentifier) → \(b.minimalIdentifier)：") + state)
    }
#if arch(x86_64)
    if #unavailable(macOS 26.0) { log(L("Live translation needs macOS 26 or later; this Mac shows the original text only", "实时翻译需要 macOS 26 或更新，当前系统只出原文")) }
#endif
    emit(["ready": true])

    while let line = readLine() {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let text = obj["text"] as? String else { continue }
        let id = obj["id"] ?? NSNull()
        let lang = (obj["lang"] as? String) ?? "auto"
        let from = lang == "auto" ? (text.range(of: "\\p{Han}", options: .regularExpression) != nil ? zh : en) : Locale.Language(identifier: lang == "zh" ? "zh-Hans" : lang)
        let to = from.minimalIdentifier.hasPrefix("zh") ? en : zh
        do {
#if arch(x86_64)
            guard #available(macOS 26.0, *) else { emit(["id": id, "error": "macOS 26+ required"]); continue }
#endif
            let r = try await session(from: from, to: to).translate(text)
            emit(["id": id, "text": r.targetText, "to": to.minimalIdentifier])
        } catch {
            emit(["id": id, "error": error.localizedDescription])
        }
    }
    exit(0)
}

dispatchMain()
