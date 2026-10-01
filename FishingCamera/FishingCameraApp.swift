import SwiftUI
import AVFoundation
import Photos
import CoreMotion
import UIKit
import AudioToolbox
import Speech
import MediaPlayer
import VideoToolbox

// MARK: - App 入口
@main
struct FishingCameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}

// MARK: - 设计系统
enum Design {
    // 主色
    static let accent = Color(red: 0.20, green: 0.83, blue: 0.60)          // 薄荷绿
    static let recordRed = Color(red: 0.96, green: 0.26, blue: 0.21)        // 录制红
    static let warmYellow = Color(red: 0.98, green: 0.75, blue: 0.20)
    // 背景
    static let bgTop = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let bgBottom = Color(red: 0.03, green: 0.03, blue: 0.05)
    static let cardBg = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let cardBgActive = Color(red: 0.16, green: 0.22, blue: 0.24)
    // 玻璃
    static let glassBg = Color.black.opacity(0.45)
    static let glassBorder = Color.white.opacity(0.12)
    // 圆角
    static let radius: CGFloat = 16
    static let chipRadius: CGFloat = 12
    // 字体
    static func title(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static func body(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular, design: .rounded)
    }
    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

// MARK: - 环形缓冲区
struct CircularFrameBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.storage = Array(repeating: nil, count: capacity)
    }
    mutating func write(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }
    func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        var r: [Element] = []; r.reserveCapacity(count)
        let start = count < capacity ? 0 : writeIndex
        for o in 0..<count {
            let i = (start + o) % capacity
            if let e = storage[i] { r.append(e) }
        }
        return r
    }
}

// MARK: - 枚举
enum CameraLens: String, CaseIterable {
    case ultraWide = "超广角", wide = "广角", telephoto = "长焦", frontWide = "前置"
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .frontWide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }
    var position: AVCaptureDevice.Position { self == .frontWide ? .front : .back }
    var isAvailable: Bool { AVCaptureDevice.default(deviceType, for: .video, position: position) != nil }
    var icon: String {
        switch self {
        case .ultraWide: return "camera.aperture"
        case .wide: return "camera"
        case .telephoto: return "camera.macro"
        case .frontWide: return "camera.metering.center.weighted"
        }
    }
}

enum VideoResolution: String, CaseIterable {
    case uhd4K = "4K", uhd4K4x3 = "4K (4:3)"
    case k3_4x3 = "3K (4:3)", k2_5_4x3 = "2.5K (4:3)"
    case k2_4x3 = "2K (4:3)", hd1080 = "1080p"
    case hd1080_4x3 = "1080p (4:3)", hd720 = "720p"

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .uhd4K, .uhd4K4x3: return .hd4K3840x2160
        case .hd720: return .hd1280x720
        default: return .hd1920x1080
        }
    }
    // ✅ 修复：4:3 输出尺寸全部修正
    var outputSize: (w: Int, h: Int) {
        switch self {
        case .uhd4K: return (3840, 2160)
        case .uhd4K4x3: return (3840, 2880)
        case .k3_4x3: return (3072, 2304)
        case .k2_5_4x3: return (2560, 1920)
        case .k2_4x3: return (2048, 1536)
        case .hd1080: return (1920, 1080)
        case .hd1080_4x3: return (1920, 1440)
        case .hd720: return (1280, 720)
        }
    }
    var maxFrameRate: Int {
        switch self {
        case .uhd4K, .uhd4K4x3: return 60
        case .k3_4x3: return 120
        default: return 240
        }
    }
}

enum FrameRateOption: Int, CaseIterable {
    case fps24 = 24, fps25 = 25, fps30 = 30, fps48 = 48
    case fps50 = 50, fps60 = 60, fps120 = 120, fps240 = 240
    var displayName: String { "\(rawValue)fps" }
}

enum StabilizationLevel: String, CaseIterable {
    case off = "关", standard = "标准", smooth = "平滑"
    case enhanced = "增强", superMode = "超强", auto = "自动"
    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .smooth: return .cinematic
        case .enhanced, .superMode:
            if #available(iOS 13.0, *) { return .cinematicExtended }
            return .cinematic
        case .auto: return .auto
        }
    }
    var icon: String {
        switch self {
        case .off: return "hand.raised.slash.fill"
        case .standard: return "hand.raised.fill"
        case .smooth: return "figure.walk"
        case .enhanced: return "figure.run"
        case .superMode: return "figure.strengthtraining.traditional"
        case .auto: return "wand.and.stars"
        }
    }
}

enum PreRecordOption: String, CaseIterable {
    case off = "关", s5 = "5秒", s15 = "15秒", s30 = "30秒", m1 = "1分钟", m2 = "2分钟"
    var seconds: TimeInterval {
        switch self {
        case .off: return 0
        case .s5: return 5; case .s15: return 15; case .s30: return 30
        case .m1: return 60; case .m2: return 120
        }
    }
}

enum ScreenOffOption: String, CaseIterable {
    case s5 = "5秒", s15 = "15秒", s30 = "30秒"
    case m1 = "1分钟", m5 = "5分钟", never = "永不熄屏"
    var seconds: TimeInterval {
        switch self {
        case .s5: return 5; case .s15: return 15; case .s30: return 30
        case .m1: return 60; case .m5: return 300; case .never: return 0
        }
    }
}

