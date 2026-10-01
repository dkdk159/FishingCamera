import SwiftUI
import AVFoundation
import Photos
import UIKit
import VideoToolbox
import AudioToolbox
import Speech
import CoreMedia

// MARK: - App 入口
@main
struct ActionCameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen().preferredColorScheme(.dark)
        }
    }
}

// MARK: - 枚举
enum CameraLens: String, CaseIterable {
    case ultraWide = "超广角"
    case wide      = "广角"
    case telephoto = "长焦"
    case frontWide = "前置"

    var position: AVCaptureDevice.Position { self == .frontWide ? .front : .back }
    var shortName: String {
        switch self {
        case .ultraWide: return "0.5×"
        case .wide: return "1×"
        case .telephoto: return "长焦"
        case .frontWide: return "前置"
        }
    }
}

enum StabilizationLevel: String, CaseIterable {
    case off = "关", standard = "标准", smooth = "平滑", enhanced = "增强", auto = "自动"
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .smooth: return .cinematic
        case .enhanced: return .cinematicExtended
        case .auto: return .auto
        }
    }
}

enum PreRecordOption: Int, CaseIterable {
    case off = 0, s5 = 5, s15 = 15, s30 = 30, s60 = 60, s120 = 120
    var label: String { rawValue == 0 ? "关" : "\(rawValue)秒" }
    var seconds: TimeInterval { Double(rawValue) }
}

/// 真实可用的分辨率档位（activeFormat 匹配，尺寸为传感器横向像素）
enum QualityOption: String, CaseIterable {
    case uhd4K169   = "4K 16:9"
    case uhd4K43    = "4K 4:3"
    case hd1080169  = "1080P 16:9"
    case hd108043   = "1080P 4:3"
    case hd720169   = "720P 16:9"
    case hd72043    = "720P 4:3"

    var targetWidth: Double {
        switch self {
        case .uhd4K169, .uhd4K43: return 3840
        case .hd1080169, .hd108043: return 1920
        case .hd720169, .hd72043: return 1280
        }
    }
    var targetHeight: Double {
        switch self {
        case .uhd4K169: return 2160
        case .uhd4K43: return 2880
        case .hd1080169: return 1080
        case .hd108043: return 1440
        case .hd720169: return 720
        case .hd72043: return 960
        }
    }
}

enum FrameRateOption: Int, CaseIterable {
    case auto = 0, f30 = 30, f60 = 60, f120 = 120, f240 = 240
    var label: String { rawValue == 0 ? "自动" : "\(rawValue)" }
}

// MARK: - 工具：在回调线程内复制 sample buffer（Apple 规定回调返回后即失效）
@inline(__always) func retainedCopy(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
    var copy: CMSampleBuffer?
    let st = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                      sampleBufferOut: &copy)
    return st == noErr ? copy : nil
}

