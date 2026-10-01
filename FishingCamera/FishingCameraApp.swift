import SwiftUI
import AVFoundation
import VideoToolbox
import Photos
import Speech
import AudioToolbox
import MediaPlayer
import CoreMotion
import UIKit
import Combine

// MARK: - 调试日志（写入沙盒文档目录 + 内存缓冲供屏幕显示）
enum LogBuffer {
    private static let lock = NSLock()
    private static var lines: [String] = []
    static func add(_ s: String) {
        lock.lock()
        lines.append(s)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
        lock.unlock()
    }
    static func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

enum Log {
    private static var url: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("debug_log.txt")
    }
    private static let queue = DispatchQueue(label: "com.fishing.camera.log")
    static func write(_ s: String) {
        LogBuffer.add(s)
        queue.async {
            let line = "[\(Date())] \(s)\n"
            print(line, terminator: "")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                if let d = line.data(using: .utf8) { h.write(d) }
                h.closeFile()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - 设计常量
enum Design {
    static let accent = Color(red: 0.25, green: 0.85, blue: 0.75)
    static let record = Color(red: 1.0, green: 0.26, blue: 0.26)
    static let warm = Color(red: 1.0, green: 0.78, blue: 0.35)
    static let glassBg = Color.black.opacity(0.42)
    static let glassBorder = Color.white.opacity(0.16)
    static func mono(_ s: CGFloat) -> Font { .system(size: s, weight: .medium, design: .monospaced) }
}

// MARK: - 枚举
enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide = "超广角"
    case wide = "广角"
    case telephoto = "长焦"
    case front = "前置"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .ultraWide: return "0.5"
        case .wide: return "1"
        case .telephoto: return "2"
        case .front: return "前置"
        }
    }
}

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd720 = "720P"
    case hd1080 = "1080P"
    case uhd4K = "4K"
    var id: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        case .uhd4K: return .hd4K3840x2160
        }
    }
}

enum FrameRateOption: Int, CaseIterable, Identifiable {
    case fps24 = 24, fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

enum StabilizationLevel: String, CaseIterable, Identifiable {
    case off = "关闭"
    case standard = "标准"
    case cinematic = "影院级"
    case auto = "自动"
    var id: String { rawValue }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .auto: return .auto
        }
    }
}

enum PreRecordOption: String, CaseIterable, Identifiable {
    case s5 = "5秒"
    case s15 = "15秒"
    case s30 = "30秒"
    case s60 = "1分钟"
    case s120 = "2分钟"
    case off = "关闭"
    var id: String { rawValue }
    var seconds: Int {
        switch self {
        case .off: return 0
        case .s5: return 5
        case .s15: return 15
        case .s30: return 30
        case .s60: return 60
        case .s120: return 120
        }
    }
}

enum ScreenOffOption: String, CaseIterable, Identifiable {
    case s5 = "5秒"
    case s15 = "15秒"
    case s30 = "30秒"
    case s60 = "1分钟"
    case s300 = "5分钟"
    case never = "永不息屏"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .s5: return 5
        case .s15: return 15
        case .s30: return 30
        case .s60: return 60
        case .s300: return 300
        case .never: return 0
        }
    }
}

enum VideoOrientationOption: String, CaseIterable, Identifiable {
    case portrait = "竖屏"
    case landscapeRight = "横屏(右)"
    case landscapeLeft = "横屏(左)"
    var id: String { rawValue }
    var av: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case fullScreen = "全屏"
    case fit = "适应"
    var id: String { rawValue }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fullScreen: return .resizeAspectFill
        case .fit: return .resizeAspect
        }
    }
}

// MARK: - 环形缓冲（线程安全）
final class RingBuffer<T> {
    private var items: [T?]
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int
    private let lock = NSLock()
    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.items = Array(repeating: nil, count: self.capacity)
    }
    func append(_ e: T) {
        lock.lock(); defer { lock.unlock() }
        items[writeIndex] = e
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }
    func snapshot() -> [T] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        var r: [T] = []
        r.reserveCapacity(count)
        let start = count < capacity ? 0 : writeIndex
        for o in 0..<count {
            if let e = items[(start + o) % capacity] { r.append(e) }
        }
        return r
    }
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}

