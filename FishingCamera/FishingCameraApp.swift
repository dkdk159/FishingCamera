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

/// 真实可用的分辨率档位（activeFormat 匹配）
enum QualityOption: String, CaseIterable {
    case uhd4K169   = "4K 16:9"
    case uhd4K43    = "4K 4:3"
    case hd1080169  = "1080P 16:9"
    case hd108043   = "1080P 4:3"
    case hd720169   = "720P 16:9"
    case hd72043    = "720P 4:3"

    var targetWidth: Int32 {
        switch self {
        case .uhd4K169, .uhd4K43: return 3840
        case .hd1080169, .hd108043: return 1920
        case .hd720169, .hd72043: return 1280
        }
    }
    var targetHeight: Int32 {
        switch self {
        case .uhd4K169: return 2160
        case .uhd4K43: return 2880
        case .hd1080169: return 1080
        case .hd108043: return 1440
        case .hd720169: return 720
        case .hd72043: return 960
        }
    }
    var is43: Bool { self == .uhd4K43 || self == .hd108043 || self == .hd72043 }
}

enum FrameRateOption: Int, CaseIterable {
    case auto = 0, f30 = 30, f60 = 60, f120 = 120, f240 = 240
    var label: String { rawValue == 0 ? "自动" : "\(rawValue)" }
}

// MARK: - 环形缓冲（线程安全，PTS 滚动淘汰）
private struct TimedSample { let buffer: CMSampleBuffer; let pts: CMTime }

final class SampleRingBuffer {
    private var items: [TimedSample] = []
    private let lock = NSLock()
    private let maxSeconds: Double
    init(maxSeconds: Double) { self.maxSeconds = max(1, maxSeconds) }
    func append(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        lock.lock(); defer { lock.unlock() }
        items.append(.init(buffer: sb, pts: pts))
        let cutoff = pts.seconds - maxSeconds
        while let f = items.first, f.pts.seconds <= cutoff { items.removeFirst() }
    }
    func snapshot() -> [CMSampleBuffer] {
        lock.lock(); defer { lock.unlock() }
        return items.map { $0.buffer }
    }
}