enum VideoOrientationOption: String, CaseIterable {
    case portrait = "纵向", landscape = "横向"
    var avOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .landscape: return .landscapeRight
        }
    }
    var icon: String {
        self == .portrait ? "iphone" : "iphone.landscape"
    }
}

enum PreviewMode: String, CaseIterable {
    case fullScreen = "全屏", adaptive = "自适应"
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fullScreen: return .resizeAspectFill
        case .adaptive: return .resizeAspect
        }
    }
}

// MARK: - 音频反馈
final class AudioFeedback {
    private let synthesizer = AVSpeechSynthesizer()
    func sayStart() {
        AudioServicesPlaySystemSound(1113)
        speak("开始录像")
    }
    func sayStop() {
        AudioServicesPlaySystemSound(1114)
        speak("停止录像")
    }
    func sayInterrupted() { speak("来电中断，已保存") }

    private func speak(_ t: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.52; u.volume = 1.0
        synthesizer.speak(u)
    }
}

// MARK: - H.264 编码器
final class H264VideoEncoder {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    var onEncodedSample: ((CMSampleBuffer) -> Void)?

    func setup(width: Int, height: Int, fps: Int, bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = session {
            VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(old); session = nil
        }
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        var ns: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sb in
                guard status == noErr, let s = sb, let r = refcon else { return }
                Unmanaged<H264VideoEncoder>.fromOpaque(r).takeUnretainedValue().onEncodedSample?(s)
            },
            outputCallbackRefCon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &ns)
        guard st == noErr, let s = ns else { return }
        VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) {
        lock.lock(); let s = session; lock.unlock()
        guard let session = s else { return }
        var props: [String: Any] = [:]
        if forceKeyframe { props[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: props.isEmpty ? nil : props as CFDictionary,
            sourceFrameRefCon: nil, infoFlagsOut: nil)
    }

    deinit {
        lock.lock(); defer { lock.unlock() }
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }
}