// MARK: - H.264 硬编码器
final class H264Encoder {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    var onSample: ((CMSampleBuffer) -> Void)?
    private var configuredSize = CGSize.zero

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        let w = width % 2 == 0 ? width : width + 1
        let h = height % 2 == 0 ? height : height + 1
        if let s = session, configuredSize == CGSize(width: w, height: h) { return }
        if let old = session { session = nil; VTCompressionSessionInvalidate(old) }
        var ns: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(w), height: Int32(h),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, _, st, _, sb in
                guard st == noErr, let s = sb, let r = refcon else { return }
                Unmanaged<H264Encoder>.fromOpaque(r).takeUnretainedValue().onSample?(s)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &ns)
        guard status == noErr, let s = ns else {
            Log.write("[Encoder] create failed st=\(status) \(w)x\(h)")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(fps, 15)))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        configuredSize = CGSize(width: w, height: h)
        Log.write("[Encoder] configured \(w)x\(h) fps=\(fps)")
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool) {
        lock.lock(); let s = session; lock.unlock()
        guard let session = s else { return }
        var props: [String: Any] = [:]
        if forceKeyframe { props[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: time, duration: .invalid,
            frameProperties: props.isEmpty ? nil : props as CFDictionary,
            sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        if let s = session { session = nil; VTCompressionSessionInvalidate(s) }
        configuredSize = .zero
    }
}

// MARK: - 提示音（合成，走扬声器）
final class SoundPlayer {
    private var cache: [String: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "com.fishing.camera.sound")
    private lazy var startData = Self.makeBeepData(pattern: [(0.015, 0.09), (0.145, 0.09), (0.275, 0.20)])
    private lazy var stopData = Self.makeBeepData(pattern: [(0.015, 0.22)])

    func playStart() { play(startData) }
    func playStop() { play(stopData) }

    private func play(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let p = try? AVAudioPlayer(data: data) else { return }
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            self.cache["last"] = p
        }
    }

    private static func makeBeepData(pattern: [(Double, Double)]) -> Data {
        let sr = 44100, freq = 880.0, amp = 29000.0
        let total = Int(0.6 * Double(sr))
        var pcm = [Int16](repeating: 0, count: total)
        for (off, dur) in pattern {
            let start = Int(off * Double(sr))
            let cnt = Int(dur * Double(sr))
            for i in 0..<cnt {
                let idx = start + i
                if idx >= total { break }
                let t = Double(i) / Double(sr)
                let env = exp(-t * 20.0)
                pcm[idx] = Int16(sin(2 * Double.pi * freq * t) * amp * env)
            }
        }
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        var sz = UInt32(36 + total * 2); d.append(Data(bytes: &sz, count: 4))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        var sub = UInt32(16); d.append(Data(bytes: &sub, count: 4))
        var fmt = UInt16(1); d.append(Data(bytes: &fmt, count: 2))
        var ch = UInt16(1); d.append(Data(bytes: &ch, count: 2))
        var rate = UInt32(sr); d.append(Data(bytes: &rate, count: 4))
        var bytes = UInt32(sr * 2); d.append(Data(bytes: &bytes, count: 4))
        var align = UInt16(2); d.append(Data(bytes: &align, count: 2))
        var bits = UInt16(16); d.append(Data(bytes: &bits, count: 2))
        d.append(contentsOf: Array("data".utf8))
        var dsz = UInt32(total * 2); d.append(Data(bytes: &dsz, count: 4))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

// MARK: - 影片写入器（预录帧 + 实时帧）
// 采用 realtime=true（与之前能正常出片的版本一致）+ isReadyForMoreMediaData 守卫：
// 绝不盲目 append（未就绪时 append 会阻塞/抛异常 → 卡死或闪退），全部在写入器自己的串行队列上执行。
final class MovieWriter {
    private let queue = DispatchQueue(label: "com.fishing.camera.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var active = false
    private var videoAppended = 0
    private var outputURL: URL?
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid

    func start(video: [CMSampleBuffer], audio: [CMSampleBuffer],
               url: URL, transform: CGAffineTransform?, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion(false) }; return }
            // 上一段若意外未收尾，直接取消，避免"第二次点不动/卡死"
            if self.active {
                Log.write("[Writer] 发现未收尾的上一段，强制取消")
                self.writer?.cancelWriting()
                self.cleanup()
            }
            guard let first = video.first, let vHint = CMSampleBufferGetFormatDescription(first) else {
                Log.write("[Writer] 无视频帧/格式，无法开始")
                DispatchQueue.main.async { completion(false) }; return
            }
            let startTime = CMSampleBufferGetPresentationTimeStamp(first)
            do {
                if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
                let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vHint)
                vIn.expectsMediaDataInRealTime = true
                if let t = transform { vIn.transform = t }
                guard w.canAdd(vIn) else {
                    Log.write("[Writer] 无法添加视频轨")
                    DispatchQueue.main.async { completion(false) }; return
                }
                w.add(vIn)

                // 预录音频只保留不早于视频起点的部分，避免 PTS 早于 startSession 被丢弃/写坏
                let aValid = audio.filter { CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), startTime) >= 0 }
                let aSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 128000]
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings,
                                             sourceFormatHint: aValid.first.flatMap { CMSampleBufferGetFormatDescription($0) })
                aIn.expectsMediaDataInRealTime = true
                let hasAudio = w.canAdd(aIn)
                if hasAudio { w.add(aIn) }

                guard w.startWriting() else {
                    Log.write("[Writer] startWriting 失败 \(w.error?.localizedDescription ?? "")")
                    DispatchQueue.main.async { completion(false) }; return
                }
                w.startSession(atSourceTime: startTime)

                self.writer = w
                self.videoInput = vIn
                self.audioInput = hasAudio ? aIn : nil
                self.outputURL = url
                self.videoAppended = 0
                self.lastVideoPTS = startTime
                self.lastAudioPTS = .invalid
                self.active = true

                self.writeBulk(video: video, audio: aValid)
                Log.write("[Writer] 开始 预录v=\(video.count) a=\(aValid.count) 音频=\(hasAudio) 已写=\(self.videoAppended)")
                // 只要 writer 启动成功就算成功；能否出帧交由 finish 判断
                DispatchQueue.main.async { completion(true) }
            } catch {
                Log.write("[Writer] 异常 \(error)")
                self.cleanup()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // 按 PTS 交错写入预录帧；未就绪则短暂等待重试，不静默丢帧
    private func writeBulk(video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
        guard let vIn = videoInput else { return }
        var vi = 0, ai = 0
        let deadline = Date().addingTimeInterval(20)
        while (vi < video.count || ai < audio.count) && Date() < deadline {
            let takeVideo: Bool
            if ai >= audio.count { takeVideo = true }
            else if vi >= video.count { takeVideo = false }
            else {
                takeVideo = CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(video[vi]),
                                          CMSampleBufferGetPresentationTimeStamp(audio[ai])) <= 0
            }
            if takeVideo {
                if vIn.isReadyForMoreMediaData {
                    let p = CMSampleBufferGetPresentationTimeStamp(video[vi])
                    if vIn.append(video[vi]) { videoAppended += 1; lastVideoPTS = p }
                    vi += 1
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            } else if let aIn = audioInput {
                if aIn.isReadyForMoreMediaData {
                    let p = CMSampleBufferGetPresentationTimeStamp(audio[ai])
                    if aIn.append(audio[ai]) { lastAudioPTS = p }
                    ai += 1
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            } else {
                ai += 1
            }
        }
    }

    func appendVideo(_ s: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active, let vIn = self.videoInput,
                  let w = self.writer, w.status == .writing else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(s)
            // PTS 必须单调递增，否则 AVAssetWriter 会写入失败甚至抛异常
            if self.lastVideoPTS.isValid && CMTimeCompare(pts, self.lastVideoPTS) <= 0 { return }
            // 未就绪时不盲目 append（会阻塞/抛异常），本帧丢弃
            guard vIn.isReadyForMoreMediaData else { return }
            self.lastVideoPTS = pts
            if vIn.append(s) { self.videoAppended += 1 }
        }
    }
    func appendAudio(_ s: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active, let aIn = self.audioInput,
                  let w = self.writer, w.status == .writing else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(s)
            if self.lastAudioPTS.isValid && CMTimeCompare(pts, self.lastAudioPTS) <= 0 { return }
            guard aIn.isReadyForMoreMediaData else { return }
            self.lastAudioPTS = pts
            _ = aIn.append(s)
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.active, let w = self.writer else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            self.active = false
            let url = self.outputURL
            if self.videoAppended == 0 {
                Log.write("[Writer] 无有效帧，取消写入")
                w.cancelWriting()
                self.cleanup()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let frames = self.videoAppended
            w.finishWriting {
                let ok = (w.status == .completed)
                Log.write("[Writer] 完成 ok=\(ok) status=\(w.status.rawValue) 帧=\(frames) \(w.error?.localizedDescription ?? "")")
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
            self.cleanup()
        }
    }

    private func cleanup() {
        writer = nil; videoInput = nil; audioInput = nil
        outputURL = nil; videoAppended = 0; active = false
        lastVideoPTS = .invalid; lastAudioPTS = .invalid
    }
}

// MARK: - 语音控制
final class VoiceCommandManager {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onListeningChanged: ((Bool) -> Void)?

    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private let lock = NSLock()
    private var lastStart: TimeInterval = 0
    private var lastStop: TimeInterval = 0
    /// 优先离线识别，失败后回退在线识别
    private var useOnDevice = true

    var startWords: [String] = ["开始录像", "开始录制", "开始拍摄", "录一下", "开始"]
    var stopWords: [String] = ["停止录像", "结束录像", "停止录制", "结束录制", "停止拍摄", "停止", "保存"]

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            guard let self = self else { return }
            guard st == .authorized else {
                Log.write("[Voice] 未授权 \(st.rawValue)")
                return
            }
            DispatchQueue.main.async { self.begin() }
        }
    }

    func stop() {
        lock.lock()
        running = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        lock.unlock()
        onListeningChanged?(false)
    }

    /// 首次启动：置位 running 后建立识别任务
    private func begin() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        startTask()
    }

    /// 建立/重建一次识别任务；restart 复用（绕过 running 守卫，这是之前语音只在第一次生效的根因）
    private func startTask() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        let supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        if supportsOnDevice && useOnDevice { r.requiresOnDeviceRecognition = true }
        request = r
        lock.unlock()
        onListeningChanged?(true)
        if recognizer == nil { Log.write("[Voice] 识别器不可用(zh-CN)") }
        task = recognizer?.recognitionTask(with: r) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { Log.write("[Voice] 听到: \(text)") }
                self.handle(text)
                if result.isFinal { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.restart() } }
            } else if let error = error {
                Log.write("[Voice] 识别错误: \(error.localizedDescription)")
                // 离线识别失败（模型未下载等）→ 回退在线识别
                if supportsOnDevice { self.useOnDevice = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restart() }
            }
        }
    }

    private func restart() {
        guard running else { return }
        lock.lock()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.running else { return }
            self.startTask()
        }
    }

    private func handle(_ text: String) {
        let now = Date().timeIntervalSince1970
        // 去掉空格与常见标点，避免"开始 录像。""被识别成带间隔的文本匹配不上
        let t = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
        if startWords.contains(where: { t.contains($0) }) {
            if now - lastStart > 3 {
                lastStart = now
                Log.write("[Voice] 触发开始录像")
                DispatchQueue.main.async { [weak self] in self?.onStart?() }
            }
        } else if stopWords.contains(where: { t.contains($0) }) {
            if now - lastStop > 3 {
                lastStop = now
                Log.write("[Voice] 触发停止录像")
                DispatchQueue.main.async { [weak self] in self?.onStop?() }
            }
        }
    }

    func feed(_ sb: CMSampleBuffer) {
        lock.lock(); let r = request; lock.unlock()
        guard running, let req = r, let pcm = sb.toPCMBuffer() else { return }
        if let mono = Self.resample16k(pcm) { req.append(mono) }
    }

    private static func resample16k(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if Int(src.format.sampleRate) == 16000 && src.format.channelCount == 1 { return src }
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src.format, to: dst) else { return nil }
        let ratio = 16000.0 / src.format.sampleRate
        let cap = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return nil }
        var fed = false
        var attempts = 0
        while attempts < 8 {
            attempts += 1
            var err: NSError?
            let st = conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return src
            }
            if st == .error { return nil }
            if st == .endOfStream { break }
            if st == .haveData && out.frameLength > 0 { break }
        }
        return out.frameLength > 0 ? out : nil
    }
}