private func isKeyFrame(_ sb: CMSampleBuffer) -> Bool {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
        as? [[CFString: Any]], let a = arr.first else { return true }
    return !(a[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
}

// MARK: - H264 硬件编码器
final class VideoCompressor {
    private var session: VTCompressionSession?
    private(set) var formatDescription: CMFormatDescription?
    var onEncoded: ((CMSampleBuffer) -> Void)?
    private(set) var width: Int32 = 1920
    private(set) var height: Int32 = 1080

    func configure(width: Int32, height: Int32, fps: Int32, bitRate: Int) {
        invalidate()
        self.width = width; self.height = height
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
        // 每秒 2 个关键帧，预录从任意点开始最多丢 0.5 秒
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: max(fps / 2, 1) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[ENC] configured \(width)x\(height)@\(fps)")
    }

    func encode(_ sb: CMSampleBuffer) {
        guard let session = session, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var dur = CMSampleBufferGetDuration(sb)
        if !dur.isValid { dur = CMTime(value: 1, timescale: 30) }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            duration: dur, frameProperties: nil, infoFlagsOut: nil) { [weak self] st, _, enc in
            guard st == noErr, let enc = enc else { return }
            if self?.formatDescription == nil { self?.formatDescription = CMSampleBufferGetFormatDescription(enc) }
            self?.onEncoded?(enc)
        }
    }

    func invalidate() {
        guard let session = session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil; formatDescription = nil
    }
}

// MARK: - 录制写入器（全部在 sessionQueue 同步调用，无竞争）
final class Recorder {
    private var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?
    private var aIn: AVAssetWriterInput?
    private var finishing = false

    var isActive: Bool { writer != nil && !finishing }

    /// 同步开始并写入历史帧。返回是否成功。
    @discardableResult
    func begin(video: [CMSampleBuffer], audio: [CMSampleBuffer],
               url: URL, format: CMFormatDescription?, portrait: Bool) -> Bool {
        guard let format = format else {
            print("[REC] encoder format not ready")
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

            // passthrough：直接写入已由 VideoToolbox 编码的 H264 帧
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            vi.expectsMediaDataInRealTime = true
            if portrait { vi.transform = CGAffineTransform(rotationAngle: .pi / 2) }
            if w.canAdd(vi) { w.add(vi) }

            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000])
            ai.expectsMediaDataInRealTime = true
            if w.canAdd(ai) { w.add(ai) }

            w.startWriting()

            // 历史视频必须从关键帧开始
            var v = video
            if let ki = v.firstIndex(where: { isKeyFrame($0) }) { v = Array(v[ki...]) } else { v = [] }
            guard let start = v.first?.pts ?? audio.first?.pts else {
                // 完全没有历史：先启动，实时帧再开始 session
                writer = w; vIn = vi; aIn = ai
                print("[REC] begin no-history")
                return true
            }
            var a = audio.filter { $0.pts.seconds >= start.seconds - 0.002 }
            w.startSession(atSourceTime: start)

            // 交错写入历史（等待输入就绪，避免丢历史帧）
            var vi2 = 0, ai2 = 0
            while vi2 < v.count || ai2 < a.count {
                if ai2 >= a.count || (vi2 < v.count && v[vi2].pts.seconds <= a[ai2].pts.seconds) {
                    if Self.waitReady(vi) { vi.append(v[vi2]) }
                    vi2 += 1
                } else {
                    if Self.waitReady(ai) { ai.append(a[ai2]) }
                    ai2 += 1
                }
            }
            writer = w; vIn = vi; aIn = ai
            print("[REC] begin history v=\(v.count) a=\(a.count)")
            return true
        } catch {
            print("[REC] begin error: \(error)")
            return false
        }
    }

    /// 短暂等待 writer 输入就绪（最多 ~0.5s），返回是否可写入
    private static func waitReady(_ input: AVAssetWriterInput) -> Bool {
        var n = 0
        while !input.isReadyForMoreMediaData, n < 50 {
            usleep(10_000); n += 1
            if Thread.isCancelled { return false }
        }
        return input.isReadyForMoreMediaData
    }

    func appendVideo(_ sb: CMSampleBuffer) {
        guard let w = writer, !finishing else { return }
        if w.status != .writing { return }
        if w.sessionStartTime.isNaN {
            // session 尚未开始（无历史帧情形）：必须从关键帧开始
            guard isKeyFrame(sb) else { return }
            w.startSession(atSourceTime: sb.pts)
        }
        if vIn?.isReadyForMoreMediaData == true { vIn?.append(sb) }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard let w = writer, !finishing else { return }
        if w.status != .writing { return }
        if w.sessionStartTime.isNaN { w.startSession(atSourceTime: sb.pts) }
        if aIn?.isReadyForMoreMediaData == true { aIn?.append(sb) }
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard let w = writer, !finishing else { done(nil); return }
        finishing = true
        vIn?.markAsFinished(); aIn?.markAsFinished()
        w.finishWriting { [weak self] in
            let url = w.status == .completed ? w.outputURL : nil
            if let e = w.error { print("[REC] finish error: \(e)") }
            DispatchQueue.main.async {
                self?.writer = nil; self?.vIn = nil; self?.aIn = nil; self?.finishing = false
                done(url)
            }
        }
    }
}

private extension CMSampleBuffer {
    var pts: CMTime { CMSampleBufferGetPresentationTimeStamp(self) }
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

// MARK: - 语音控制（相机流 → AVAudioConverter → SFSpeech）
final class VoiceController {
    static let shared = VoiceController()
    private let queue = DispatchQueue(label: "com.actioncam.voice")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var converter: AVAudioConverter?
    private var converterFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                             channels: 1, interleaved: false)!
    private var lastCmd = ""
    private var lastCmdAt = Date.distantPast

    var onCommand: ((String) -> Void)?
    var onState: ((Bool) -> Void)?