// MARK: - 相机引擎
final class CameraEngine: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var currentLens: CameraLens = .wide
    @Published var videoResolution: VideoResolution = .hd1080
    @Published var frameRate: FrameRateOption = .fps30
    @Published var stabilizationLevel: StabilizationLevel = .auto
    @Published var preRecordOption: PreRecordOption = .s30
    @Published var screenOffOption: ScreenOffOption = .never
    @Published var previewMode: PreviewMode = .fullScreen
    @Published var videoOrientation: VideoOrientationOption = .portrait
    @Published var mirrorHorizontal: Bool = false
    @Published var mirrorVertical: Bool = false
    @Published var showGrid: Bool = false
    @Published var showLevel: Bool = false
    @Published var voiceEnabled: Bool = true
    @Published var interruptOnPhoneCall: Bool = true
    @Published var shutterSoundEnabled: Bool = true
    @Published var batteryLevel: Float = 1.0
    @Published var lastSavedMessage: String?
    @Published var isVoiceListening = false
    @Published var isScreenOffMode = false
    @Published var customStartWords: [String] = ["开始录像", "开始录制", "录一下"]
    @Published var customStopWords: [String] = ["结束录像", "停止录像", "停止录制", "结束录制", "保存"]

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.fishingcamera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentVideoDevice: AVCaptureDevice?
    private let encoder = H264VideoEncoder()
    private var compressedVideoBuffer: CircularFrameBuffer<CMSampleBuffer>?
    private var audioBuffer: CircularFrameBuffer<CMSampleBuffer>?
    private let writer = PreRecordWriter()
    private var isRecordingInternal = false
    private var preRecordOnInternal = false
    private let batteryManager = BatteryManager()
    private let voiceManager = VoiceCommandManager()
    private let audioFeedback = AudioFeedback()
    private var screenOffTimer: Timer?
    private let suppressLock = NSLock()
    private var suppressUntil: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    private func shouldSuppressVoice() -> Bool {
        suppressLock.lock(); defer { suppressLock.unlock() }
        return Date().timeIntervalSince1970 < suppressUntil
    }
    private func suppressVoice(_ s: TimeInterval) {
        suppressLock.lock()
        suppressUntil = Date().timeIntervalSince1970 + s
        suppressLock.unlock()
    }

    override init() {
        super.init()

        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .videoChat,
                           options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? s.setActive(true)

        voiceManager.onStart = { [weak self] in
            guard let self = self, !self.shouldSuppressVoice(), !self.isRecordingInternal else { return }
            self.startRecording()
        }
        voiceManager.onStop = { [weak self] in
            guard let self = self, !self.shouldSuppressVoice(), self.isRecordingInternal else { return }
            self.stopRecording()
        }
        encoder.onEncodedSample = { [weak self] sb in
            guard let self = self else { return }
            self.sessionQueue.async {
                if self.preRecordOnInternal { self.compressedVideoBuffer?.write(sb) }
                if self.isRecordingInternal { self.writer.appendVideo(sb) }
            }
        }
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRecording == true ? self?.stopRecording() : self?.startRecording()
            }
            return .success
        }
        let interruptObs = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: captureSession, queue: .main
        ) { [weak self] _ in self?.handleInterruption() }
        let resumeObs = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: captureSession, queue: .main
        ) { _ in }
        observers = [interruptObs, resumeObs]
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func handleInterruption() {
        guard interruptOnPhoneCall, isRecording else { return }
        audioFeedback.sayInterrupted()
        stopRecording()
        lastSavedMessage = "来电中断，已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.lastSavedMessage = nil
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            if self.captureSession.canSetSessionPreset(self.videoResolution.sessionPreset) {
                self.captureSession.sessionPreset = self.videoResolution.sessionPreset
            }
            guard let device = self.deviceFor(self.currentLens),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration(); return
            }
            self.captureSession.addInput(input)
            self.currentVideoDevice = device

            if let audio = AVCaptureDevice.default(for: .audio),
               let aInput = try? AVCaptureDeviceInput(device: audio),
               self.captureSession.canAddInput(aInput) {
                self.captureSession.addInput(aInput)
            }
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            if self.captureSession.canAddOutput(self.videoOutput) { self.captureSession.addOutput(self.videoOutput) }
            self.audioOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            if self.captureSession.canAddOutput(self.audioOutput) { self.captureSession.addOutput(self.audioOutput) }

            self.applyAllConnectionSettings()
            self.captureSession.commitConfiguration()
            self.setupEncoder()
            self.rebuildBuffers()
            self.applyFrameRate()
            self.captureSession.startRunning()

            DispatchQueue.main.async {
                self.batteryManager.start { [weak self] lvl in self?.batteryLevel = lvl }
                self.startVoiceListening()
                self.resetScreenOffTimer()
            }
        }
    }

    private func applyAllConnectionSettings() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        if conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = stabilizationLevel.avMode
        }
        if conn.isVideoOrientationSupported {
            conn.videoOrientation = videoOrientation.avOrientation
        }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = mirrorHorizontal
        }
    }

    private func setupEncoder() {
        let (w, h) = videoResolution.outputSize
        let fps = frameRate.rawValue
        encoder.setup(width: w, height: h, fps: fps, bitrate: computeBitrate(resolution: videoResolution, fps: fps))
    }

    private func computeBitrate(resolution: VideoResolution, fps: Int) -> Int {
        let base: Int
        switch resolution {
        case .uhd4K, .uhd4K4x3: base = 40_000_000
        case .k3_4x3, .k2_5_4x3: base = 30_000_000
        case .k2_4x3: base = 20_000_000
        case .hd1080, .hd1080_4x3: base = 16_000_000
        case .hd720: base = 8_000_000
        }
        return base * max(fps, 24) / 30
    }

    private func deviceFor(_ lens: CameraLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position)
    }

    private func rebuildBuffers() {
        let sec = preRecordOption.seconds
        if sec <= 0 {
            compressedVideoBuffer = nil
            audioBuffer = nil
            preRecordOnInternal = false
            return
        }
        preRecordOnInternal = true
        compressedVideoBuffer = CircularFrameBuffer<CMSampleBuffer>(capacity: Int(30.0 * sec))
        audioBuffer = CircularFrameBuffer<CMSampleBuffer>(capacity: Int(43.0 * sec))
    }

    private func applyFrameRate() {
        guard let device = currentVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            let d = Double(frameRate.rawValue)
            let f = min(d, Double(videoResolution.maxFrameRate))
            let fmt = device.activeFormat
            if fmt.videoSupportedFrameRateRanges.contains(where: { f >= $0.minFrameRate && f <= $0.maxFrameRate }) {
                let dur = CMTime(value: 1, timescale: CMTimeScale(f))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func startVoiceListening() {
        guard voiceEnabled else { return }
        voiceManager.startWords = customStartWords
        voiceManager.stopWords = customStopWords
        voiceManager.start { [weak self] l in self?.isVoiceListening = l }
    }

    // MARK: - 用户操作
    func switchLens(_ lens: CameraLens) {
        guard lens.isAvailable else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .filter { $0.device.hasMediaType(.video) }
                .forEach { self.captureSession.removeInput($0) }
            guard let d = self.deviceFor(lens),
                  let i = try? AVCaptureDeviceInput(device: d),
                  self.captureSession.canAddInput(i) else {
                self.captureSession.commitConfiguration(); return
            }
            self.captureSession.addInput(i)
            self.currentVideoDevice = d
            self.applyAllConnectionSettings()
            self.captureSession.commitConfiguration()
            self.setupEncoder()
            DispatchQueue.main.async { self.currentLens = lens }
        }
    }

    func setResolution(_ r: VideoResolution) {
        DispatchQueue.main.async { self.videoResolution = r }
        if frameRate.rawValue > r.maxFrameRate {
            DispatchQueue.main.async { self.frameRate = .fps30 }
        }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            if self.captureSession.canSetSessionPreset(r.sessionPreset) {
                self.captureSession.sessionPreset = r.sessionPreset
            }
            self.captureSession.commitConfiguration()
            self.setupEncoder()
            self.rebuildBuffers()
            self.applyFrameRate()
        }
    }

    func setFrameRate(_ f: FrameRateOption) {
        guard f.rawValue <= videoResolution.maxFrameRate else { return }
        DispatchQueue.main.async { self.frameRate = f }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupEncoder(); self.applyFrameRate(); self.rebuildBuffers()
        }
    }

    func setStabilization(_ s: StabilizationLevel) {
        DispatchQueue.main.async { self.stabilizationLevel = s }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let c = self.videoOutput.connection(with: .video), c.isVideoStabilizationSupported {
                c.preferredVideoStabilizationMode = s.avMode
            }
        }
    }

    func setPreRecord(_ p: PreRecordOption) {
        DispatchQueue.main.async { self.preRecordOption = p }
        sessionQueue.async { [weak self] in self?.rebuildBuffers() }
    }

    func setScreenOffOption(_ o: ScreenOffOption) {
        DispatchQueue.main.async {
            self.screenOffOption = o
            self.resetScreenOffTimer()
        }
    }

    func setVideoOrientation(_ o: VideoOrientationOption) {
        DispatchQueue.main.async { self.videoOrientation = o }
        sessionQueue.async { [weak self] in
            guard let self = self, let c = self.videoOutput.connection(with: .video),
                  c.isVideoOrientationSupported else { return }
            c.videoOrientation = o.avOrientation
        }
    }

    func setMirrorHorizontal(_ on: Bool) {
        DispatchQueue.main.async { self.mirrorHorizontal = on }
        sessionQueue.async { [weak self] in
            guard let self = self, let c = self.videoOutput.connection(with: .video),
                  c.isVideoMirroringSupported else { return }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = on
        }
    }

    func setMirrorVertical(_ on: Bool) {
        DispatchQueue.main.async { self.mirrorVertical = on }
    }

    func setPreviewMode(_ m: PreviewMode) {
        DispatchQueue.main.async { self.previewMode = m }
    }

    func resetScreenOffTimer() {
        screenOffTimer?.invalidate(); screenOffTimer = nil
        let s = screenOffOption.seconds
        guard s > 0 else { return }
        screenOffTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.isScreenOffMode = true }
        }
    }

    func unlockScreen() {
        isScreenOffMode = false
        resetScreenOffTimer()
    }

    // ✅ 修复：关闭语音时同时停止识别任务
    func toggleVoice() {
        voiceEnabled.toggle()
        if voiceEnabled {
            startVoiceListening()
        } else {
            voiceManager.stop()
        }
    }

    // MARK: - 录制
    func startRecording() {
        guard !isRecordingInternal else { return }
        // ✅ 修复：仅在开关打开时播放快门声
        if shutterSoundEnabled {
            audioFeedback.sayStart()
        }
        suppressVoice(seconds: 2.0)
        resetScreenOffTimer()

        sessionQueue.async { [weak self] in
            guard let self = self, !self.isRecordingInternal else { return }
            let all = self.compressedVideoBuffer?.snapshot() ?? []
            let valid = self.trimToKeyframe(all)
            let audios = self.audioBuffer?.snapshot() ?? []
            self.writer.begin(
                videoSamples: valid, audioSamples: audios,
                outputURL: self.makeURL(),
                mirrorVertical: self.mirrorVertical
            )
            self.isRecordingInternal = true
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    private func trimToKeyframe(_ samples: [CMSampleBuffer]) -> [CMSampleBuffer] {
        for (i, s) in samples.enumerated() {
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) else {
                return Array(samples[i...])
            }
            if CFArrayGetCount(arr) == 0 { return Array(samples[i...]) }
            guard let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary?.self) else {
                return Array(samples[i...])
            }
            let notSync = CFDictionaryContainsKey(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            if !notSync { return Array(samples[i...]) }
        }
        return samples
    }

    func stopRecording() {
        guard isRecordingInternal else { return }
        if shutterSoundEnabled { audioFeedback.sayStop() }
        suppressVoice(seconds: 2.0)
        resetScreenOffTimer()
        sessionQueue.async { [weak self] in
            guard let self = self, self.isRecordingInternal else { return }
            self.writer.end()
            self.isRecordingInternal = false
            DispatchQueue.main.async {
                self.isRecording = false
                self.lastSavedMessage = "已保存到相册"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.lastSavedMessage = nil }
            }
        }
    }

    private func makeURL() -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        return d.appendingPathComponent("Fishing_\(f.string(from: Date())).mp4")
    }
}