// MARK: - 电池
final class BatteryMonitor {
    private var timer: Timer?
    func start(_ cb: @escaping (Float) -> Void) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        cb(max(UIDevice.current.batteryLevel, 0))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            cb(max(UIDevice.current.batteryLevel, 0))
        }
    }
}

// MARK: - 水平仪
final class MotionManager: ObservableObject {
    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false
    private let motion = CMMotionManager()
    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self = self, let dm = dm else { return }
            self.roll = dm.attitude.roll
            self.pitch = dm.attitude.pitch
            self.isLevel = abs(dm.attitude.roll) < 0.03
        }
    }
    func stop() { motion.stopDeviceMotionUpdates() }
}

// MARK: - 相机引擎
final class CameraEngine: NSObject, ObservableObject {
    // 输出状态
    @Published var isRecording = false
    @Published var isPreRecording = false      // 预录是否在工作
    @Published var recordSeconds = 0
    @Published var voiceListening = false
    @Published var battery: Float = 1
    @Published var status: String?
    @Published var torchOn = false
    @Published var screenOff = false

    // 设置
    @Published var lens: CameraLens = .wide { didSet { if oldValue != lens { switchLens() } } }
    @Published var resolution: VideoResolution = .hd1080 { didSet { if oldValue != resolution { reconfigure() } } }
    @Published var frameRate: FrameRateOption = .fps30 { didSet { if oldValue != frameRate { applyFrameRate() } } }
    @Published var stabilization: StabilizationLevel = .auto { didSet { if oldValue != stabilization { applyStabilization() } } }
    @Published var preRecord: PreRecordOption = .s30 { didSet { if oldValue != preRecord { stateLock.lock(); _preRecordFlag = preRecord.seconds > 0; stateLock.unlock(); rebuildBuffers(); updatePreRecordState() } } }
    @Published var screenOffOption: ScreenOffOption = .never { didSet { resetScreenOffTimer() } }
    @Published var orientation: VideoOrientationOption = .portrait { didSet { applyOrientation() } }
    @Published var previewMode: PreviewMode = .fullScreen
    @Published var mirror = false { didSet { applyOrientation() } }
    @Published var showGrid = false
    @Published var showLevel = false
    @Published var shutterSound = true
    @Published var flashReminder = false
    @Published var voiceEnabled = false { didSet { if oldValue != voiceEnabled { stateLock.lock(); _voiceFlag = voiceEnabled; stateLock.unlock(); voiceEnabled ? startVoice() : stopVoice() } } }
    @Published var startWords: [String] = ["开始录像", "开始录制", "开始拍摄", "录一下"]
    @Published var stopWords: [String] = ["停止录像", "结束录像", "停止录制", "保存"]
    @Published var debugOverlay = true
    @Published var debugText = ""
    @Published var logPanel = false