func isKeyFrame(_ sb: CMSampleBuffer) -> Bool {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
        as? [[CFString: Any]], let a = arr.first else { return true }
    return !(a[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
}

// MARK: - 环形缓冲（线程安全；PTS 淘汰 + 字节预算防 OOM）
private struct TimedSample {
    let buffer: CMSampleBuffer
    let pts: CMTime
    let bytes: Int
}

final class SampleRingBuffer {
    private var items: [TimedSample] = []
    private var totalBytes = 0
    private let lock = NSLock()
    private let maxSeconds: Double
    private let maxBytes: Int

    /// maxBytes=0 表示不限字节数
    init(maxSeconds: Double, maxBytes: Int = 0) {
        self.maxSeconds = max(1, maxSeconds)
        self.maxBytes = maxBytes
    }

    func append(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        let bytes = max(Int(CMSampleBufferGetTotalSampleSize(sb)), 0)
        lock.lock(); defer { lock.unlock() }
        items.append(.init(buffer: sb, pts: pts, bytes: bytes))
        totalBytes += bytes
        let cutoff = pts.seconds - maxSeconds
        while let f = items.first, f.pts.seconds <= cutoff {
            totalBytes -= f.bytes; items.removeFirst()
        }
        while maxBytes > 0 && totalBytes > maxBytes && items.count > 1 {
            let f = items.removeFirst()
            totalBytes -= f.bytes
        }
    }

    func snapshot() -> [CMSampleBuffer] {
        lock.lock(); defer { lock.unlock() }
        return items.map { $0.buffer }
    }
}

// MARK: - H264 硬件编码器
final class VideoCompressor {
    private var session: VTCompressionSession?
    private(set) var formatDescription: CMFormatDescription?
    /// 已复制、可跨队列安全使用的编码帧
    var onEncoded: ((CMSampleBuffer) -> Void)?

    func configure(width: Int32, height: Int32, fps: Int32, bitRate: Int) {
        invalidate()
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard st == noErr, let session = s else { print("[ENC] create fail \(st)"); return }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        // 每秒 2 个关键帧：预录从任意点开始最多丢 0.5 秒画面
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: max(fps / 2, 1) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[ENC] \(width)x\(height)@\(fps) br=\(bitRate)")
    }

    /// 必须在采集回调线程同步调用
    func encode(_ sb: CMSampleBuffer) {
        guard let session = session, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var dur = CMSampleBufferGetDuration(sb)
        if !dur.isValid { dur = CMTime(value: 1, timescale: 30) }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            duration: dur, frameProperties: nil, infoFlagsOut: nil) { [weak self] st, _, enc in
            // 关键：回调返回后 enc 即失效，必须立刻复制
            guard st == noErr, let enc = enc, let kept = retainedCopy(enc) else { return }
            if self?.formatDescription == nil {
                self?.formatDescription = CMSampleBufferGetFormatDescription(kept)
            }
            self?.onEncoded?(kept)
        }
    }

    func invalidate() {
        guard let session = session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil; formatDescription = nil
    }
}

// MARK: - 录制写入器（泵模式。所有方法只在 writerQueue 调用，绝不阻塞采集线程）
// 设计依据 Apple AVCam / RosyWriter：
// - requestMediaDataWhenReady 驱动喂帧，历史帧与实时帧统一排队，严格按 PTS 写入
// - expectsMediaDataInRealTime = false，允许一次性灌入历史帧而不触发实时丢帧/坏文件
// - 任何 writer 失败立即通过 onFail 上报完整错误域与错误码
final class Recorder {
    private var writer: AVAssetWriter?
    private var vi: AVAssetWriterInput?
    private var ai: AVAssetWriterInput?
    private let q: DispatchQueue

    private var histV: [CMSampleBuffer] = []
    private var histA: [CMSampleBuffer] = []
    private var liveV: [CMSampleBuffer] = []
    private var liveA: [CMSampleBuffer] = []

    private var finishing = false
    private var finishCalled = false
    private var vMarked = false
    private var aMarked = true

    private let activeLock = NSLock()
    private var _active = false
    /// 供采集线程跨队列判断当前是否需要把帧送入写入器
    var isActive: Bool { activeLock.lock(); defer { activeLock.unlock() }; return _active }

    /// 主线程回调
    var onFail: ((String) -> Void)?
    var onFinish: ((URL?) -> Void)?

    init(queue: DispatchQueue) { self.q = queue }

    // MARK: 开始（histVideo 为已编码 H264，histAudio 为 PCM）
    func begin(histVideo: [CMSampleBuffer], histAudio: [CMSampleBuffer], url: URL,
               portrait: Bool, front: Bool) {
        // passthrough 首帧必须是关键帧（自带 SPS/PPS）
        var v = histVideo
        if let ki = v.firstIndex(where: { isKeyFrame($0) }) { v = Array(v[ki...]) } else { v = [] }
        guard let firstV = v.first, let fd = CMSampleBufferGetFormatDescription(firstV) else {
            DispatchQueue.main.async { [weak self] in
                self?.onFail?("预录缓冲还没准备好，请等 1～2 秒再按录制")
            }
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
            vIn.expectsMediaDataInRealTime = false
            if portrait {
                // 后置竖屏 +90°；前置竖屏 -90° 并水平翻转，朝向与原相机一致
                var t = CGAffineTransform(rotationAngle: front ? -.pi / 2 : .pi / 2)
                if front { t = t.scaledBy(x: -1, y: 1) }
                vIn.transform = t
            }
            guard w.canAdd(vIn) else { abort(w, reason: "无法添加视频轨道"); return }
            w.add(vIn)

            // 音频：只指定 AAC，采样率/声道跟随源（麦克风通常 48kHz），避免声明不一致导致失败
            let aCand = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: 128_000])
            aCand.expectsMediaDataInRealTime = false
            let aIn: AVAssetWriterInput? = w.canAdd(aCand) ? { w.add(aCand); return aCand }() : nil

            guard w.startWriting() else { abort(w, reason: "启动文件写入失败"); return }

            let start = firstV.presentationTimeStamp
            w.startSession(atSourceTime: start)

            histV = v
            histA = histAudio.filter { $0.presentationTimeStamp.seconds >= start.seconds - 0.02 }
            liveV = []; liveA = []
            writer = w; vi = vIn; ai = aIn
            finishing = false; finishCalled = false
            vMarked = false; aMarked = (aIn == nil)
            activeLock.lock(); _active = true; activeLock.unlock()

            vIn.requestMediaDataWhenReady(on: q) { [weak self] in self?.pumpVideo() }
            aIn?.requestMediaDataWhenReady(on: q) { [weak self] in self?.pumpAudio() }
            print("[REC] begin hist v=\(v.count) a=\(histA.count)")
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onFail?("创建视频文件失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 实时帧入队（writerQueue）
    func enqueueVideo(_ sb: CMSampleBuffer) {
        guard writing else { return }
        liveV.append(sb)
        pumpVideo()
    }

    func enqueueAudio(_ sb: CMSampleBuffer) {
        guard writing else { return }
        liveA.append(sb)
        pumpAudio()
    }

    private var writing: Bool {
        if let w = writer, !finishing, w.status == .writing { return true }
        return false
    }

    // MARK: 泵
    private func pumpVideo() {
        guard let w = writer, let inp = vi else { return }
        while inp.isReadyForMoreMediaData, w.status == .writing {
            let s: CMSampleBuffer? = !histV.isEmpty ? histV.removeFirst()
                                   : (!liveV.isEmpty ? liveV.removeFirst() : nil)
            guard let s = s else {
                if finishing, !vMarked { vMarked = true; inp.markAsFinished(); tryFinish(w) }
                return
            }
            if !inp.append(s) { abort(w, reason: "写入视频帧失败"); return }
        }
        if w.status == .failed { abort(w, reason: "视频写入中断") }
    }

    private func pumpAudio() {
        guard let w = writer, let inp = ai else {
            if finishing, !aMarked { aMarked = true; if let w = writer { tryFinish(w) } }
            return
        }
        while inp.isReadyForMoreMediaData, w.status == .writing {
            let s: CMSampleBuffer? = !histA.isEmpty ? histA.removeFirst()
                                   : (!liveA.isEmpty ? liveA.removeFirst() : nil)
            guard let s = s else {
                if finishing, !aMarked { aMarked = true; inp.markAsFinished(); tryFinish(w) }
                return
            }
            if !inp.append(s) { abort(w, reason: "写入音频帧失败"); return }
        }
        if w.status == .failed { abort(w, reason: "音频写入中断") }
    }

    // MARK: 结束（writerQueue）
    func finish() {
        guard let w = writer else {
            DispatchQueue.main.async { [weak self] in self?.onFinish?(nil) }
            return
        }
        guard !finishing else { return }
        finishing = true
        pumpVideo()
        pumpAudio()
    }

    private func tryFinish(_ w: AVAssetWriter) {
        guard finishing, vMarked, aMarked, !finishCalled else { return }
        finishCalled = true
        w.finishWriting { [weak self] in
            let ok = w.status == .completed
            let url = ok ? w.outputURL : nil
            if let e = w.error { print("[REC] finish error: \(e)") }
            self?.q.async { self?.reset(url: url) }
        }
    }

    // MARK: 失败处理 / 重置
    private func abort(_ w: AVAssetWriter, reason: String) {
        let e = w.error as NSError?
        let detail = "\(reason)：\(e?.localizedDescription ?? "未知") [\(e?.domain ?? "AVF") \(e?.code ?? 0)] status=\(w.status.rawValue)"
        print("[REC] \(detail)")
        if w.status == .writing { w.cancelWriting() }
        reset(url: nil, failMessage: detail)
    }

    private func reset(url: URL?, failMessage: String? = nil) {
        activeLock.lock(); _active = false; activeLock.unlock()
        writer = nil; vi = nil; ai = nil
        histV = []; histA = []; liveV = []; liveA = []
        finishing = false; finishCalled = false; vMarked = false; aMarked = true
        let cb = onFinish
        let fail = onFail
        let msg = failMessage
        DispatchQueue.main.async {
            if let msg = msg { fail?(msg) } else { cb?(url) }
        }
    }
}

// MARK: - 相册
enum PhotoSaver {
    static func save(_ url: URL, _ done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { done(false) }; return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, e in
                if let e = e { print("[Photo] \(e)") }
                DispatchQueue.main.async { done(ok) }
            }
        }
    }
}