// MARK: - 数据输出
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            encoder.encode(pixelBuffer: pb, presentationTime: pts, forceKeyframe: isRecordingInternal)
        } else if output === audioOutput {
            if preRecordOnInternal, let b = audioBuffer { b.write(sb) }
            if isRecordingInternal { writer.appendAudio(sb) }
            voiceManager.feedAudio(sb)
        }
    }
}

// MARK: - 写入器
final class PreRecordWriter {
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?
    private var active = false
    private var url: URL?
    private var appendedVideo = 0

    func begin(videoSamples: [CMSampleBuffer], audioSamples: [CMSampleBuffer],
               outputURL: URL, mirrorVertical: Bool) {
        guard !active else { return }
        url = outputURL; appendedVideo = 0
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            vInput?.expectsMediaDataInRealTime = false
            if mirrorVertical {
                var t = CGAffineTransform.identity
                t = t.translatedBy(x: 0, y: 1)
                t = t.scaledBy(x: 1, y: -1)
                vInput?.transform = t
            }
            let aS: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]
            aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aS)
            aInput?.expectsMediaDataInRealTime = true
            if let v = vInput, writer!.canAdd(v) { writer!.add(v) }
            if let a = aInput, writer!.canAdd(a) { writer!.add(a) }
            guard writer!.startWriting() else { cleanup(); return }
            var startTime = CMTime.zero
            var hasStart = false
            if let fv = videoSamples.first {
                startTime = CMSampleBufferGetPresentationTimeStamp(fv); hasStart = true
            }
            if let fa = audioSamples.first {
                let a = CMSampleBufferGetPresentationTimeStamp(fa)
                if !hasStart || CMTimeCompare(a, startTime) < 0 { startTime = a }
                hasStart = true
            }
            writer?.startSession(atSourceTime: hasStart ? startTime : .zero)
            active = true
            let mx = max(videoSamples.count, audioSamples.count)
            for i in 0..<mx {
                if i < videoSamples.count {
                    let s = videoSamples[i]
                    if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(s), startTime) >= 0 { appendVideo(s) }
                }
                if i < audioSamples.count {
                    let s = audioSamples[i]
                    if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(s), startTime) >= 0 { appendAudio(s) }
                }
            }
        } catch { print("[Writer] \(error)"); cleanup() }
    }

    func appendVideo(_ s: CMSampleBuffer) {
        guard active, let i = vInput, i.isReadyForMoreMediaData else { return }
        if i.append(s) { appendedVideo += 1 }
    }
    func appendAudio(_ s: CMSampleBuffer) {
        guard active, let i = aInput, i.isReadyForMoreMediaData else { return }
        _ = i.append(s)
    }

    func end() {
        guard active, let w = writer else { cleanup(); return }
        guard w.status == .writing, appendedVideo > 0 else {
            w.cancelWriting(); cleanup(); return
        }
        vInput?.markAsFinished(); aInput?.markAsFinished()
        let u = url; let ref = w
        writer = nil; vInput = nil; aInput = nil; active = false; url = nil
        ref.finishWriting {
            if ref.status == .completed, let u = u { PhotoLibrarySaver.save(u) }
        }
    }
    private func cleanup() {
        writer = nil; vInput = nil; aInput = nil
        active = false; url = nil; appendedVideo = 0
    }
}