    let session = AVCaptureSession()
    let motion = MotionManager()
    private let sessionQueue = DispatchQueue(label: "com.fishing.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let encoder = H264Encoder()
    private let writer = MovieWriter()
    private let sound = SoundPlayer()
    private let voice = VoiceCommandManager()
    private let batteryMonitor = BatteryMonitor()

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInputDevice: AVCaptureDeviceInput?

    private var videoRing: RingBuffer<CMSampleBuffer>?
    private var audioRing: RingBuffer<CMSampleBuffer>?
    private var encoderSize: CGSize = .zero
    private var frameCount = 0
    private var encodedFrameCount = 0

    // 跨线程共享标志（统一由 stateLock 保护）
    private let stateLock = NSLock()
    private var _recording = false
    private var _starting = false
    private var _live = false
    private var _preRecordFlag = true
    private var _voiceFlag = false
    private var _pending = false
    private var isConfigured = false
    private var screenOffTimer: Timer?
    private var recordTimer: Timer?
    private var logTimer: Timer?

    private var recordingFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _recording }
    private var preRecordFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _preRecordFlag }
    private var voiceFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _voiceFlag }
    private var pendingFlag: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _pending }
    private func clearPending() { stateLock.lock(); _pending = false; stateLock.unlock() }
    /// 录制启动失败时复位状态，避免卡在"假录制"
    private func resetRecordingState() {
        stateLock.lock(); _recording = false; _starting = false; _live = false; _pending = false; stateLock.unlock()
        DispatchQueue.main.async {
            self.isRecording = false
            self.stopRecordTimer()
        }
    }

    // MARK: 生命周期
    func prepare() {
        let ases = AVAudioSession.sharedInstance()
        try? ases.setCategory(.playAndRecord, mode: .default,
                              options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? ases.setActive(true)
        motion.start()
        // 提前请求相册写入权限，避免录制完才发现无法保存
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.debugOverlay || self.logPanel else { return }
            let info = "编码:\(self.encodedFrameCount) 缓冲:\(self.videoRing?.count ?? 0) "
                + "录制:\(self.isRecording ? "Y" : "N") 状态:\(self._live ? "live" : (self._starting ? "starting" : "-"))"
            let t = info + "\n" + LogBuffer.text()
            DispatchQueue.main.async { self.debugText = t }
        }
        batteryMonitor.start { [weak self] lvl in
            DispatchQueue.main.async { self?.battery = lvl }
        }
        sessionQueue.async { [weak self] in self?.configureSession() }
        encoder.onSample = { [weak self] sb in self?.handleEncoded(sb) }
        voice.onListeningChanged = { [weak self] on in DispatchQueue.main.async { self?.voiceListening = on } }
        voice.onStart = { [weak self] in
            guard let self = self else { return }
            if !self.isRecording { self.startRecording() }
        }
        voice.onStop = { [weak self] in
            guard let self = self else { return }
            if self.isRecording { self.stopRecording() }
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }
        isConfigured = true
        session.beginConfiguration()
        if session.canSetSessionPreset(resolution.preset) { session.sessionPreset = resolution.preset }

        if let dev = deviceFor(lens),
           let input = try? AVCaptureDeviceInput(device: dev),
           session.canAddInput(input) {
            session.addInput(input)
            videoDevice = dev
            videoInput = input
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let aIn = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(aIn) {
            session.addInput(aIn)
            audioInputDevice = aIn
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        applyOrientationLocked()
        applyStabilizationLocked()
        session.commitConfiguration()

        rebuildBuffers()
        applyFrameRateLocked()
        session.startRunning()
        updatePreRecordState()
        Log.write("[Session] 启动 preset=\(resolution.rawValue) lens=\(lens.rawValue)")
    }

    private func deviceFor(_ l: CameraLens) -> AVCaptureDevice? {
        switch l {
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .wide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .telephoto:
            return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    func switchLens() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.recordingFlag { Log.write("[Lens] 录制中不切换镜头"); return }
            self.videoRing?.removeAll(); self.audioRing?.removeAll()
            guard let dev = self.deviceFor(self.lens),
                  let newInput = try? AVCaptureDeviceInput(device: dev) else { return }
            if self.lens == .front, self.videoDevice?.position == .back, self.torchOn { self.setTorchLocked(false) }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.videoDevice = dev
            } else if let old = self.videoInput {
                self.session.addInput(old)
            }
            self.applyOrientationLocked()
            self.applyStabilizationLocked()
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.torchOn = false }
        }
    }

    private func reconfigure() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.recordingFlag { Log.write("[Session] 录制中不切换分辨率"); return }
            self.videoRing?.removeAll(); self.audioRing?.removeAll()
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(self.resolution.preset) {
                self.session.sessionPreset = self.resolution.preset
            }
            self.session.commitConfiguration()
            self.applyFrameRateLocked()
            Log.write("[Session] 分辨率切换 \(self.resolution.rawValue)")
        }
    }

    func applyFrameRate() { sessionQueue.async { [weak self] in self?.applyFrameRateLocked() } }
    private func applyFrameRateLocked() {
        guard let dev = videoDevice else { return }
        let fps = Double(frameRate.rawValue)
        do {
            try dev.lockForConfiguration()
            let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
            var best: AVCaptureDevice.Format?
            for f in dev.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let target = targetDimensions()
                guard Int(dims.width) >= target.width, Int(dims.height) >= target.height else { continue }
                let ranges = f.videoSupportedFrameRateRanges
                if ranges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) {
                    if best == nil { best = f }
                }
            }
            if let f = best { dev.activeFormat = f }
            if fps >= 1 { dev.activeVideoMinFrameDuration = dur; dev.activeVideoMaxFrameDuration = dur }
            dev.unlockForConfiguration()
        } catch { Log.write("[Session] 帧率设置失败 \(error)") }
    }

    private func targetDimensions() -> (width: Int, height: Int) {
        switch resolution {
        case .hd720: return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }

    func applyStabilization() { sessionQueue.async { [weak self] in self?.applyStabilizationLocked() } }
    private func applyStabilizationLocked() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        if conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = stabilization.mode
        }
    }

    func applyOrientation() { sessionQueue.async { [weak self] in self?.applyOrientationLocked() } }
    private func applyOrientationLocked() {
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = orientation.av }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (lens == .front) ? !mirror : mirror }
        }
    }

    // MARK: 预录缓冲
    private func rebuildBuffers() {
        let sec = preRecord.seconds
        let fps = max(Double(frameRate.rawValue), 15)
        // 关闭预录时仍保留 2 秒，保证开始录制时能立即拿到关键帧与编码参数
        let cap = max(sec, 2)
        videoRing = RingBuffer(capacity: Int(fps * Double(cap)))
        audioRing = RingBuffer(capacity: Int(50 * Double(cap)))
        Log.write("[PreRecord] 缓冲 \(cap)s video=\(Int(fps * Double(cap))) audio=\(Int(50 * Double(cap)))")
    }

    private func updatePreRecordState() {
        DispatchQueue.main.async { self.isPreRecording = self.preRecord.seconds > 0 }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        encodedFrameCount += 1
        if preRecordFlag { videoRing?.append(sb) }
        // 缓冲为空时按下录制：等第一个关键帧再建 writer。
        // 必须先于 recordingFlag 判断，否则 writer 永远建不起来（假录制）
        if pendingFlag {
            guard sb.isKeyFrame else { return }
            clearPending()
            let startPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            let a = (audioRing?.snapshot() ?? []).filter {
                CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), startPTS) >= 0
            }
            startWriter(video: [sb], audio: a)
            return
        }
        if recordingFlag { writer.appendVideo(sb) }
    }

    /// 统一启动写入器；失败时复位录制状态，避免卡死
    private func startWriter(video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
        guard recordingFlag else {
            Log.write("[Record] 录制已被取消，忽略启动")
            resetRecordingState()
            return
        }
        guard !video.isEmpty else {
            resetRecordingState(); showStatus("录像启动失败：无画面")
            return
        }
        let url = makeURL()
        let t = transformForWriter()
        writer.start(video: video, audio: audio, url: url, transform: t) { [weak self] ok in
            guard let self = self else { return }
            self.stateLock.lock()
            self._starting = false
            let stillWanted = self._recording
            if ok && stillWanted { self._live = true }
            self.stateLock.unlock()
            Log.write("[Record] writer 启动 ok=\(ok) v=\(video.count) a=\(audio.count)")
            if !ok && stillWanted { self.resetRecordingState(); self.showStatus("录像启动失败") }
        }
    }

    // MARK: 录制
    func startRecording() {
        stateLock.lock()
        if _recording || _starting { stateLock.unlock(); return }
        _recording = true
        _starting = true
        _live = false
        stateLock.unlock()

        resetScreenOffTimer()
        if shutterSound { sound.playStart() }
        if flashReminder { flash() }

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordSeconds = 0
            self.startRecordTimer()
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.recordingFlag else { return }
            let vAll = self.videoRing?.snapshot() ?? []
            let aAll = self.audioRing?.snapshot() ?? []
            let v = self.preRecordFlag ? self.trimToFirstKeyframe(vAll) : self.trimToLastKeyframe(vAll)
            let startPTS = v.first.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? .zero
            let a = aAll.filter { CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), startPTS) >= 0 }

            if v.isEmpty {
                // 还没有可用帧（刚启动）：等第一帧关键帧到来后再建 writer
                self.stateLock.lock()
                if self._recording { self._pending = true }
                self.stateLock.unlock()
                Log.write("[Record] 暂无缓冲帧，等待首帧关键帧")
                return
            }
            self.startWriter(video: v, audio: a)
        }
    }

    func stopRecording() {
        stateLock.lock()
        let wasActive = _recording || _starting
        let live = _live
        _recording = false
        _starting = false
        _live = false
        _pending = false
        stateLock.unlock()
        guard wasActive else { return }

        if shutterSound { sound.playStop() }
        DispatchQueue.main.async {
            self.isRecording = false
            self.stopRecordTimer()
        }
        resetScreenOffTimer()

        writer.finish { url in
            guard let url = url else {
                if live { DispatchQueue.main.async { self.showStatus("保存失败") } }
                return
            }
            PhotoLibrary.save(url) { ok in
                DispatchQueue.main.async {
                    self.showStatus(ok ? "已保存到相册 · \(self.recordSeconds)秒" : "保存失败")
                }
            }
        }
    }

    private func trimToFirstKeyframe(_ arr: [CMSampleBuffer]) -> [CMSampleBuffer] {
        guard let idx = arr.firstIndex(where: { $0.isKeyFrame }) else { return [] }
        return Array(arr[idx...])
    }
    private func trimToLastKeyframe(_ arr: [CMSampleBuffer]) -> [CMSampleBuffer] {
        guard let idx = arr.lastIndex(where: { $0.isKeyFrame }) else { return [] }
        return Array(arr[idx...])
    }

    private var recordSeq = 0
    private func makeURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        recordSeq += 1
        return dir.appendingPathComponent("Fishing_\(f.string(from: Date()))_\(recordSeq).mp4")
    }

    private func transformForWriter() -> CGAffineTransform {
        if lens == .front && mirror {
            var t = CGAffineTransform(scaleX: -1, y: 1)
            t = t.translatedBy(x: -1, y: 0)
            return t
        }
        return .identity
    }

    private func flash() {
        sessionQueue.async { [weak self] in
            guard let self = self, let dev = self.videoDevice,
                  dev.hasTorch, dev.isTorchModeSupported(.on) else { return }
            try? dev.lockForConfiguration()
            dev.torchMode = .on
            dev.unlockForConfiguration()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.setTorchLocked(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.setTorchLocked(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.setTorchLocked(false) }
                }
            }
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let next = !self.torchOn
            self.setTorchLocked(next)
            DispatchQueue.main.async { self.torchOn = next }
        }
    }
    private func setTorchLocked(_ on: Bool) {
        guard let dev = videoDevice, dev.hasTorch, dev.isTorchModeSupported(on ? .on : .off) else { return }
        try? dev.lockForConfiguration()
        dev.torchMode = on ? .on : .off
        dev.unlockForConfiguration()
    }

    // MARK: 计时器 / 状态
    private func startRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordSeconds += 1
            self.resetScreenOffTimer()
        }
    }
    private func stopRecordTimer() { recordTimer?.invalidate(); recordTimer = nil }

    private func showStatus(_ s: String) {
        DispatchQueue.main.async {
            self.status = s
            if s.contains("失败") || s.contains("错误") {
                self.logPanel = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.logPanel = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.status == s { self?.status = nil }
            }
        }
    }

    func resetScreenOffTimer() {
        screenOffTimer?.invalidate()
        let sec = screenOffOption.seconds
        guard sec > 0 else { return }
        screenOffTimer = Timer.scheduledTimer(withTimeInterval: sec, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.screenOff = true }
        }
    }
    func wakeScreen() { screenOff = false; resetScreenOffTimer() }

    // MARK: 语音
    private func startVoice() {
        voice.startWords = startWords
        voice.stopWords = stopWords
        voice.start()
    }
    private func stopVoice() { voice.stop() }

    func setVoiceWords(start: [String], stop: [String]) {
        startWords = start; stopWords = stop
        voice.startWords = start; voice.stopWords = stop
    }

    func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