// MARK: - 语音控制
// 相机 48kHz PCM →（采集线程同步重采样为独立 16kHz 缓冲）→ SFSpeech
final class VoiceController {
    static let shared = VoiceController()
    private let queue = DispatchQueue(label: "com.actioncam.voice")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var converter: AVAudioConverter?
    private var converterSig = ""
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                             channels: 1, interleaved: false)!
    private var lastCmd = ""
    private var lastCmdAt = Date.distantPast

    var onCommand: ((String) -> Void)?
    var onState: ((Bool) -> Void)?
    var onHeard: ((String) -> Void)?

    init() { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) }

    var isRunning: Bool { return running }

    func start(_ done: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            guard let self = self else { return }
            guard st == .authorized else {
                DispatchQueue.main.async { done(false, "请在系统设置中允许语音识别") }; return
            }
            self.queue.async {
                guard let r = self.recognizer, r.isAvailable else {
                    DispatchQueue.main.async { done(false, "语音识别不可用（检查网络或系统语言）") }; return
                }
                self.running = true
                self.startTask()
                DispatchQueue.main.async {
                    self.onState?(true)
                    done(true, "语音已开启：说\"开始录像\" / \"停止录像\"")
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.running = false
            self.request?.endAudio(); self.task?.cancel()
            self.request = nil; self.task = nil
            DispatchQueue.main.async { self.onState?(false); self.onHeard?("") }
        }
    }

    private func startTask() {
        guard running, let r = recognizer else { return }
        task?.cancel(); task = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // 不强制离线：中文端侧识别仅部分机型支持，系统会自动选择
        req.requiresOnDeviceRecognition = false
        request = req
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let t = result?.bestTranscription.formattedString, !t.isEmpty {
                let clean = t.replacingOccurrences(of: " ", with: "")
                DispatchQueue.main.async { self.onHeard?(clean) }
                self.detect(clean)
            }
            if error != nil || result?.isFinal == true {
                self.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self, self.running else { return }
                    self.request = nil; self.task = nil
                    self.startTask()
                }
            }
        }
    }

    private func detect(_ text: String) {
        var cmd: String?
        if text.contains("开始录像") || text.contains("开始录制") || text.contains("开拍")
            || (text.contains("开始") && text.contains("录")) {
            cmd = "start"
        } else if text.contains("停止录像") || text.contains("结束录像") || text.contains("停止录制")
                    || text.contains("结束录制") || text.contains("停止拍摄")
                    || (text.contains("停止") && text.contains("录")) {
            cmd = "stop"
        }
        guard let c = cmd else { return }
        let now = Date()
        if lastCmd == c && now.timeIntervalSince(lastCmdAt) < 3 { return }
        lastCmd = c; lastCmdAt = now
        print("[VOICE] \(c) <- \(text)")
        DispatchQueue.main.async { self.onCommand?(c) }
    }

    /// 必须在采集回调线程同步调用（此时 sb 仍有效）
    func feed(_ sb: CMSampleBuffer) {
        guard running else { return }
        guard let outBuf = convert(sb) else { return }
        queue.async { [weak self] in
            guard let self = self, self.running, let req = self.request else { return }
            req.append(outBuf)
        }
    }

    /// 在采集线程把相机 PCM 重采样为 16kHz 单声道，输出缓冲是独立内存可跨队列
    private func convert(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let inFmt = AVAudioFormat(cmAudioFormatDescription: desc)
        let sig = "\(inFmt.sampleRate)_\(inFmt.channelCount)_\(inFmt.commonFormat.rawValue)_\(inFmt.isInterleaved)"
        if sig != converterSig {
            converter = AVAudioConverter(from: inFmt, to: targetFormat)
            converterSig = sig
        }
        guard let converter = converter else { return nil }
        let inFrames = CMSampleBufferGetNumSamples(sb)
        guard inFrames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(inFrames)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(inFrames)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
            frameCount: Int32(inFrames), into: inBuf.mutableAudioBufferList)
        guard st == noErr else { return nil }

        let ratio = targetFormat.sampleRate / inFmt.sampleRate
        let cap = AVAudioFrameCount(Double(inFrames) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return nil }
        var err: NSError?
        var fed = false
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        let ok = (status == .haveData || status == .inputRanDry)
        return (ok && err == nil && outBuf.frameLength > 0) ? outBuf : nil
    }
}