enum PhotoLibrarySaver {
    static func save(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, _ in }
        }
    }
}

// MARK: - 电池
final class BatteryManager {
    private var timer: Timer?
    private var cb: ((Float) -> Void)?
    func start(_ cb: @escaping (Float) -> Void) {
        self.cb = cb
        UIDevice.current.isBatteryMonitoringEnabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.cb?(UIDevice.current.batteryLevel)
        }
    }
    deinit { timer?.invalidate(); UIDevice.current.isBatteryMonitoringEnabled = false }
}

// MARK: - 水平仪
final class MotionManager: ObservableObject {
    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false
    private let m = CMMotionManager()
    func start() {
        guard m.isDeviceMotionAvailable else { return }
        m.deviceMotionUpdateInterval = 1.0 / 30.0
        m.startDeviceMotionUpdates(to: .main) { [weak self] d, _ in
            guard let d = d, let self = self else { return }
            self.roll = d.attitude.roll
            self.pitch = d.attitude.pitch
            self.isLevel = abs(self.roll) < 0.03 && abs(self.pitch) < 0.03
        }
    }
    func stop() { m.stopDeviceMotionUpdates() }
}

// MARK: - 语音控制
final class VoiceCommandManager {
    var onStart: (() -> Void)?
    var onStop:  (() -> Void)?
    var startWords: [String] = ["开始录像", "开始录制", "录一下"]
    var stopWords: [String] = ["结束录像", "停止录像", "停止录制", "结束录制", "保存"]
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var running = false
    private var onListeningChanged: ((Bool) -> Void)?
    private var lastStart: TimeInterval = 0
    private var lastStop: TimeInterval = 0
    private let reqLock = NSLock()

