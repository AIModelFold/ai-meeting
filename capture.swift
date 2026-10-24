// AI Meeting · 第一步：抓 Mac 扬声器里的系统声音（ScreenCaptureKit，不用虚拟声卡）
// 提示文字跟环境变量 AIM_LANG=en|zh（默认英文）；AIM_APP=1（应用版）启动失败时多打一行 @@perm 让主窗口弹权限引导
//
// 输出：16kHz 单声道 16-bit 小端 PCM，写到 stdout（后面接语音识别）或 --out 文件（.wav）。
// --mic：同时录麦克风（macOS 15+ ScreenCaptureKit 自带的麦克风采集，需要「麦克风」权限），同样格式写到 fd 3（或 --mic-out 文件）；
//        没有麦克风权限 / 打不开就只录系统声音，不影响主流程。
// stderr 每秒打一行电平，方便确认真的抓到了声音。
//
// 编译：swiftc -O capture.swift -o capture
// 用法：./capture --out test.wav --seconds 10      录 10 秒到 wav
//       ./capture --out sys.wav --mic --mic-out mic.wav --seconds 10   系统声音和麦克风各录一份
//       ./capture | 识别程序                        持续输出 PCM 到 stdout
// 首次运行需要在「系统设置 → 隐私与安全性 → 屏幕与系统录音」里允许运行它的终端。

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let SAMPLE_RATE = 16000.0
let ENV = ProcessInfo.processInfo.environment
let ZH = ENV["AIM_LANG"] == "zh"
let IN_APP = ENV["AIM_APP"] == "1"
func L(_ en: String, _ zh: String) -> String { ZH ? zh : en }

struct Options {
    var out: String? = nil
    var seconds: Double? = nil
    var quiet = false
    var mic = false
    var micOut: String? = nil
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out": o.out = it.next()
        case "--seconds": o.seconds = it.next().flatMap(Double.init)
        case "--quiet": o.quiet = true
        case "--mic": o.mic = true
        case "--mic-out": o.micOut = it.next()
        default:
            FileHandle.standardError.write(L("Unknown argument \(a)\n", "未知参数 \(a)\n").data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// 输出端：stdout 直写 PCM；文件则先留 44 字节 wav 头，结束时补长度
final class PcmSink {
    private let handle: FileHandle
    private let isFile: Bool
    private(set) var bytes = 0

    init(handle: FileHandle) { self.handle = handle; isFile = false }

    init(path: String?) throws {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: path) else { throw NSError(domain: "capture", code: 1) }
            handle = h
            isFile = true
            handle.write(Data(count: 44))
        } else {
            handle = FileHandle.standardOutput
            isFile = false
        }
    }

    func write(_ samples: [Int16]) {
        let d = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        handle.write(d)
        bytes += d.count
    }

    func finish() {
        guard isFile else { return }
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + bytes))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(SAMPLE_RATE)); u32(UInt32(SAMPLE_RATE) * 2); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(bytes))
        handle.seek(toFileOffset: 0)
        handle.write(h)
        handle.closeFile()
    }
}

/// 一路声音（系统声音 / 麦克风）各自的格式转换：原始格式 → 16kHz 单声道 Int16
final class Resampler {
    let name: String
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    private let dstFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SAMPLE_RATE, channels: 1, interleaved: true)!
    init(name: String) { self.name = name }

    func convert(_ sb: CMSampleBuffer) -> [Int16]? {
        guard sb.isValid, let desc = sb.formatDescription, let asbd = desc.audioStreamBasicDescription else { return nil }
        if srcFormat == nil {
            var a = asbd
            srcFormat = AVAudioFormat(streamDescription: &a)
            if let s = srcFormat {
                converter = AVAudioConverter(from: s, to: dstFormat)
                log(L("\(name) audio format: \(Int(s.sampleRate)) Hz × \(s.channelCount) ch → 16000 Hz mono",
                      "\(name)格式：\(Int(s.sampleRate))Hz × \(s.channelCount) 声道 → 输出 16000Hz 单声道"))
            }
        }
        guard let srcFormat, let converter else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList)
        guard st == noErr else { return nil }
        let outCap = AVAudioFrameCount(Double(frames) * SAMPLE_RATE / srcFormat.sampleRate) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, let ch = outBuf.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}

final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    let sink: PcmSink
    let micSink: PcmSink?
    let quiet: Bool
    private let sys = Resampler(name: L("System", "系统音频"))
    private let mic = Resampler(name: L("Microphone", "麦克风"))
    private var peak: Float = 0
    private var sumSq: Double = 0
    private var count = 0
    private var lastReport = Date()

    init(sink: PcmSink, micSink: PcmSink?, quiet: Bool) {
        self.sink = sink
        self.micSink = micSink
        self.quiet = quiet
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard let samples = sys.convert(sb) else { return }
            sink.write(samples)
            meter(samples)
            return
        }
        if #available(macOS 15.0, *), type == .microphone, let micSink, let samples = mic.convert(sb) {
            micSink.write(samples)
        }
    }

    private func meter(_ s: [Int16]) {
        for v in s {
            let f = Float(v) / 32768
            peak = max(peak, abs(f))
            sumSq += Double(f * f)
        }
        count += s.count
        if !quiet, Date().timeIntervalSince(lastReport) >= 1, count > 0 {
            let rms = sqrt(sumSq / Double(count))
            let db = rms > 0 ? 20 * log10(rms) : -120
            let bar = String(repeating: "█", count: max(0, min(30, Int((db + 60) / 2))))
            log(String(format: L("Level %6.1f dB  peak %.3f  %@", "电平 %6.1f dB  峰值 %.3f  %@"), db, peak, bar))
            peak = 0; sumSq = 0; count = 0; lastReport = Date()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log(L("Capture stopped: ", "采集停止：") + error.localizedDescription)
        sink.finish()
        micSink?.finish()
        exit(1)
    }
}