    init() { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) }

    func start(_ done: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            guard let self = self else { return }
            guard st == .authorized else {
                DispatchQueue.main.async { done(false, "请在设置中允许语音识别") }; return
            }
            self.queue.async {
                guard let r = self.recognizer, r.isAvailable else {
                    DispatchQueue.main.async { done(false, "语音识别不可用") }; return
                }
                self.running = true
                self.startTask()
                DispatchQueue.main.async {
                    self.onState?(true); done(true, "语音已开启：说开始录像 / 停止录像")
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
            DispatchQueue.main.async { self.onState?(false) }
        }
    }

    private func startTask() {
        guard running, let r = recognizer else { return }
        task?.cancel(); task = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // 不强制离线：中文离线仅部分机型支持；系统会自动在离线可用时走离线
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
        request = req
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let t = result?.bestTranscription.formattedString {
                self.detect(t.replacingOccurrences(of: " ", with: ""))
            }
            if error != nil || result?.isFinal == true {
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self = self, self.running else { return }
                    self.request = nil; self.task = nil
                    self.startTask()
                }
            }
        }
    }

    private func detect(_ text: String) {
        var cmd: String?
        if text.contains("开始录像") || text.contains("开始录制") || text.contains("开拍") || text.contains("开始拍") {
            cmd = "start"
        } else if text.contains("停止录像") || text.contains("结束录像") || text.contains("停止录制")
                    || text.contains("结束录制") || text.contains("停止拍摄") {
            cmd = "stop"
        }
        guard let c = cmd else { return }
        let now = Date()
        if lastCmd == c && now.timeIntervalSince(lastCmdAt) < 3 { return }
        lastCmd = c; lastCmdAt = now
        print("[VOICE] \(c) <- \(text)")
        DispatchQueue.main.async { self.onCommand?(c) }
    }

    /// 喂入相机音频帧
    func enqueue(_ sb: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.running, let req = self.request else { return }
            guard let out = self.convert(sb) else { return }
            req.append(out)
        }
    }

    private func convert(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let inFmt = AVAudioFormat(cmAudioFormatDescription: desc)
        let same = converterFormat.map {
            $0.sampleRate == inFmt.sampleRate
            && $0.channelCount == inFmt.channelCount
            && $0.commonFormat == inFmt.commonFormat
            && $0.isInterleaved == inFmt.isInterleaved
        } ?? false
        if !same {
            converter = AVAudioConverter(from: inFmt, to: targetFormat)
            converterFormat = inFmt
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
        converter.convert(to: outBuf, error: &err) { _, outPacket in
            if fed { outPacket.pointee = nil; return .noDataNow }
            fed = true
            outPacket.pointee = inBuf
            return .haveData
        }
        return err == nil ? outBuf : nil
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
    func tap()   { play(1000, 0.05, 0.4, vibrate: false) }
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
    @Published var toast: String?
    @Published var countdown: Int?
    @Published var actualFormat: String = ""

    let session = AVCaptureSession()
    private let sq = DispatchQueue(label: "com.actioncam.session")
    private let vOut = AVCaptureVideoDataOutput()
    private let aOut = AVCaptureAudioDataOutput()
    private var device: AVCaptureDevice?
    private var enc = VideoCompressor()
    private var vRing = SampleRingBuffer(maxSeconds: 30)
    private var aRing = SampleRingBuffer(maxSeconds: 30)
    private let rec = Recorder()

    private var started = false
    private var recording = false
    private var preSec: TimeInterval = 30
    private var delayTimer: Timer?
    private var batteryTimer: Timer?

    // 后置虚拟多摄（支持无缝 0.5/1/3 倍）
    private var backVirtual: AVCaptureDevice?
    private var backVirtualZooms: [CameraLens: CGFloat] = [:]

    override init() {
        super.init()
        VoiceController.shared.onCommand = { [weak self] c in
            guard let self = self else { return }
            if c == "start" { if !self.isRecording { self.startRecording() } }
            else { if self.isRecording { self.stopRecording() } }
        }
        VoiceController.shared.onState = { [weak self] on in self?.isVoiceOn = on }
    }

    // MARK: 启动
    func start() {
        sq.sync { if started { return }; started = true }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] g in
            guard let self = self else { return }
            guard g else { DispatchQueue.main.async { self.denied = true }; return }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                self.configAudio()
                self.sq.async { self.buildSession(mic: mic) }
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

    // MARK: 发现摄像头
    private func discoverBackLenses() {
        // 优先虚拟多摄
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        for t in types {
            if let d = AVCaptureDevice.default(t, for: .video, position: .back) {
                backVirtual = d
                var lenses: Set<CameraLens> = [.wide]
                var zooms: [CameraLens: CGFloat] = [.wide: 1.0]
                let constituents = d.constituentDevices
                let hasUltra = constituents.contains { $0.deviceType == .builtInUltraWideCamera }
                let hasTele = constituents.contains { $0.deviceType == .builtInTelephotoCamera }
                if hasUltra {
                    lenses.insert(.ultraWide)
                    zooms[.ultraWide] = max(d.minAvailableVideoZoomFactor, 0.5)
                }
                if hasTele {
                    lenses.insert(.telephoto)
                    let factors = d.virtualDeviceSwitchOverVideoZoomFactors
                    if let last = factors.last {
                        zooms[.telephoto] = CGFloat(truncating: last)
                    } else {
                        zooms[.telephoto] = 2.0
                    }
                }
                backVirtualZooms = zooms
                DispatchQueue.main.async {
                    var all = lenses
                    all.insert(.frontWide)
                    self.availableLenses = all
                }
                return
            }
        }
        // 回退：独立镜头
        backVirtual = nil
        var lenses: Set<CameraLens> = [.wide]
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil { lenses.insert(.ultraWide) }
        if AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil { lenses.insert(.telephoto) }
        lenses.insert(.frontWide)
        DispatchQueue.main.async { self.availableLenses = lenses }
    }

    // MARK: 选择最匹配的 activeFormat
    private func bestFormat(_ d: AVCaptureDevice, q: QualityOption, fps: Int) -> AVCaptureDevice.Format? {
        let tw = q.targetWidth, th = q.targetHeight
        let wantRatio = Double(tw) / Double(th)
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
            let ratio = Double(dim.width) / Double(dim.height)
            let ratioDiff = abs(ratio - wantRatio)

            var score = 0.0
            // 比例匹配权重最高
            score -= ratioDiff * 10000
            // 分辨率接近
            let resDiff = abs(Double(dim.width) - Double(tw)) / Double(tw)
                          + abs(Double(dim.height) - Double(th)) / Double(th)
            score -= resDiff * 100
            // 帧率支持（高帧率优先满足）
            if fps > 0 {
                if maxFps + 0.5 >= Double(fps) { score += 50 } else { score -= 200 }
            }
            // 避免照片专用 binned 格式（高分低帧率的静态照片格式）
            if maxFps < 24 { score -= 100 }

            if score > bestScore { bestScore = score; best = f }
        }
        return best
    }

    // MARK: 构建采集会话
    private func buildSession(mic: Bool? = nil) {
        discoverBackLenses()

        // 决定使用的物理设备
        var wantType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
        var wantPos: AVCaptureDevice.Position = currentLens.position
        if wantPos == .back, let v = backVirtual {
            // 后置虚拟设备可承担所有后摄镜头
            device = v
        } else {
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

        // 关键：使用 activeFormat 时必须 inputPriority
        session.sessionPreset = .inputPriority

        guard let vInput = try? AVCaptureDeviceInput(device: dev), session.canAddInput(vInput) else {
            session.commitConfiguration(); flash("无法添加摄像头"); return
        }
        session.addInput(vInput)

        if mic != false, let micDev = AVCaptureDevice.default(for: .audio),
           let mInput = try? AVCaptureDeviceInput(device: micDev), session.canAddInput(mInput) {
            session.addInput(mInput)
        }

        vOut.alwaysDiscardsLateVideoFrames = true
        vOut.setSampleBufferDelegate(self, queue: sq)
        if session.canAddOutput(vOut) { session.addOutput(vOut) }

        aOut.setSampleBufferDelegate(self, queue: sq)
        if mic != false, session.canAddOutput(aOut) { session.addOutput(aOut) }

        if let c = vOut.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = (wantPos == .front)
        }

        // 选择格式与帧率（需持有 device lock）
        do {
            try dev.lockForConfiguration()
            applyFormatLocked(dev)
            dev.unlockForConfiguration()
        } catch {
            print("[FMT] lock error: \(error)")
        }

        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }

        // 应用虚拟设备变焦（镜头切换）
        if wantPos == .back, backVirtual === dev {
            let z = backVirtualZooms[currentLens] ?? 1.0
            do { try dev.lockForConfiguration(); dev.videoZoomFactor = z; dev.unlockForConfiguration() } catch {}
        }

        applyStabilizationLocked()
    }

    /// 选择并应用格式。调用方必须已持有 device 的 configuration lock，且处于 begin/commit 之间。
    private func applyFormatLocked(_ dev: AVCaptureDevice) {
        let wantFps = frameRate.rawValue
        guard let fmt = bestFormat(dev, q: quality, fps: wantFps) else {
            print("[FMT] no match, fallback 1080p")
            return
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
        let realMaxFps = fmt.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
        DispatchQueue.main.async {
            self.actualFormat = "\(dim.width)×\(dim.height) @\(Int(realMaxFps))"
        }
        // 用实际格式尺寸配置编码器
        let br: Int
        if dim.width >= 3840 { br = 32_000_000 }
        else if dim.width >= 1920 { br = 10_000_000 }
        else { br = 5_000_000 }
        let encFps: Int32 = wantFps > 0 ? Int32(min(wantFps, Int(realMaxFps))) : 30
        enc.configure(width: dim.width, height: dim.height, fps: max(encFps, 24), bitRate: br)
        enc.onEncoded = { [weak self] sb in
            self?.sq.async {
                guard let self = self else { return }
                if self.preSec > 0 { self.vRing.append(sb) }
                if self.recording { self.rec.appendVideo(sb) }
            }
        }
        vRing = SampleRingBuffer(maxSeconds: max(preSec, 1))
        aRing = SampleRingBuffer(maxSeconds: max(preSec, 1))
    }

    // MARK: 镜头切换
    func switchLens(_ lens: CameraLens) {
        guard availableLenses.contains(lens), lens != currentLens else { return }
        Beep.shared.tap()
        // 判断是否为安全的虚拟后摄变焦（录制中也允许）
        let safeZoom = lens.position == .back && backVirtual != nil
            && backVirtual === device
        if isRecording && !safeZoom { flash("录制中无法切换到该镜头"); return }
        currentLens = lens
        sq.async { [weak self] in
            guard let self = self else { return }
            // 虚拟后摄：直接变焦，无缝不中断
            if lens.position == .back, let v = self.backVirtual, self.device === v {
                let z = self.backVirtualZooms[lens] ?? 1.0
                do { try v.lockForConfiguration()
                    v.videoZoomFactor = z
                    v.unlockForConfiguration()
                } catch { print("[LENS] zoom error \(error)") }
            } else {
                // 前置或独立镜头：重建会话
                self.buildSession()
            }
        }
    }

    // MARK: 设置
    func setQuality(_ q: QualityOption) {
        guard q != quality else { return }
        if isRecording { flash("录制中无法切换分辨率"); return }
        quality = q; Beep.shared.tap()
        sq.async { [weak self] in
            guard let self = self, let d = self.device else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority
            do {
                try d.lockForConfiguration()
                self.applyFormatLocked(d)
                d.unlockForConfiguration()
            } catch {}
            self.session.commitConfiguration()
        }
    }

    func setFrameRate(_ f: FrameRateOption) {
        guard f != frameRate else { return }
        if isRecording { flash("录制中无法切换帧率"); return }
        frameRate = f; Beep.shared.tap()
        sq.async { [weak self] in
            guard let self = self, let d = self.device else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority
            do {
                try d.lockForConfiguration()
                self.applyFormatLocked(d)
                d.unlockForConfiguration()
            } catch {}
            self.session.commitConfiguration()
        }
    }

    func setPreRecord(_ p: PreRecordOption) {
        preRecord = p; Beep.shared.tap(); preSec = p.seconds
        sq.async { [weak self] in
            self?.vRing = SampleRingBuffer(maxSeconds: max(p.seconds, 1))
            self?.aRing = SampleRingBuffer(maxSeconds: max(p.seconds, 1))
        }
    }

    func setStabilization(_ s: StabilizationLevel) {
        stabilization = s; Beep.shared.tap()
        sq.async { [weak self] in self?.applyStabilizationLocked() }
    }

    private func applyStabilizationLocked() {
        guard let c = vOut.connection(with: .video), c.isVideoStabilizationSupported else { return }
        c.preferredVideoStabilizationMode = stabilization.mode
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
        sq.async { [weak self] in
            guard let self = self, !self.recording else { return }
            // 等编码器就绪
            var tries = 0
            while self.enc.formatDescription == nil && tries < 100 { usleep(10000); tries += 1 }

            let v = self.preSec > 0 ? self.vRing.snapshot() : []
            let a = self.preSec > 0 ? self.aRing.snapshot() : []
            let url = self.makeURL()
            let portrait = self.currentLens.position == .back || self.currentLens == .frontWide
            let ok = self.rec.begin(video: v, audio: a, url: url,
                                    format: self.enc.formatDescription, portrait: portrait)
            guard ok else {
                DispatchQueue.main.async { self.flash("无法开始录制") }
                return
            }
            self.recording = true
            DispatchQueue.main.async { self.isRecording = true; Beep.shared.start() }
        }
    }

    func stopRecording() {
        delayTimer?.invalidate(); delayTimer = nil; countdown = nil
        Beep.shared.stop()
        sq.async { [weak self] in
            guard let self = self, self.recording else { return }
            self.recording = false
            DispatchQueue.main.async { self.isRecording = false; self.isSaving = true }
            self.rec.finish { [weak self] url in
                guard let self = self else { return }
                guard let url = url else {
                    self.isSaving = false; self.flash("保存失败"); return
                }
                PhotoSaver.save(url) { ok in
                    self.isSaving = false
                    self.flash(ok ? "已保存到相册" : "保存失败")
                    try? FileManager.default.removeItem(at: url)
                }
            }
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

// MARK: 采集回调
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                       from c: AVCaptureConnection) {
        if o === vOut {
            enc.encode(sb)
        } else if o === aOut {
            if preSec > 0 { aRing.append(sb) }
            if recording { rec.appendAudio(sb) }
            VoiceController.shared.enqueue(sb)
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

// MARK: - 主题
enum T {
    static let accent = Color(red: 0.15, green: 0.78, blue: 0.65)
    static let rec = Color(red: 0.95, green: 0.30, blue: 0.25)
    static let panel = Color.black.opacity(0.55)
    static let cell = Color(red: 0.16, green: 0.16, blue: 0.18)
}

// MARK: - 主界面
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
                        .foregroundStyle(.white.opacity(0.7))
                    Text("需要相机权限").font(.headline).foregroundStyle(.white)
                    Button("打开系统设置") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(T.accent).foregroundStyle(.black).clipShape(Capsule())
                }
            }

            // 顶部
            VStack {
                HStack(spacing: 8) {
                    Text(e.isRecording ? "● REC" : (e.preSec > 0 ? "预录\(Int(e.preSec))s" : "STBY"))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(e.isRecording ? T.rec : .white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(T.panel).cornerRadius(6)
                    if e.isVoiceOn {
                        Label("语音", systemImage: "mic.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(T.accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(T.panel).cornerRadius(6)
                    }
                    Spacer()
                    Text("\(Int(e.battery * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(T.panel).cornerRadius(6)
                    IconButton(e.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                               on: e.torchOn) { e.toggleTorch() }
                    IconButton("gearshape.fill", on: false) { showSettings = true }
                }
                .padding(.horizontal, 12).padding(.top, 6)
                Spacer()
            }

            // 实际格式提示
            VStack {
                Spacer().frame(height: 50)
                if !e.actualFormat.isEmpty {
                    Text(e.actualFormat)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(T.panel).cornerRadius(4)
                }
                Spacer()
            }

            if let c = e.countdown {
                Text("\(c)").font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).shadow(radius: 10)
            }

            if let m = e.toast {
                VStack {
                    Spacer().frame(height: 110)
                    Text(m).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(T.panel).cornerRadius(20)
                    Spacer()
                }
            }

            if e.isSaving {
                VStack {
                    Spacer()
                    Text("保存中…").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(T.panel).cornerRadius(16)
                        .padding(.bottom, 120)
                }
            }

            // 底部
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    Button { e.toggleVoice() } label: {
                        ZStack {
                            Circle().fill(e.isVoiceOn ? T.accent : T.panel).frame(width: 56, height: 56)
                            Image(systemName: e.isVoiceOn ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(e.isVoiceOn ? .black : .white)
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
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(T.panel).clipShape(Circle())
                    }
                }
                .padding(.bottom, 34)
            }
        }
        .statusBarHidden(true)
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
                .foregroundStyle(on ? T.accent : .white)
                .frame(width: 34, height: 34).background(T.panel).clipShape(Circle())
        }
    }
}

// MARK: - 设置
struct Settings: View {
    @ObservedObject var e: CameraEngine
    @Environment(\.dismiss) private var dismiss
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
                    section("预录时长") {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(PreRecordOption.allCases, id: \.self) { v in
                                Cell(v.label, sel: e.preRecord == v) { e.setPreRecord(v) }
                            }
                        }
                    }
                    section("镜头（仅显示本机支持）") {
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
                    section("帧率（高帧率需设备支持）") {
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
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea())
            .navigationTitle("相机设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.bold().foregroundStyle(T.accent)
                }
            }
        }.preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.5))
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
                .foregroundStyle(!enabled ? Color.gray.opacity(0.4) : (sel ? .black : .white))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(sel ? T.accent : T.cell)
                .cornerRadius(10)
        }.disabled(!enabled)
    }
}

struct ToggleRow: View {
    let title: String; @Binding var on: Bool
    init(_ title: String, _ on: Binding<Bool>) { self.title = title; self._on = on }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: $on).labelsHidden().tint(T.accent)
        }
        .padding(.horizontal, 14).frame(height: 46).background(T.cell).cornerRadius(10)
    }
}