    func start(_ onChange: @escaping (Bool) -> Void) {
        guard !running else { return }
        onListeningChanged = onChange
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            guard st == .authorized else { return }
            DispatchQueue.main.async { self?.begin() }
        }
    }

    private func begin() {
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if rec?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
        reqLock.lock(); request = r; reqLock.unlock()
        task = rec?.recognitionTask(with: r) { [weak self] result, err in
            guard let self = self else { return }
            if let res = result {
                let t = res.bestTranscription.formattedString.replacingOccurrences(of: " ", with: "")
                let now = Date().timeIntervalSince1970
                if self.startWords.contains(where: { t.contains($0) }) {
                    if now - self.lastStart > 2.0 {
                        self.lastStart = now
                        self.onStart?()
                    }
                } else if self.stopWords.contains(where: { t.contains($0) }) {
                    if now - self.lastStop > 2.0 {
                        self.lastStop = now
                        self.onStop?()
                    }
                }
            }
            if err != nil || (result?.isFinal ?? false) { self.restart() }
        }
        running = true
        DispatchQueue.main.async { self.onListeningChanged?(true) }
    }

    private func restart() {
        task?.cancel(); task = nil
        reqLock.lock(); request = nil; reqLock.unlock()
        running = false
        DispatchQueue.main.async { self.onListeningChanged?(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.begin() }
    }

    func feedAudio(_ sb: CMSampleBuffer) {
        guard running else { return }
        reqLock.lock(); let r = request; reqLock.unlock()
        guard let r = r, let pcm = sb.toPCMBuffer() else { return }
        r.append(pcm)
    }

    func stop() {
        task?.cancel(); task = nil
        reqLock.lock(); request = nil; reqLock.unlock()
        running = false
        DispatchQueue.main.async { self.onListeningChanged?(false) }
    }
}

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let d = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) else { return nil }
        guard let f = AVAudioFormat(streamDescription: asbd) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n) else { return nil }
        buf.frameLength = n
        var abl = AudioBufferList(); var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self, bufferListSizeNeededOut: nil,
            bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        guard st == noErr else { return nil }
        let src = UnsafeMutableAudioBufferListPointer(&abl)
        let dst = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let s = src[i].mData, let d = dst[i].mData {
                memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
            }
        }
        return buf
    }
}

// MARK: - 音量键
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
        let i = AVCaptureEventInteraction { e in
            if e.phase == .ended { DispatchQueue.main.async { action() } }
        }
        v.addInteraction(i); return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
extension View {
    func onVolumeButton(_ a: @escaping () -> Void) -> some View {
        modifier(VolumeButtonModifier(action: a))
    }
}

// MARK: - 预览
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let gravity: AVLayerVideoGravity
    let orientation: AVCaptureVideoOrientation
    let mirrored: Bool

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = gravity
        if let c = v.previewLayer.connection {
            if c.isVideoOrientationSupported { c.videoOrientation = orientation }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = mirrored
            }
        }
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.videoGravity = gravity
        if let c = uiView.previewLayer.connection {
            if c.isVideoOrientationSupported { c.videoOrientation = orientation }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = mirrored
            }
        }
    }
}
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 网格
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
            .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }
    }
}

// MARK: - 水平仪
struct LevelOverlay: View {
    @ObservedObject var motion: MotionManager
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(motion.isLevel ? Design.accent : Design.warmYellow, lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                Rectangle()
                    .fill(motion.isLevel ? Design.accent : Design.warmYellow)
                    .frame(width: 36, height: 1)
                    .offset(x: CGFloat(motion.roll * 100))
                Rectangle()
                    .fill(motion.isLevel ? Design.accent : Design.warmYellow)
                    .frame(width: 1, height: 36)
                    .offset(y: CGFloat(motion.pitch * 100))
                Circle()
                    .fill(motion.isLevel ? Design.accent : Design.warmYellow)
                    .frame(width: 5, height: 5)
            }
            Text(String(format: "%.1f°", motion.roll * 180 / .pi))
                .font(Design.mono(10))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Design.glassBg)
                .clipShape(Capsule())
        }
        .opacity(0.85)
    }
}

// MARK: - 玻璃胶囊
struct GlassPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Design.mono(11))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Design.glassBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Design.glassBorder, lineWidth: 0.5))
    }
}

// MARK: - 圆形玻璃按钮
struct GlassCircleButton: View {
    let icon: String
    var active: Bool = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(active ? Design.accent : .white)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Design.glassBg)
                        .overlay(
                            Circle().stroke(
                                active ? Design.accent.opacity(0.8) : Design.glassBorder,
                                lineWidth: active ? 1.5 : 0.5
                            )
                        )
                )
        }
    }
}