// MARK: - 提示音
final class Beep {
    static let shared = Beep()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    init() {
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }
    private func play(_ freq: Double, _ dur: Double, _ vol: Float, vibrate: Bool) {
        try? engine.start()
        let n = AVAudioFrameCount(fmt.sampleRate * dur)
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        b.frameLength = n
        let c = b.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / fmt.sampleRate
            let env = exp(-4.5 * t)
            c[i] = Float((sin(2 * .pi * freq * t) + 0.2 * sin(4 * .pi * freq * t)) * env) * vol
        }
        node.scheduleBuffer(b, at: nil); node.play()
        if vibrate { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    }
    func start() { play(1320, 0.15, 0.9, vibrate: true) }
    func stop()  { play(880, 0.25, 0.9, vibrate: true) }
    func tap()   { play(1000, 0.05, 0.35, vibrate: false) }
    func on()    { play(1100, 0.1, 0.7, vibrate: false) }
    func off()   { play(700, 0.1, 0.7, vibrate: false) }
}

// MARK: - 相机引擎
final class CameraEngine: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var isVoiceOn = false
    @Published var currentLens: CameraLens = .wide
    @Published var availableLenses: Set<CameraLens> = [.wide]
    @Published var preRecord: PreRecordOption = .s30
    @Published var quality: QualityOption = .hd1080169
    @Published var frameRate: FrameRateOption = .auto
    @Published var stabilization: StabilizationLevel = .auto
    @Published var torchOn = false
    @Published var delayOn = false
    @Published var battery: Float = 1
    @Published var denied = false
    @Published var micGranted = true
    @Published var toast: String?
    @Published var countdown: Int?
    @Published var actualFormat = ""
    @Published var heardText = ""

    let session = AVCaptureSession()
    private let sq = DispatchQueue(label: "com.actioncam.session")
    /// 所有录制数据面（环形缓冲 / AVAssetWriter）只在此队列访问，采集线程永不阻塞
    private let wq = DispatchQueue(label: "com.actioncam.writer")
    private let vOut = AVCaptureVideoDataOutput()
    private let aOut = AVCaptureAudioDataOutput()
    private let movieOut = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var enc = VideoCompressor()
    private var rec: Recorder!
    private var vRing = SampleRingBuffer(maxSeconds: 30, maxBytes: 200 * 1024 * 1024)
    private var aRing = SampleRingBuffer(maxSeconds: 30, maxBytes: 8 * 1024 * 1024)
    private var movieURL: URL?

    /// 预录缓冲内存预算，防止 4K/高帧率长预录被系统杀死
    private static let videoBudget = 200 * 1024 * 1024
    private static let audioBudget = 8 * 1024 * 1024

    private var started = false
    private let preLock = NSLock()
    private var _preSec: TimeInterval = 30
    private var preSec: TimeInterval {
        get { preLock.lock(); defer { preLock.unlock() }; return _preSec }
        set { preLock.lock(); _preSec = newValue; preLock.unlock() }
    }
    private var delayTimer: Timer?
    private var batteryTimer: Timer?
    private var heardDismissWork: DispatchWorkItem?

    // 后置虚拟多摄（0.5/1/长焦无缝切换）
    private var backVirtual: AVCaptureDevice?
    private var backVirtualZooms: [CameraLens: CGFloat] = [:]

    override init() {
        super.init()
        rec = Recorder(queue: wq)
        VoiceController.shared.onCommand = { [weak self] c in
            guard let self = self else { return }
            if c == "start" { if !self.isRecording { self.startRecording() } }
            else { if self.isRecording { self.stopRecording() } }
        }
        VoiceController.shared.onState = { [weak self] on in self?.isVoiceOn = on }
        VoiceController.shared.onHeard = { [weak self] t in self?.showHeard(t) }
    }

    private func showHeard(_ t: String) {
        heardDismissWork?.cancel()
        if t.isEmpty { heardText = ""; return }
        heardText = t
        let work = DispatchWorkItem { [weak self] in self?.heardText = "" }
        heardDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: 启动
    func start() {
        sq.sync { if started { return }; started = true }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] g in
            guard let self = self else { return }
            guard g else { DispatchQueue.main.async { self.denied = true }; return }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { self.micGranted = mic }
                self.configAudio()
                self.sq.async { self.buildSession() }
            }
        }
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.battery = UIDevice.current.batteryLevel
            self.batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.battery = UIDevice.current.batteryLevel
            }
        }
    }

    private func configAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // MARK: 发现镜头（兼容 iOS 13+ 全部机型）
    private func discoverBackLenses() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        for t in types {
            if let d = AVCaptureDevice.default(t, for: .video, position: .back) {
                backVirtual = d
                var lenses: Set<CameraLens> = [.wide]
                var zooms: [CameraLens: CGFloat] = [.wide: 1.0]
                let constituents = d.constituentDevices
                if constituents.contains(where: { $0.deviceType == .builtInUltraWideCamera }) {
                    lenses.insert(.ultraWide)
                    zooms[.ultraWide] = max(d.minAvailableVideoZoomFactor, 0.5)
                }
                if constituents.contains(where: { $0.deviceType == .builtInTelephotoCamera }) {
                    lenses.insert(.telephoto)
                    var teleZoom: CGFloat = 2.0
                    if #available(iOS 16.0, *) {
                        if let last = d.virtualDeviceSwitchOverVideoZoomFactors.last {
                            teleZoom = CGFloat(truncating: last)
                        }
                    }
                    zooms[.telephoto] = teleZoom
                }
                backVirtualZooms = zooms
                DispatchQueue.main.async {
                    var all = lenses; all.insert(.frontWide)
                    self.availableLenses = all
                }
                return
            }
        }
        // 老机型回退：独立镜头
        backVirtual = nil
        var lenses: Set<CameraLens> = [.wide]
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil { lenses.insert(.ultraWide) }
        if AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil { lenses.insert(.telephoto) }
        lenses.insert(.frontWide)
        DispatchQueue.main.async { self.availableLenses = lenses }
    }

    // MARK: 选择最匹配的 activeFormat
    private func bestFormat(_ d: AVCaptureDevice, wantFps: Int) -> AVCaptureDevice.Format? {
        let tw = quality.targetWidth, th = quality.targetHeight
        let wantRatio = tw / th
        let targetPixels = tw * th
        var best: AVCaptureDevice.Format?
        var bestScore = -Double.greatestFiniteMagnitude

        for f in d.formats {
            let desc = f.formatDescription
            guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { continue }
            let dim = CMVideoFormatDescriptionGetDimensions(desc)
            guard dim.width > 0, dim.height > 0 else { continue }
            let ranges = f.videoSupportedFrameRateRanges
            guard !ranges.isEmpty else { continue }
            let maxFps = ranges.map { $0.maxFrameRate }.max() ?? 0
            if maxFps < 24 { continue } // 排除照片专用低帧格式
            let w = Double(dim.width), h = Double(dim.height)
            let ratio = w / h

            var score = 0.0
            // 1) 比例必须最接近（权重最高）
            score -= abs(ratio - wantRatio) * 100000
            // 2) 像素量接近目标（对数距离，避免选到超大照片格式）
            score -= abs(log((w * h) / targetPixels)) * 100
            // 3) 帧率满足度
            if wantFps > 0 {
                if maxFps + 0.5 >= Double(wantFps) { score += 50 } else { score -= 300 }
            }
            if score > bestScore { bestScore = score; best = f }
        }
        return best
    }

    /// 让 activeFormat 生效：iOS 15+ 用 inputPriority；iOS 14 用 high（锁定 activeFormat 后格式优先生效）
    private func applyInputPriorityPreset() {
        if #available(iOS 15.0, *) {
            session.sessionPreset = .inputPriority
        } else {
            session.sessionPreset = .high
        }
    }

    // MARK: 构建采集会话
    private func buildSession() {
        discoverBackLenses()

        let wantPos = currentLens.position
        if wantPos == .back, let v = backVirtual {
            device = v
        } else {
            let wantType: AVCaptureDevice.DeviceType
            switch currentLens {
            case .ultraWide: wantType = .builtInUltraWideCamera
            case .telephoto: wantType = .builtInTelephotoCamera
            default: wantType = .builtInWideAngleCamera
            }
            device = AVCaptureDevice.default(wantType, for: .video, position: wantPos)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: wantPos)
        }
        guard let dev = device else { flash("未找到摄像头"); return }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        // 让 activeFormat 生效（iOS 14/15+ 分别处理），否则分辨率/比例设置无效
        applyInputPriorityPreset()

        guard let vInput = try? AVCaptureDeviceInput(device: dev), session.canAddInput(vInput) else {
            session.commitConfiguration(); flash("无法添加摄像头"); return
        }
        session.addInput(vInput)

        if micGranted, let micDev = AVCaptureDevice.default(for: .audio),
           let mInput = try? AVCaptureDeviceInput(device: micDev), session.canAddInput(mInput) {
            session.addInput(mInput)
        }

        // 双通道：预录开启→原始帧+硬件编码环形缓冲；预录关闭→系统 MovieFileOutput（与原相机同级可靠）
        if preSec > 0 {
            vOut.alwaysDiscardsLateVideoFrames = true
            vOut.setSampleBufferDelegate(self, queue: sq)
            if session.canAddOutput(vOut) { session.addOutput(vOut) }

            aOut.setSampleBufferDelegate(self, queue: sq)
            if micGranted, session.canAddOutput(aOut) { session.addOutput(aOut) }

            if let c = vOut.connection(with: .video) {
                // 关键：dataOutput 不设 videoOrientation，缓冲保持传感器横向方向，
                // 竖屏完全交给 AVAssetWriterInput.transform，避免双重旋转导致坏文件
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = (wantPos == .front)
            }
        } else {
            if session.canAddOutput(movieOut) { session.addOutput(movieOut) }
            if let c = movieOut.connection(with: .video) {
                if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = (wantPos == .front)
            }
            // 音频 dataOutput 与 MovieFileOutput 可共存：仅用于语音识别，不干扰系统录音
            aOut.setSampleBufferDelegate(self, queue: sq)
            if micGranted, session.canAddOutput(aOut) { session.addOutput(aOut) }
        }

        do {
            try dev.lockForConfiguration()
            applyFormat(dev)
            dev.unlockForConfiguration()
        } catch { print("[FMT] lock error: \(error)") }

        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }

        if wantPos == .back, backVirtual === dev {
            let z = backVirtualZooms[currentLens] ?? 1.0
            do { try dev.lockForConfiguration(); dev.videoZoomFactor = z; dev.unlockForConfiguration() } catch {}
        }
        applyStabilization()
    }

    /// 调用方须持有 device lock 并处于 begin/commitConfiguration 之间
    private func applyFormat(_ dev: AVCaptureDevice) {
        let wantFps = frameRate.rawValue
        guard let fmt = bestFormat(dev, wantFps: wantFps) else {
            print("[FMT] no format matched"); return
        }
        dev.activeFormat = fmt
        if wantFps > 0 {
            let fpsD = Double(wantFps)
            if fmt.videoSupportedFrameRateRanges.contains(where: {
                fpsD >= $0.minFrameRate && fpsD <= $0.maxFrameRate
            }) {
                let t = CMTime(value: 1, timescale: CMTimeScale(wantFps))
                dev.activeVideoMinFrameDuration = t
                dev.activeVideoMaxFrameDuration = t
            }
        }

        let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let realMaxFps = fmt.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        let effFps = wantFps > 0 ? min(Double(wantFps), realMaxFps) : 30
        DispatchQueue.main.async {
            self.actualFormat = "\(dim.width)×\(dim.height) @\(Int(effFps))"
        }

        // 码率：基础值 × 帧率系数
        let fpsFactor = max(effFps / 30.0, 1.0)
        let base: Int
        if dim.width >= 3840 { base = 18_000_000 }
        else if dim.width >= 1920 { base = 8_000_000 }
        else { base = 4_500_000 }
        let br = min(Int(Double(base) * fpsFactor), 60_000_000)
        // 仅预录通道需要持续硬件编码；预录关闭时由 MovieFileOutput 内部编码，更省电
        if preSec > 0 {
            enc.configure(width: dim.width, height: dim.height, fps: Int32(max(effFps, 24)), bitRate: br)
            enc.onEncoded = { [weak self] kept in
                // kept 已在 VT 回调内复制；统一派发到写入队列：录制中入 writer，否则入预录环
                guard let self = self else { return }
                self.wq.async {
                    if self.rec.isActive {
                        self.rec.enqueueVideo(kept)
                    } else {
                        self.vRing.append(kept)
                    }
                }
            }
            let ps = max(preSec, 1)
            wq.async {
                self.vRing = SampleRingBuffer(maxSeconds: ps, maxBytes: CameraEngine.videoBudget)
                self.aRing = SampleRingBuffer(maxSeconds: ps, maxBytes: CameraEngine.audioBudget)
            }
        }
    }

    // MARK: 切换镜头
    func switchLens(_ lens: CameraLens) {
        guard availableLenses.contains(lens), lens != currentLens else { return }
        let safeZoom = lens.position == .back && backVirtual != nil && backVirtual === device
        if isRecording && !safeZoom { flash("录制中无法切换到该镜头"); return }
        Beep.shared.tap()
        currentLens = lens
        sq.async { [weak self] in
            guard let self = self else { return }
            if lens.position == .back, let v = self.backVirtual, self.device === v {
                let z = self.backVirtualZooms[lens] ?? 1.0
                do { try v.lockForConfiguration(); v.videoZoomFactor = z; v.unlockForConfiguration() }
                catch { print("[LENS] zoom error \(error)") }
            } else {
                self.buildSession()
            }
        }
    }

    // MARK: 设置
    func setQuality(_ q: QualityOption) {
        guard q != quality else { return }
        if isRecording { flash("请先停止录制再切换分辨率"); return }
        quality = q; Beep.shared.tap()
        sq.async { [weak self] in
            guard let self = self, let d = self.device else { return }
            self.session.beginConfiguration()
            self.applyInputPriorityPreset()
            do { try d.lockForConfiguration(); self.applyFormat(d); d.unlockForConfiguration() } catch {}
            self.session.commitConfiguration()
        }
    }

    func setFrameRate(_ f: FrameRateOption) {
        guard f != frameRate else { return }
        if isRecording { flash("请先停止录制再切换帧率"); return }
        frameRate = f; Beep.shared.tap()
        sq.async { [weak self] in
            guard let self = self, let d = self.device else { return }
            self.session.beginConfiguration()
            self.applyInputPriorityPreset()
            do { try d.lockForConfiguration(); self.applyFormat(d); d.unlockForConfiguration() } catch {}
            self.session.commitConfiguration()
        }
    }

    func setPreRecord(_ p: PreRecordOption) {
        guard p != preRecord else { return }
        if isRecording { flash("请先停止录制再切换预录档位"); return }
        preRecord = p; Beep.shared.tap(); preSec = p.seconds
        // 预录开关要在 dataOutput 与 MovieFileOutput 两套输出之间切换，重建会话
        sq.async { [weak self] in self?.buildSession() }
    }

    func setStabilization(_ s: StabilizationLevel) {
        stabilization = s; Beep.shared.tap()
        sq.async { [weak self] in self?.applyStabilization() }
    }

    private func applyStabilization() {
        if let c = vOut.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = stabilization.mode
        }
        if let c = movieOut.connection(with: .video), c.isVideoStabilizationSupported {
            c.preferredVideoStabilizationMode = stabilization.mode
        }
    }

    func toggleTorch() {
        torchOn.toggle(); Beep.shared.tap()
        let on = torchOn
        sq.async { [weak self] in
            guard let self = self, let d = self.device, d.position == .back else { return }
            do { try d.lockForConfiguration()
                if on, d.hasTorch, d.isTorchAvailable { try d.setTorchModeOn(level: 1) }
                else { d.torchMode = .off }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func toggleVoice() {
        if isVoiceOn {
            VoiceController.shared.stop(); Beep.shared.off(); flash("语音已关闭")
        } else {
            VoiceController.shared.start { [weak self] ok, msg in
                if ok { Beep.shared.on() } else { Beep.shared.off() }
                self?.flash(msg)
            }
        }
    }

    // MARK: 录制
    func toggleRecord() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        if delayOn {
            var n = 3
            DispatchQueue.main.async { self.countdown = n }
            Beep.shared.tap()
            delayTimer?.invalidate()
            delayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                n -= 1
                if n <= 0 {
                    t.invalidate(); self.delayTimer = nil; self.countdown = nil
                    self.doStart()
                } else { self.countdown = n; Beep.shared.tap() }
            }
        } else { doStart() }
    }

    private func doStart() {
        if preSec > 0 {
            // 预录管线：准备工作全部在写入队列完成，采集线程零阻塞
            wq.async { [weak self] in
                guard let self = self, !self.rec.isActive else { return }
                self.rec.onFail = { [weak self] msg in
                    self?.isRecording = false
                    self?.isSaving = false
                    self?.flash(msg)
                }
                self.rec.onFinish = { [weak self] url in self?.handleSaved(url) }
                self.rec.begin(histVideo: self.vRing.snapshot(),
                               histAudio: self.aRing.snapshot(),
                               url: self.makeURL(),
                               portrait: true,
                               front: self.currentLens.position == .front)
                if self.rec.isActive {
                    DispatchQueue.main.async { self.isRecording = true; Beep.shared.start() }
                }
            }
        } else {
            // 系统 MovieFileOutput 通道：与苹果原相机同一套写入，最稳、最省电
            sq.async { [weak self] in
                guard let self = self, !self.movieOut.isRecording else { return }
                let url = self.makeURL()
                self.movieURL = url
                if let c = self.movieOut.connection(with: .video) {
                    if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
                    c.isVideoMirrored = self.currentLens.position == .front
                }
                self.movieOut.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { self.isRecording = true; Beep.shared.start() }
            }
        }
    }

    func stopRecording() {
        delayTimer?.invalidate(); delayTimer = nil; countdown = nil
        Beep.shared.stop()
        DispatchQueue.main.async { self.isRecording = false; self.isSaving = true }
        if preSec > 0 {
            wq.async { [weak self] in self?.rec.finish() }
        } else {
            sq.async { [weak self] in
                if self?.movieOut.isRecording == true { self?.movieOut.stopRecording() }
            }
        }
    }

    /// 统一保存入口（主线程或任意线程调用均可）
    private func handleSaved(_ url: URL?) {
        guard let url = url else {
            DispatchQueue.main.async {
                self.isSaving = false
                self.flash("保存失败：没有生成视频文件")
            }
            return
        }
        // 预录管线：本段结束后清空环形缓冲，下一段预录从当前时刻重新积累
        if preSec > 0 {
            wq.async {
                let ps = max(self.preSec, 1)
                self.vRing = SampleRingBuffer(maxSeconds: ps, maxBytes: CameraEngine.videoBudget)
                self.aRing = SampleRingBuffer(maxSeconds: ps, maxBytes: CameraEngine.audioBudget)
            }
        }
        PhotoSaver.save(url) { [weak self] ok in
            DispatchQueue.main.async {
                self?.isSaving = false
                self?.flash(ok ? "✓ 已保存到相册" : "保存失败：请允许添加到相册")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeURL() -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        return d.appendingPathComponent("Action_\(f.string(from: Date())).mp4")
    }

    func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == m { self?.toast = nil }
        }
    }
}