// MARK: - 采集回调
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if encoderSize != CGSize(width: w, height: h) {
            encoderSize = CGSize(width: w, height: h)
            // 帧格式变化（切换分辨率/镜头）：清空预录缓冲，避免新旧格式帧写入同一文件导致崩溃
            videoRing?.removeAll()
            audioRing?.removeAll()
            let bitrate = max(w * h * 2, 4_000_000)
            encoder.configure(width: w, height: h, fps: frameRate.rawValue, bitrate: bitrate)
            frameCount = 0
            if recordingFlag {
                Log.write("[Video] 录制中画面尺寸变化，停止当前录制避免文件损坏")
                DispatchQueue.main.async { self.stopRecording() }
                return
            }
        }
        // 始终编码：预录需要持续缓冲，且能在按下录制时立即拿到关键帧与编码参数
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // 每秒强制一个关键帧，保证预录起点可解码
        let force = frameCount % max(frameRate.rawValue, 15) == 0
        encoder.encode(pb, at: pts, forceKeyframe: force)
        frameCount += 1
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        if preRecordFlag { audioRing?.append(sb) }
        if recordingFlag { writer.appendAudio(sb) }
        if voiceFlag { voice.feed(sb) }
    }
}

// MARK: - CMSampleBuffer 工具
extension CMSampleBuffer {
    var isKeyFrame: Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let a = arr.first else { return true }
        return !(a[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fmt = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        let frames = CMSampleBufferGetNumSamples(self)
        guard frames > 0, let format = AVAudioFormat(streamDescription: asbd),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames),
                                                           into: buf.mutableAudioBufferList) == noErr else { return nil }
        return buf
    }
}