// MARK: - 主界面
struct CameraScreen: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var motion = MotionManager()
    @State private var showSettings = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // 预览
            CameraPreviewView(
                session: engine.captureSession,
                gravity: engine.previewMode.gravity,
                orientation: engine.videoOrientation.avOrientation,
                mirrored: engine.mirrorHorizontal
            )
            .scaleEffect(x: 1, y: engine.mirrorVertical ? -1 : 1)
            .ignoresSafeArea()

            // 渐变遮罩
            LinearGradient(
                colors: [Color.black.opacity(0.55), .clear, .clear, Color.black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // 网格
            if engine.showGrid && !engine.isScreenOffMode {
                GridOverlay().ignoresSafeArea().allowsHitTesting(false)
            }

            // 水平仪
            if engine.showLevel && !engine.isScreenOffMode {
                LevelOverlay(motion: motion)
                    .position(x: UIScreen.main.bounds.width / 2, y: 140)
                    .allowsHitTesting(false)
            }

            // 省电黑屏
            if engine.isScreenOffMode {
                screenOffView
            }

            // 顶部状态栏
            if !engine.isScreenOffMode {
                VStack {
                    topBar
                    Spacer()
                }
            }

            // 底部控制
            if !engine.isScreenOffMode {
                VStack {
                    Spacer()
                    bottomBar
                }
            }

            // 保存提示
            if let msg = engine.lastSavedMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(Design.body(13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Design.glassBg)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Design.glassBorder, lineWidth: 0.5))
                        .padding(.bottom, 140)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            engine.startSession()
            motion.start()
        }
        .onDisappear { motion.stop() }
        .onVolumeButton {
            engine.isRecording ? engine.stopRecording() : engine.startRecording()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
    }

    // MARK: 顶部
    private var topBar: some View {
        HStack(spacing: 8) {
            // 录制状态
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isRecording ? Design.recordRed : Color.white.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .shadow(color: engine.isRecording ? Design.recordRed : .clear, radius: 4)
                Text(engine.isRecording ? "REC" : "STBY")
                    .font(Design.mono(11))
                    .foregroundStyle(engine.isRecording ? Design.recordRed : .white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Design.glassBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Design.glassBorder, lineWidth: 0.5))

            if engine.isVoiceListening {
                GlassPill(text: "🎙 语音", color: Design.accent)
            }
            if engine.mirrorHorizontal { GlassPill(text: "H", color: Design.warmYellow) }
            if engine.mirrorVertical { GlassPill(text: "V", color: Design.warmYellow) }

            Spacer()

            // 电量
            HStack(spacing: 4) {
                Image(systemName: batteryIcon(engine.batteryLevel))
                    .font(.system(size: 12, weight: .medium))
                Text("\(Int(engine.batteryLevel * 100))%")
                    .font(Design.mono(11))
            }
            .foregroundStyle(engine.batteryLevel < 0.2 ? Design.recordRed : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Design.glassBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Design.glassBorder, lineWidth: 0.5))

            GlassCircleButton(icon: "gearshape.fill", size: 36) {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: 底部
    private var bottomBar: some View {
        HStack(spacing: 24) {
            GlassCircleButton(icon: engine.currentLens.icon, size: 48) {
                engine.resetScreenOffTimer()
                let a = CameraLens.allCases.filter { $0.isAvailable }
                guard !a.isEmpty else { return }
                let i = a.firstIndex(of: engine.currentLens) ?? 0
                engine.switchLens(a[(i + 1) % a.count])
            }

            recordButton

            GlassCircleButton(
                icon: engine.voiceEnabled ? "mic.fill" : "mic.slash.fill",
                active: engine.voiceEnabled,
                size: 48
            ) { engine.toggleVoice() }

            GlassCircleButton(icon: "moon.fill", size: 48) {
                engine.isScreenOffMode = true
                engine.resetScreenOffTimer()
            }
        }
        .padding(.bottom, 32)
    }

    // MARK: 录制按钮
    private var recordButton: some View {
        Button {
            engine.isRecording ? engine.stopRecording() : engine.startRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 76, height: 76)
                Circle()
                    .stroke(engine.isRecording ? Design.recordRed.opacity(0.4) : Color.clear, lineWidth: 8)
                    .frame(width: 88, height: 88)
                if engine.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Design.recordRed)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Design.recordRed)
                        .frame(width: 60, height: 60)
                        .shadow(color: Design.recordRed.opacity(0.5), radius: 8)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 省电黑屏视图
    private var screenOffView: some View {
        Color.black.ignoresSafeArea()
            .overlay(
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                        Text("上滑解锁")
                            .font(Design.body(12))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.bottom, 70)
                    .offset(y: dragOffset)
                }
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in dragOffset = min(0, v.translation.height) }
                    .onEnded { v in
                        if v.translation.height < -80 { engine.unlockScreen() }
                        withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                    }
            )
    }

    private func batteryIcon(_ level: Float) -> String {
        if level < 0.1 { return "battery.0" }
        if level < 0.35 { return "battery.25" }
        if level < 0.6 { return "battery.50" }
        if level < 0.85 { return "battery.75" }
        return "battery.100"
    }
}