// MARK: 采集回调（运行在 sq；只做极轻量操作，耗时工作全部派发 wq，绝不阻塞相机/麦克风）
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                       from c: AVCaptureConnection) {
        if o === vOut {
            // VT 编码为异步，完成回调在其内部线程；回调内已复制帧并自行派发到 wq
            enc.encode(sb)
        } else if o === aOut {
            if preSec > 0, let copy = retainedCopy(sb) {
                if rec.isActive {
                    wq.async { self.rec.enqueueAudio(copy) }
                } else {
                    wq.async { self.aRing.append(copy) }
                }
            }
            // 语音识别：内部当场重采样为独立 16kHz 缓冲
            VoiceController.shared.feed(sb)
        }
    }
}

// MARK: - 系统 MovieFileOutput 录制结果（预录关闭通道）
extension CameraEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    error: Error?) {
        let nsErr = error as NSError?
        let finishedOK = (nsErr == nil)
            || (nsErr?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        if finishedOK {
            handleSaved(outputFileURL)
        } else {
            let detail = "\(nsErr?.localizedDescription ?? "未知错误") [\(nsErr?.domain ?? "AVF") \(nsErr?.code ?? 0)]"
            print("[MOVIE] \(detail)")
            DispatchQueue.main.async {
                self.isSaving = false
                self.flash("保存失败：\(detail)")
            }
            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }
}

// MARK: - 预览
struct Preview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        let p = v.layer as! AVCaptureVideoPreviewLayer
        p.session = session
        p.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
}