// MARK: - 保存相册
enum PhotoLibrary {
    static func save(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.write("[Photos] 文件不存在 \(url.lastPathComponent)")
            completion(false); return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Log.write("[Photos] 无相册权限 st=\(st.rawValue)")
                completion(false); return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, err in
                if let err = err { Log.write("[Photos] 保存出错 \(err.localizedDescription)") }
                else { Log.write("[Photos] 保存\(ok ? "成功" : "失败")") }
                completion(ok)
            }
        }
    }
}

// MARK: - 预览视图
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let gravity: AVLayerVideoGravity
    let orientation: AVCaptureVideoOrientation
    let mirrored: Bool
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = gravity
        update(v)
        return v
    }
    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.previewLayer.videoGravity = gravity
        update(v)
    }
    private func update(_ v: PreviewUIView) {
        guard let c = v.previewLayer.connection else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = orientation }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirrored
        }
    }
}
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 音量键（iOS 17.2+）
struct VolumeButtonModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 17.2, *) {
            content.background(VolumeBtn(action: action))
        } else { content }
    }
}
@available(iOS 17.2, *)
private struct VolumeBtn: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.isUserInteractionEnabled = false
        if let cls = NSClassFromString("AVCaptureEventInteraction") as? NSObject.Type {
            let sel = NSSelectorFromString("initWithHandler:")
            if cls.responds(to: sel) {
                let handler: @convention(block) (AnyObject) -> Void = { e in
                    // 用 responds(to:) 先探测，避免 value(forKey:) 抛 NSUnknownKeyException 崩溃
                    guard let obj = e as? NSObject,
                          obj.responds(to: NSSelectorFromString("phase")) else { return }
                    if let phase = obj.value(forKey: "phase") as? Int, phase == 2 {
                        DispatchQueue.main.async { action() }
                    }
                }
                if let i = cls.perform(sel, with: handler)?.takeUnretainedValue() as? UIInteraction {
                    v.addInteraction(i)
                }
            }
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
extension View {
    func onVolumeButton(_ a: @escaping () -> Void) -> some View {
        modifier(VolumeButtonModifier(action: a))
    }
}

// MARK: - 通用控件
struct GlassPill: View {
    let text: String
    var color: Color = .white
    var body: some View {
        Text(text)
            .font(Design.mono(11))
            .foregroundColor(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Design.glassBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Design.glassBorder, lineWidth: 0.5))
    }
}