// MARK: - 设置界面
struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.presentationMode) var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Design.bgTop, Design.bgBottom],
                    startPoint: .top, endPoint: .bottom
                ).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        // 运动防抖
                        section(title: "运动防抖", icon: "hand.raised.fill") {
                            grid {
                                ForEach(StabilizationLevel.allCases, id: \.self) { s in
                                    chip(title: s.rawValue, selected: engine.stabilizationLevel == s) {
                                        engine.setStabilization(s)
                                    }
                                }
                            }
                        }

                        // 预录
                        section(title: "预录", icon: "arrow.counterclockwise") {
                            grid {
                                ForEach(PreRecordOption.allCases, id: \.self) { p in
                                    chip(title: p.rawValue, selected: engine.preRecordOption == p) {
                                        engine.setPreRecord(p)
                                    }
                                }
                            }
                        }

                        // 切换镜头
                        section(title: "切换镜头", icon: "camera.rotate") {
                            grid {
                                ForEach(CameraLens.allCases, id: \.self) { l in
                                    chip(
                                        title: l.rawValue,
                                        selected: engine.currentLens == l,
                                        enabled: l.isAvailable
                                    ) { engine.switchLens(l) }
                                }
                            }
                        }

                        // 分辨率
                        section(title: "分辨率", icon: "rectangle.on.rectangle") {
                            grid {
                                ForEach(VideoResolution.allCases, id: \.self) { r in
                                    chip(title: r.rawValue, selected: engine.videoResolution == r) {
                                        engine.setResolution(r)
                                    }
                                }
                            }
                        }

                        // 帧率
                        section(title: "帧率", icon: "speedometer") {
                            grid {
                                ForEach(FrameRateOption.allCases, id: \.self) { f in
                                    let ok = f.rawValue <= engine.videoResolution.maxFrameRate
                                    chip(
                                        title: f.displayName,
                                        selected: engine.frameRate == f,
                                        enabled: ok
                                    ) { engine.setFrameRate(f) }
                                }
                            }
                        }

                        // 预览画面
                        section(title: "预览画面", icon: "rectangle.inset.filled") {
                            grid {
                                ForEach(PreviewMode.allCases, id: \.self) { m in
                                    chip(title: m.rawValue, selected: engine.previewMode == m) {
                                        engine.setPreviewMode(m)
                                    }
                                }
                            }
                        }

                        // 变换与视图
                        section(title: "变换与视图", icon: "arrow.left.arrow.right") {
                            grid {
                                chip(title: "水平翻转", selected: engine.mirrorHorizontal) {
                                    engine.setMirrorHorizontal(!engine.mirrorHorizontal)
                                }
                                chip(title: "垂直翻转", selected: engine.mirrorVertical) {
                                    engine.setMirrorVertical(!engine.mirrorVertical)
                                }
                                chip(title: "网格", selected: engine.showGrid) {
                                    engine.showGrid.toggle()
                                }
                                chip(title: "水平仪", selected: engine.showLevel) {
                                    engine.showLevel.toggle()
                                }
                            }
                        }

                        // 智能语音
                        section(title: "智能语音", icon: "waveform") {
                            VStack(alignment: .leading, spacing: 12) {
                                grid {
                                    chip(title: "开", selected: engine.voiceEnabled) {
                                        if !engine.voiceEnabled { engine.toggleVoice() }
                                    }
                                    chip(title: "关", selected: !engine.voiceEnabled) {
                                        if engine.voiceEnabled { engine.toggleVoice() }
                                    }
                                }
                                textFieldRow(
                                    icon: "play.circle",
                                    placeholder: "开始词语（选填，逗号分隔）",
                                    text: Binding(
                                        get: { engine.customStartWords.joined(separator: ",") },
                                        set: { engine.customStartWords = $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                                    )
                                )
                                textFieldRow(
                                    icon: "stop.circle",
                                    placeholder: "结束词语（选填，逗号分隔）",
                                    text: Binding(
                                        get: { engine.customStopWords.joined(separator: ",") },
                                        set: { engine.customStopWords = $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                                    )
                                )
                            }
                        }

                        // 省电模式
                        section(title: "省电模式（上滑屏幕解除）", icon: "moon.zzz.fill") {
                            grid {
                                ForEach(ScreenOffOption.allCases, id: \.self) { o in
                                    chip(title: o.rawValue, selected: engine.screenOffOption == o) {
                                        engine.setScreenOffOption(o)
                                    }
                                }
                            }
                        }

                        // 快门声
                        section(title: "快门声", icon: "speaker.wave.2.fill") {
                            grid {
                                chip(title: "开", selected: engine.shutterSoundEnabled) {
                                    engine.shutterSoundEnabled = true
                                }
                                chip(title: "关", selected: !engine.shutterSoundEnabled) {
                                    engine.shutterSoundEnabled = false
                                }
                            }
                        }

                        // 录制方向
                        section(title: "录制方向", icon: "iphone") {
                            grid {
                                ForEach(VideoOrientationOption.allCases, id: \.self) { o in
                                    chip(title: o.rawValue, selected: engine.videoOrientation == o) {
                                        engine.setVideoOrientation(o)
                                    }
                                }
                            }
                        }

                        // 来电提醒
                        section(title: "来电提醒", icon: "phone.fill") {
                            grid {
                                chip(title: "开", selected: engine.interruptOnPhoneCall) {
                                    engine.interruptOnPhoneCall = true
                                }
                                chip(title: "关", selected: !engine.interruptOnPhoneCall) {
                                    engine.interruptOnPhoneCall = false
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss.wrappedValue.dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 卡片分组
    @ViewBuilder
    private func section<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.accent)
                Text(title)
                    .font(Design.title(14))
                    .foregroundStyle(.white)
            }
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Design.radius)
                .fill(Design.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radius)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func grid<C: View>(@ViewBuilder content: () -> C) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            content()
        }
    }

    @ViewBuilder
    private func chip(title: String, selected: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Design.body(13))
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(enabled ? (selected ? Design.accent : .white) : Color.white.opacity(0.3))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: Design.chipRadius)
                        .fill(selected ? Design.cardBgActive : Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.chipRadius)
                                .stroke(selected ? Design.accent.opacity(0.7) : Color.white.opacity(0.05),
                                        lineWidth: selected ? 1.5 : 0.5)
                        )
                )
        }
        .disabled(!enabled)
    }

    @ViewBuilder
    private func textFieldRow(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Design.accent)
            TextField(placeholder, text: text)
                .font(Design.body(13))
                .foregroundStyle(.white)
                .textFieldStyle(PlainTextFieldStyle())
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: Design.chipRadius)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.chipRadius)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
}