// MARK: - 主题（兼容 iOS 14）
enum T {
    static let accent = Color(red: 0.15, green: 0.78, blue: 0.65)
    static let rec = Color(red: 0.95, green: 0.30, blue: 0.25)
    static let panel = Color.black.opacity(0.55)
    static let cell = Color(red: 0.16, green: 0.16, blue: 0.18)
}

// MARK: - 主界面（兼容 iPhone 6s ~ iPhone 16 全系列 / iOS 14+）
struct CameraScreen: View {
    @StateObject private var e = CameraEngine()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Preview(session: e.session).ignoresSafeArea()

            if e.denied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.metering.unknown").font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.7))
                    Text("需要相机权限").font(.headline).foregroundColor(.white)
                    Button("打开系统设置") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(T.accent).foregroundColor(.black).clipShape(Capsule())
                }
            }

            VStack {
                HStack(spacing: 8) {
                    Text(e.isRecording ? "● REC" : (e.preRecord.rawValue > 0 ? "预录\(e.preRecord.rawValue)s" : "STBY"))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(e.isRecording ? T.rec : .white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(T.panel).cornerRadius(6)
                    if e.isVoiceOn {
                        Label("语音", systemImage: "mic.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(T.accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(T.panel).cornerRadius(6)
                    }
                    Spacer()
                    Text("\(Int(e.battery * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(T.panel).cornerRadius(6)
                    IconButton(e.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", on: e.torchOn) {
                        e.toggleTorch()
                    }
                    IconButton("gearshape.fill", on: false) { showSettings = true }
                }
                .padding(.horizontal, 12)

                HStack(spacing: 6) {
                    if !e.actualFormat.isEmpty {
                        Text(e.actualFormat)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(T.panel).cornerRadius(4)
                    }
                    if !e.micGranted {
                        Text("无麦克风")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(T.panel).cornerRadius(4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 4)
                Spacer()
            }

            // 语音实时听到的内容（调试 + 反馈）
            VStack {
                Spacer().frame(height: 120)
                if e.isVoiceOn && !e.heardText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 12))
                        Text(e.heardText).font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(T.accent)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(T.panel).cornerRadius(20)
                }
                Spacer()
            }

            if let c = e.countdown {
                Text("\(c)").font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundColor(.white).shadow(radius: 10)
            }

            if let m = e.toast {
                VStack {
                    Spacer().frame(height: 170)
                    Text(m).font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white).multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(T.panel).cornerRadius(20)
                    Spacer()
                }
            }

            if e.isSaving {
                VStack {
                    Spacer()
                    Text("保存中…").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(T.panel).cornerRadius(16)
                        .padding(.bottom, 130)
                }
            }

            VStack {
                Spacer()
                HStack(spacing: 40) {
                    Button { e.toggleVoice() } label: {
                        ZStack {
                            Circle().fill(e.isVoiceOn ? T.accent : T.panel).frame(width: 56, height: 56)
                            Image(systemName: e.isVoiceOn ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 20))
                                .foregroundColor(e.isVoiceOn ? .black : .white)
                        }
                    }
                    Button { e.toggleRecord() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                            if e.isRecording {
                                RoundedRectangle(cornerRadius: 7).fill(T.rec).frame(width: 30, height: 30)
                            } else {
                                Circle().fill(T.rec).frame(width: 58, height: 58)
                            }
                        }
                    }.disabled(e.isSaving)
                    Button {
                        let all = CameraLens.allCases.filter { e.availableLenses.contains($0) }
                        if let i = all.firstIndex(of: e.currentLens) {
                            e.switchLens(all[(i + 1) % all.count])
                        }
                    } label: {
                        Text(e.currentLens.shortName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(T.panel).clipShape(Circle())
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .navigationBarHidden(true)
        .ignoresSafeArea(.keyboard)
        .onAppear { e.start() }
        .sheet(isPresented: $showSettings) { Settings(e: e) }
    }
}

struct IconButton: View {
    let icon: String; let on: Bool; let action: () -> Void
    init(_ icon: String, on: Bool, action: @escaping () -> Void) {
        self.icon = icon; self.on = on; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15))
                .foregroundColor(on ? T.accent : .white)
                .frame(width: 34, height: 34).background(T.panel).clipShape(Circle())
        }
    }
}