let opts = parseArgs()
let sink: PcmSink
do { sink = try PcmSink(path: opts.out) } catch { log(L("Cannot open the output file", "打不开输出文件")); exit(1) }
// 麦克风输出：--mic-out 文件，否则 fd 3（run.mjs 开的管道）；fd 3 没开就不录麦克风
var micSink: PcmSink? = nil
if opts.mic {
    if let p = opts.micOut { micSink = try? PcmSink(path: p) }
    else if fcntl(3, F_GETFD) != -1 { micSink = PcmSink(handle: FileHandle(fileDescriptor: 3, closeOnDealloc: false)) }
    else { log(L("--mic needs fd 3 or --mic-out; microphone not captured", "--mic 需要 fd 3 或 --mic-out，不录麦克风")) }
}
let tap = AudioTap(sink: sink, micSink: micSink, quiet: opts.quiet)
var activeStream: SCStream?

func stopAndExit(_ code: Int32) {
    let s = activeStream
    Task {
        try? await s?.stopCapture()
        sink.finish()
        micSink?.finish()
        let secs = String(format: "%.1f", Double(sink.bytes) / 2 / SAMPLE_RATE)
        log(L("Stopped, \(secs) s of audio", "已停止，共 \(secs) 秒音频"))
        exit(code)
    }
}

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler { stopAndExit(0) }
sigSrc.resume()
signal(SIGPIPE, SIG_IGN)

Task {
    do {
        // 只要音频：随便取一块屏幕当捕获对象，视频压到最小
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { log(L("No display found", "找不到显示器")); exit(1) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = false  // 本程序不出声；设 true 会连带把同一终端里播放的声音也排除掉
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        var useMic = false
        if micSink != nil {
            // 麦克风权限：未决定时在这里请求（应用版主窗口一般已经先问过）；被拒就只录系统声音
            var st = AVCaptureDevice.authorizationStatus(for: .audio)
            if st == .notDetermined { st = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied }
            if st != .authorized {
                log(L("Microphone access is off, so only computer sound is captured. To include your voice: System Settings → Privacy & Security → Microphone, allow “AI Meeting”, then start again",
                      "没有麦克风权限，只录电脑声音。要录自己的声音：系统设置 → 隐私与安全性 → 麦克风，允许「AI Meeting」后重新开始"))
                if IN_APP { log("@@micdenied") }
            } else if AVCaptureDevice.default(for: .audio) == nil {
                log(L("No microphone found, only computer sound is captured", "找不到麦克风，只录电脑声音"))
            } else if #available(macOS 15.0, *) {
                useMic = true
            }
        }
        func makeStream(mic: Bool) throws -> SCStream {
            if #available(macOS 15.0, *) { cfg.captureMicrophone = mic }
            let stream = SCStream(filter: filter, configuration: cfg, delegate: tap)
            try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
            if mic, #available(macOS 15.0, *) { try stream.addStreamOutput(tap, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "mic")) }
            return stream
        }
        var stream = try makeStream(mic: useMic)
        do { try await stream.startCapture() } catch where useMic {
            // 带麦克风启动失败：退回只录系统声音，别让麦克风拖垮主流程
            log(L("Could not open the microphone (\(error.localizedDescription)), only computer sound is captured", "麦克风打不开（\(error.localizedDescription)），只录电脑声音"))
            useMic = false
            stream = try makeStream(mic: false)
            try await stream.startCapture()
        }
        if useMic { log(L("Microphone on: ", "麦克风已开：") + (AVCaptureDevice.default(for: .audio)?.localizedName ?? "")) }
        activeStream = stream
        if IN_APP { log(L("Capturing system audio", "开始抓取系统声音")) }
        else { log(L("Capturing system audio", "开始抓取系统声音") + (opts.out.map { " → \($0)" } ?? " → stdout") + L(" (Ctrl+C to stop)", "（Ctrl+C 停止）")) }
        if let secs = opts.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { stopAndExit(0) }
        }
    } catch {
        log(L("Could not start capture: ", "启动失败：") + error.localizedDescription)
        log(L("If this is a permission problem: System Settings → Privacy & Security → Screen & System Audio Recording, allow “AI Meeting” (your Terminal when run from the command line), then try again",
              "如果是权限问题：系统设置 → 隐私与安全性 → 屏幕与系统录音，允许「AI Meeting」（命令行运行时是当前终端）后重试"))
        if IN_APP { log("@@perm") }
        exit(1)
    }
}

dispatchMain()