struct CircleIconButton: View {
    let icon: String
    var active: Bool = false
    var activeColor: Color = Design.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(active ? activeColor : .white)
                .frame(width: 44, height: 44)
                .background(Design.glassBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(active ? activeColor.opacity(0.6) : Design.glassBorder, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                for i in 1..<3 {
                    let x = w * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.32), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }
    }
}

struct LevelOverlay: View {
    @ObservedObject var motion: MotionManager
    var body: some View {
        ZStack {
            Circle().stroke(motion.isLevel ? Design.accent : Design.warm, lineWidth: 1.5)
                .frame(width: 54, height: 54)
            Rectangle().fill(motion.isLevel ? Design.accent : Design.warm)
                .frame(width: 34, height: 1)
                .offset(x: CGFloat(motion.roll * 100))
            Rectangle().fill(motion.isLevel ? Design.accent : Design.warm)
                .frame(width: 1, height: 34)
                .offset(y: CGFloat(motion.pitch * 100))
            Circle().fill(motion.isLevel ? Design.accent : Design.warm).frame(width: 5, height: 5)
        }
        .opacity(0.85)
    }
}

// MARK: - 相机主界面
struct CameraScreen: View {
    @ObservedObject var engine: CameraEngine
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session,
                          gravity: engine.previewMode.gravity,
                          orientation: engine.orientation.av,
                          mirrored: engine.lens == .front ? !engine.mirror : engine.mirror)
                .ignoresSafeArea()

            if engine.showGrid { GridOverlay().ignoresSafeArea() }

            VStack {
                topBar
                Spacer()
                if engine.showLevel {
                    LevelOverlay(motion: engine.motion).padding(.bottom, 12)
                }
                bottomBar
            }

            if let s = engine.status {
                VStack {
                    Spacer()
                    Text(s)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                        .padding(.bottom, 150)
                    Spacer()
                }
                .transition(.opacity)
            }

            if engine.debugOverlay || engine.logPanel {
                VStack {
                    Spacer()
                    Text(engine.debugText.isEmpty ? "日志…" : engine.debugText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0.55, green: 1.0, blue: 0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.62))
                        .cornerRadius(8)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 132)
                }
                .allowsHitTesting(false)
            }

            if engine.screenOff {
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                        // 上滑唤醒（向上滑动距离大于 50 且以纵向为主）
                        if v.translation.height < -50 && abs(v.translation.height) > abs(v.translation.width) {
                            engine.wakeScreen()
                        }
                    })
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "chevron.up.2").font(.system(size: 26)).foregroundColor(.white.opacity(0.5))
                            Text("熄屏省电中 · 上滑唤醒").font(.system(size: 13)).foregroundColor(.white.opacity(0.5))
                        }
                    )
            }
        }
        .onVolumeButton { engine.isRecording ? engine.stopRecording() : engine.startRecording() }
        .onAppear { engine.prepare() }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            GlassPill(text: "\(engine.resolution.rawValue) · \(engine.frameRate.rawValue)fps")
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.isPreRecording ? Design.accent : Color.white.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(engine.isPreRecording ? "预录中" : "未开预录")
                    .font(Design.mono(11))
                    .foregroundColor(engine.isPreRecording ? Design.accent : Color.white.opacity(0.6))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Design.glassBg).clipShape(Capsule())
            .overlay(Capsule().stroke(engine.isPreRecording ? Design.accent.opacity(0.6) : Design.glassBorder, lineWidth: 0.5))
            if engine.voiceListening {
                GlassPill(text: "🎙 语音", color: Design.accent)
            }
            if engine.torchOn {
                GlassPill(text: "🔦", color: Design.warm)
            }
            Spacer()
            GlassPill(text: "\(Int(engine.battery * 100))%")
            if engine.debugOverlay {
                GlassPill(text: engine.isRecording ? "REC \(engine.recordSeconds)s" : "IDLE", color: engine.isRecording ? Design.record : .white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            if engine.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(Design.record).frame(width: 9, height: 9)
                    Text(timeString(engine.recordSeconds))
                        .font(Design.mono(15)).foregroundColor(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.black.opacity(0.5)).clipShape(Capsule())
            }

            HStack {
                // 镜头
                Button(action: { cycleLens() }) {
                    Text(engine.lens.short)
                        .font(Design.mono(13))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(Design.glassBg).clipShape(Circle())
                        .overlay(Circle().stroke(Design.glassBorder, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // 录制
                Button(action: {
                    engine.isRecording ? engine.stopRecording() : engine.startRecording()
                }) {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                        if engine.isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(Design.record).frame(width: 32, height: 32)
                        } else {
                            Circle().fill(Design.record).frame(width: 62, height: 62)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // 相册
                Button(action: { engine.openPhotos() }) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(Design.glassBg).clipShape(Circle())
                        .overlay(Circle().stroke(Design.glassBorder, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 26)

            HStack(spacing: 24) {
                CircleIconButton(icon: engine.voiceEnabled ? "mic.fill" : "mic.slash", active: engine.voiceEnabled) {
                    engine.voiceEnabled.toggle()
                }
                CircleIconButton(icon: engine.torchOn ? "bolt.fill" : "bolt.slash", active: engine.torchOn) {
                    engine.toggleTorch()
                }
                CircleIconButton(icon: "arrow.triangle.2.circlepath.camera") {
                    cycleLens()
                }
                CircleIconButton(icon: "slider.horizontal.3") {
                    showSettings = true
                }
            }
            .padding(.bottom, 22)
        }
    }

    private func cycleLens() {
        let order: [CameraLens] = [.ultraWide, .wide, .telephoto, .front]
        if let i = order.firstIndex(of: engine.lens) { engine.lens = order[(i + 1) % order.count] }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 设置页
struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.presentationMode) var presentation
    @State private var startText = ""
    @State private var stopText = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("画面"), footer: engine.isRecording ? Text("录制中，画面参数暂不可调") : Text("")) {
                    Picker("镜头", selection: $engine.lens) {
                        ForEach(CameraLens.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("分辨率", selection: $engine.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("帧率", selection: $engine.frameRate) {
                        ForEach(FrameRateOption.allCases) { Text("\($0.rawValue) fps").tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("防抖", selection: $engine.stabilization) {
                        ForEach(StabilizationLevel.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("画面比例", selection: $engine.previewMode) {
                        ForEach(PreviewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("水平镜像", isOn: $engine.mirror).disabled(engine.isRecording)
                }

                Section(header: Text("预录（不错过精彩瞬间）")) {
                    Picker("预录时长", selection: $engine.preRecord) {
                        ForEach(PreRecordOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("开启后，相机持续缓存最近画面；按下录制时会把\"按下之前\"的画面一并保存。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }

                Section(header: Text("拍摄辅助")) {
                    Toggle("构图网格", isOn: $engine.showGrid)
                    Toggle("水平仪", isOn: $engine.showLevel)
                    Toggle("快门提示音", isOn: $engine.shutterSound)
                    Toggle("录制闪光提醒", isOn: $engine.flashReminder)
                }

                Section(header: Text("语音控制")) {
                    Toggle("语音控制录像", isOn: $engine.voiceEnabled)
                    HStack {
                        Text("开始口令")
                        Spacer()
                        Text(engine.startWords.joined(separator: " / "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    HStack {
                        Text("结束口令")
                        Spacer()
                        Text(engine.stopWords.joined(separator: " / "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    TextField("自定义：开始口令（用逗号分隔）", text: $startText)
                    TextField("自定义：结束口令（用逗号分隔）", text: $stopText)
                    Button("保存自定义口令") {
                        let s = startText.isEmpty ? engine.startWords : startText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        let e = stopText.isEmpty ? engine.stopWords : stopText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        engine.setVoiceWords(start: s, stop: e)
                    }
                }

                Section(header: Text("省电")) {
                    Picker("自动熄屏", selection: $engine.screenOffOption) {
                        ForEach(ScreenOffOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("熄屏后仍在后台录制，在屏幕上向上滑动可唤醒。")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }

                Section(header: Text("其它")) {
                    Picker("画面方向", selection: $engine.orientation) {
                        ForEach(VideoOrientationOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("显示调试信息", isOn: $engine.debugOverlay)
                }
            }
            .navigationBarTitle("设置", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") { presentation.wrappedValue.dismiss() })
        }
        .onAppear {
            startText = engine.startWords.joined(separator: ",")
            stopText = engine.stopWords.joined(separator: ",")
        }
    }
}

// MARK: - 入口
@main
struct FishingCameraApp: App {
    @StateObject private var engine = CameraEngine()
    var body: some Scene {
        WindowGroup {
            CameraScreen(engine: engine)
                .preferredColorScheme(.dark)
        }
    }
}