// MARK: - 设置
struct Settings: View {
    @ObservedObject var e: CameraEngine
    @Environment(\.presentationMode) private var presentationMode
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("防抖") {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(StabilizationLevel.allCases, id: \.self) { v in
                                Cell(v.rawValue, sel: e.stabilization == v) { e.setStabilization(v) }
                            }
                        }
                    }
                    section("预录时长（4K/高帧率时按内存自动缩短）") {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(PreRecordOption.allCases, id: \.self) { v in
                                Cell(v.label, sel: e.preRecord == v) { e.setPreRecord(v) }
                            }
                        }
                    }
                    section("镜头（灰显=本机不支持）") {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(CameraLens.allCases, id: \.self) { v in
                                Cell(v.rawValue, sel: e.currentLens == v,
                                     enabled: e.availableLenses.contains(v)) { e.switchLens(v) }
                            }
                        }
                    }
                    section("分辨率 / 比例") {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(QualityOption.allCases, id: \.self) { v in
                                Cell(v.rawValue, sel: e.quality == v) { e.setQuality(v) }
                            }
                        }
                    }
                    section("帧率（高帧率需机型支持）") {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(FrameRateOption.allCases, id: \.self) { v in
                                Cell(v.label, sel: e.frameRate == v) { e.setFrameRate(v) }
                            }
                        }
                    }
                    section("拍摄") {
                        ToggleRow("延迟拍摄（3秒）", $e.delayOn)
                        ToggleRow("夜间补光", Binding(get: { e.torchOn },
                            set: { v in if v != e.torchOn { e.toggleTorch() } }))
                        ToggleRow("语音控制（开始/停止录像）", Binding(get: { e.isVoiceOn },
                            set: { v in if v != e.isVoiceOn { e.toggleVoice() } }))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 30)
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea())
            .navigationTitle("相机设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { presentationMode.wrappedValue.dismiss() } label: {
                        Text("完成").fontWeight(.bold).foregroundColor(T.accent)
                    }
                }
            }
        }.preferredColorScheme(.dark)
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundColor(.white.opacity(0.5))
            c()
        }
    }
}

struct Cell: View {
    let title: String; let sel: Bool; let enabled: Bool; let action: () -> Void
    init(_ title: String, sel: Bool, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.sel = sel; self.enabled = enabled; self.action = action
    }
    var body: some View {
        Button { if enabled { action() } } label: {
            Text(title)
                .font(.system(size: 13, weight: sel ? .bold : .regular))
                .foregroundColor(!enabled ? Color.gray.opacity(0.4) : (sel ? .black : .white))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(sel ? T.accent : T.cell)
                .cornerRadius(10)
        }.disabled(!enabled)
    }
}

struct ToggleRow: View {
    let title: String; @Binding var on: Bool
    init(_ title: String, _ on: Binding<Bool>) {
        self.title = title; self._on = on
    }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundColor(.white)
            Spacer()
            Toggle("", isOn: $on).labelsHidden().accentColor(T.accent)
        }
        .padding(.horizontal, 14).frame(height: 46).background(T.cell).cornerRadius(10)
    }
}
