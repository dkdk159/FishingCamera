import SwiftUI
import AVFoundation
import Photos
import UIKit
import VideoToolbox
import AudioToolbox

// MARK: - App 入口
@main
struct ActionCameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen().preferredColorScheme(.dark)
        }
    }
}

// MARK: - 枚举定义（匹配主流运动相机设置）
enum CameraLens: String, CaseIterable {
    case ultraWide = "超广角"
    case wide      = "广角"
    case telephoto = "长焦"
    case frontWide = "前置广角"

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .frontWide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position {
        self == .frontWide ? .front : .back
    }

    var shortName: String {
        switch self {
        case .ultraWide: return "0.5×"
        case .wide: return "1×"
        case .telephoto: return "3×"
        case .frontWide: return "前置"
        }
    }
}

enum StabilizationLevel: String, CaseIterable {
    case off       = "关"
    case standard  = "标准"
    case smooth    = "平滑"
    case enhanced  = "增强"
    case superMode = "超强"
    case auto      = "自动"
}

enum PreRecordOption: String, CaseIterable {
    case off = "关"
    case s5  = "5秒"
    case s15 = "15秒"
    case s30 = "30秒"
    case m1  = "1分钟"
    case m2  = "2分钟"

    var seconds: TimeInterval {
        switch self {
        case .off: return 0
        case .s5: return 5
        case .s15: return 15
        case .s30: return 30
        case .m1: return 60
        case .m2: return 120
        }
    }
}

enum VideoResolution: String, CaseIterable {
    case uhd4K       = "4K"
    case uhd4K4x3    = "4K (4:3)"
    case k3          = "3K (4:3)"
    case k2_5        = "2.5K (4:3)"
    case k2          = "2K (4:3)"
    case hd1080      = "1080p"
    case hd1080_4x3  = "1080p (4:3)"
    case hd720       = "720p"

    // 实际采集尺寸（必须与硬件 pixelBuffer 一致，4:3 选项当前按 16:9 采集，避免尺寸不匹配崩溃）
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .uhd4K, .uhd4K4x3, .k3, .k2_5: return .hd4K3840x2160
        case .k2, .hd1080, .hd1080_4x3: return .hd1920x1080
        case .hd720: return .hd1280x720
        }
    }

    /// 编码尺寸（与采集 pixelBuffer 尺寸严格一致）
    var encodedSize: (width: Int, height: Int, bitrate: Int) {
        switch sessionPreset {
        case .hd4K3840x2160: return (3840, 2160, 32_000_000)
        case .hd1280x720:   return (1280, 720, 5_000_000)
        default:            return (1920, 1080, 9_000_000)
        }
    }
}

enum FrameRateOption: Int, CaseIterable {
    case fps24 = 24
    case fps25 = 25
    case fps30 = 30
    case fps48 = 48
    case fps50 = 50
    case fps60 = 60
    case fps120 = 120
    case fps240 = 240

    var displayName: String { "\(rawValue)fps" }
}

// MARK: - 时间滚动环形缓冲（线程安全，按 PTS 自动淘汰过期帧）
private struct TimedSample {
    let buffer: CMSampleBuffer
    let pts: CMTime
}

final class SampleRingBuffer {
    private var items: [TimedSample] = []
    private let lock = NSLock()
    private let maxSeconds: Double

    init(maxSeconds: Double) { self.maxSeconds = max(1, maxSeconds) }

    func append(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        lock.lock()
        items.append(TimedSample(buffer: sb, pts: pts))
        let cutoff = pts.seconds - maxSeconds
        while let first = items.first, first.pts.seconds <= cutoff {
            items.removeFirst()
        }
        lock.unlock()
    }

    func snapshot() -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return items.map { $0.buffer }
    }
}

// MARK: - VideoToolbox 硬件 H264 压缩器
// 预录必须缓存“压缩后”的帧：未压缩帧每帧约 8MB，缓存几十秒会耗尽采集像素池导致黑屏。
final class VideoCompressor: NSObject {
    private var session: VTCompressionSession?
    private(set) var formatDescription: CMFormatDescription?
    var onEncoded: ((CMSampleBuffer) -> Void)?

    func configure(width: Int, height: Int, fps: Int32, bitRate: Int) {
        invalidate()
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            print("[Compressor] create failed \(status)")
            return
        }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                            value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                            value: bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                            value: max(fps, 1) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                            value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = session,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid { duration = CMTime(value: 1, timescale: 30) }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded = encoded else { return }
            if self?.formatDescription == nil {
                self?.formatDescription = CMSampleBufferGetFormatDescription(encoded)
            }
            self?.onEncoded?(encoded)
        }
    }

    func invalidate() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }
}

// MARK: - 预录写入器（H264 直通 + PCM→AAC，串行队列保证线程安全）
final class PreRecordWriter {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.actioncam.writer")
    private var active = false
    private var didStartSession = false

    func begin(videoFrames: [CMSampleBuffer],
               audioFrames: [CMSampleBuffer],
               url: URL,
               videoFormat: CMFormatDescription?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

                let vInput: AVAssetWriterInput
                if let fmt = videoFormat {
                    vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                               sourceFormatHint: fmt)
                } else {
                    vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: 1920,
                        AVVideoHeightKey: 1080
                    ])
                }
                vInput.expectsMediaDataInRealTime = true
                if writer.canAdd(vInput) { writer.add(vInput) }

                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 128000
                ])
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) { writer.add(aInput) }

                writer.startWriting()

                // 有预录历史帧：从最早一帧的 PTS 开始，并按时间戳交错写入音视频
                if let firstPTS = videoFrames.first?.presentationTimeStamp
                    ?? audioFrames.first?.presentationTimeStamp {
                    writer.startSession(atSourceTime: firstPTS)
                    self.didStartSession = true

                    var vi = 0, ai = 0
                    while vi < videoFrames.count || ai < audioFrames.count {
                        if ai >= audioFrames.count ||
                            (vi < videoFrames.count &&
                             videoFrames[vi].presentationTimeStamp.seconds <= audioFrames[ai].presentationTimeStamp.seconds) {
                            if vInput.isReadyForMoreMediaData { vInput.append(videoFrames[vi]) }
                            vi += 1
                        } else {
                            if aInput.isReadyForMoreMediaData { aInput.append(audioFrames[ai]) }
                            ai += 1
                        }
                    }
                }

                self.assetWriter = writer
                self.videoInput = vInput
                self.audioInput = aInput
                self.active = true
            } catch {
                print("[Writer] begin failed: \(error)")
                self.active = false
            }
        }
    }

    func appendVideo(_ sb: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active, let writer = self.assetWriter else { return }
            if !self.didStartSession {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                self.didStartSession = true
            }
            if self.videoInput?.isReadyForMoreMediaData == true {
                self.videoInput?.append(sb)
            }
        }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active, let writer = self.assetWriter else { return }
            if !self.didStartSession {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                self.didStartSession = true
            }
            if self.audioInput?.isReadyForMoreMediaData == true {
                self.audioInput?.append(sb)
            }
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.active, let writer = self.assetWriter else {
                completion(nil)
                return
            }
            self.active = false
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                completion(writer.status == .completed ? writer.outputURL : nil)
            }
        }
    }
}

private extension CMSampleBuffer {
    var presentationTimeStamp: CMTime { CMSampleBufferGetPresentationTimeStamp(self) }
}

// MARK: - 竖屏方向修复（passthrough 重封装，不重新编码，速度快）
enum VideoRotator {
    static func fixPortrait(_ url: URL, completion: @escaping (URL) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let vTrack = asset.tracks(withMediaType: .video).first,
              vTrack.naturalSize.width > vTrack.naturalSize.height else {
            completion(url)
            return
        }
        let composition = AVMutableComposition()
        guard let cVideo = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(url)
            return
        }
        do {
            let fullRange = CMTimeRange(start: .zero, duration: asset.duration)
            try cVideo.insertTimeRange(fullRange, of: vTrack, at: .zero)
            cVideo.preferredTransform = CGAffineTransform(rotationAngle: .pi / 2)
            if let aTrack = asset.tracks(withMediaType: .audio).first,
               let cAudio = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
                try cAudio.insertTimeRange(fullRange, of: aTrack, at: .zero)
            }
        } catch {
            completion(url)
            return
        }
        let out = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "_p.mp4")
        guard let exporter = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            completion(url)
            return
        }
        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        exporter.exportAsynchronously {
            if exporter.status == .completed {
                try? FileManager.default.removeItem(at: url)
                completion(out)
            } else {
                completion(url)
            }
        }
    }
}

// MARK: - 相册保存
enum PhotoLibrarySaver {
    static func save(_ url: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            })
        }
    }
}

// MARK: - 提示音（AVAudioEngine 合成清脆“叮”声，不受静音键影响）
final class SoundFeedback {
    static let shared = SoundFeedback()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    private func tone(frequency: Double, duration: Double, volume: Float, vibrate: Bool) {
        ensureRunning()
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        let sr = format.sampleRate
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let decay = exp(-4.0 * t)
            let main = sin(2 * .pi * frequency * t)
            let harmonic = 0.22 * sin(2 * .pi * frequency * 2 * t)
            ch[i] = Float((main + harmonic) * decay) * volume
        }
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
        if vibrate { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    }

    func start() { tone(frequency: 1320, duration: 0.16, volume: 0.9, vibrate: true) }
    func stop()  { tone(frequency: 880, duration: 0.24, volume: 0.9, vibrate: true) }
    func tick()  { tone(frequency: 1000, duration: 0.06, volume: 0.55, vibrate: false) }
}

// MARK: - 电量管理
final class BatteryManager {
    private var timer: Timer?
    func start(_ onChange: @escaping (Float) -> Void) {
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
            onChange(UIDevice.current.batteryLevel)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in onChange(UIDevice.current.batteryLevel) }
        }
    }
    deinit { timer?.invalidate() }
}

// MARK: - 相机引擎
final class CameraEngine: NSObject, ObservableObject {
    // UI 状态（仅主线程读写）
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var isSaving = false
    @Published var currentLens: CameraLens = .wide
    @Published var preRecordOption: PreRecordOption = .s30
    @Published var videoResolution: VideoResolution = .hd1080
    @Published var frameRate: FrameRateOption = .fps30
    @Published var stabilizationLevel: StabilizationLevel = .auto
    @Published var isNightFillLightEnabled = false
    @Published var isDelayCaptureEnabled = false
    @Published var delayCaptureSeconds: Int = 3
    @Published var batteryLevel: Float = 1.0
    @Published var permissionDenied = false
    @Published var lastMessage: String?
    @Published var countdown: Int?

    let captureSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.actioncam.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentVideoDevice: AVCaptureDevice?
    private let compressor = VideoCompressor()
    private var videoRing = SampleRingBuffer(maxSeconds: 30)
    private var audioRing = SampleRingBuffer(maxSeconds: 30)
    private let writer = PreRecordWriter()
    private let battery = BatteryManager()

    // 仅在 sessionQueue 访问
    private var recording = false
    private var preRecordSeconds: TimeInterval = 30
    private var micEnabled = false
    private var started = false
    private var delayTimer: Timer?

    // MARK: 启动（先请求权限）
    func startIfNeeded() {
        let needStart = sessionQueue.sync { () -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard needStart else { return }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
            guard let self = self else { return }
            guard videoGranted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                self.setupAudioSession()
                self.sessionQueue.async {
                    self.micEnabled = micGranted
                    self.buildSession(addAudio: micGranted)
                }
            }
        }
        Task { @MainActor in
            battery.start { [weak self] level in self?.batteryLevel = level }
        }
    }

    private func setupAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .videoRecording,
                              options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try s.setActive(true)
        } catch {
            // 降级：仅保证提示音可播放
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        }
    }

    // MARK: 构建 / 重建采集会话（每次彻底清空旧连接，避免重复添加）
    private func buildSession(addAudio: Bool? = nil) {
        let useAudio = addAudio ?? micEnabled
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        currentVideoDevice = nil

        captureSession.sessionPreset = videoResolution.sessionPreset

        guard let device = makeDevice(lens: currentLens),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(videoInput) else {
            captureSession.commitConfiguration()
            print("[Camera] no video device available")
            return
        }
        captureSession.addInput(videoInput)
        currentVideoDevice = device

        if useAudio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           captureSession.canAddInput(micInput) {
            captureSession.addInput(micInput)
        }
        micEnabled = useAudio

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if useAudio && captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }

        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (currentLens.position == .front)
        }

        let size = videoResolution.encodedSize
        compressor.invalidate()
        compressor.configure(width: size.width, height: size.height,
                             fps: Int32(frameRate.rawValue), bitRate: size.bitrate)
        compressor.onEncoded = { [weak self] sb in
            self?.sessionQueue.async {
                guard let self = self else { return }
                if self.preRecordSeconds > 0 { self.videoRing.append(sb) }
                if self.recording { self.writer.appendVideo(sb) }
            }
        }

        // 分辨率切换时清空旧格式缓冲
        videoRing = SampleRingBuffer(maxSeconds: max(preRecordSeconds, 1))
        audioRing = SampleRingBuffer(maxSeconds: max(preRecordSeconds, 1))

        applyStabilizationLocked()
        applyFrameRateLocked()

        captureSession.commitConfiguration()
        if !captureSession.isRunning { captureSession.startRunning() }

        DispatchQueue.main.async { self.isSessionRunning = true }
    }

    private func makeDevice(lens: CameraLens) -> AVCaptureDevice? {
        if let d = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position) {
            return d
        }
        // 设备不支持该镜头时回退广角，绝不返回 nil 导致黑屏
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position)
    }

    // MARK: 镜头切换
    func switchLens(_ lens: CameraLens) {
        SoundFeedback.shared.tick()
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.inputs
                .filter { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }
                .forEach { self.captureSession.removeInput($0) }

            guard let device = self.makeDevice(lens: lens),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addInput(input)
            self.currentVideoDevice = device
            if let conn = self.videoOutput.connection(with: .video) {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (lens.position == .front)
            }
            self.applyStabilizationLocked()
            self.applyFrameRateLocked()
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async { self.currentLens = lens }
        }
    }

    // MARK: 防抖 / 帧率
    func applyStabilization() {
        sessionQueue.async { [weak self] in self?.applyStabilizationLocked() }
    }

    private func applyStabilizationLocked() {
        guard let conn = videoOutput.connection(with: .video),
              conn.isVideoStabilizationSupported else { return }
        switch stabilizationLevel {
        case .off:       conn.preferredVideoStabilizationMode = .off
        case .standard:  conn.preferredVideoStabilizationMode = .standard
        case .smooth:    conn.preferredVideoStabilizationMode = .cinematic
        case .enhanced, .superMode:
            conn.preferredVideoStabilizationMode = .cinematic
        case .auto:      conn.preferredVideoStabilizationMode = .auto
        }
    }

    func applyFrameRate() {
        sessionQueue.async { [weak self] in self?.applyFrameRateLocked() }
    }

    private func applyFrameRateLocked() {
        guard let device = currentVideoDevice else { return }
        do {
            try device.lockForConfiguration()
            let fps = Double(frameRate.rawValue)
            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
                fps >= $0.minFrameRate && fps <= $0.maxFrameRate
            }
            if supported {
                let t = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMinFrameDuration = t
                device.activeVideoMaxFrameDuration = t
            }
            device.unlockForConfiguration()
        } catch {
            print("[Camera] framerate failed: \(error)")
        }
    }

    // MARK: 设置变更
    func setResolution(_ res: VideoResolution) {
        guard res != videoResolution else { return }
        videoResolution = res
        SoundFeedback.shared.tick()
        sessionQueue.async { [weak self] in self?.buildSession() }
    }

    func setPreRecord(_ option: PreRecordOption) {
        SoundFeedback.shared.tick()
        preRecordOption = option
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.preRecordSeconds = option.seconds
            self.videoRing = SampleRingBuffer(maxSeconds: max(option.seconds, 1))
            self.audioRing = SampleRingBuffer(maxSeconds: max(option.seconds, 1))
        }
    }

    // MARK: 录制控制
    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        if isDelayCaptureEnabled && delayCaptureSeconds > 0 {
            var remaining = delayCaptureSeconds
            DispatchQueue.main.async { self.countdown = remaining }
            SoundFeedback.shared.tick()
            delayTimer?.invalidate()
            delayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                remaining -= 1
                if remaining <= 0 {
                    t.invalidate()
                    self.delayTimer = nil
                    self.countdown = nil
                    self.performStart()
                } else {
                    self.countdown = remaining
                    SoundFeedback.shared.tick()
                }
            }
        } else {
            performStart()
        }
    }

    private func performStart() {
        SoundFeedback.shared.start()
        sessionQueue.async { [weak self] in
            guard let self = self, !self.recording else { return }
            self.recording = true
            let v = self.preRecordSeconds > 0 ? self.videoRing.snapshot() : []
            let a = self.preRecordSeconds > 0 ? self.audioRing.snapshot() : []
            self.writer.begin(videoFrames: v, audioFrames: a,
                              url: self.makeOutputURL(),
                              videoFormat: self.compressor.formatDescription)
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    func stopRecording() {
        delayTimer?.invalidate()
        delayTimer = nil
        countdown = nil
        SoundFeedback.shared.stop()
        sessionQueue.async { [weak self] in
            guard let self = self, self.recording else { return }
            self.recording = false
            DispatchQueue.main.async {
                self.isRecording = false
                self.isSaving = true
            }
            self.writer.finish { [weak self] url in
                guard let self = self else { return }
                guard let url = url else {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        self.flash("保存失败")
                    }
                    return
                }
                VideoRotator.fixPortrait(url) { finalURL in
                    PhotoLibrarySaver.save(finalURL) { ok in
                        DispatchQueue.main.async {
                            self.isSaving = false
                            self.flash(ok ? "已保存到相册" : "保存失败")
                        }
                        try? FileManager.default.removeItem(at: finalURL)
                    }
                }
            }
        }
    }

    private func makeOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return dir.appendingPathComponent("Action_\(f.string(from: Date())).mp4")
    }

    func flash(_ text: String) {
        lastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.lastMessage == text { self?.lastMessage = nil }
        }
    }

    // MARK: 补光灯
    func toggleTorch() {
        isNightFillLightEnabled.toggle()
        SoundFeedback.shared.tick()
        let on = isNightFillLightEnabled
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if on && device.isTorchAvailable {
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                print("[Torch] \(error)")
            }
        }
    }
}

// MARK: 采集回调（全部在 sessionQueue，不碰主线程）
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            compressor.encode(sampleBuffer)
        } else if output === audioOutput {
            if preRecordSeconds > 0 { audioRing.append(sampleBuffer) }
            if recording { writer.appendAudio(sampleBuffer) }
        }
    }
}

// MARK: - 主题
enum Theme {
    static let accent = Color(red: 0.15, green: 0.78, blue: 0.65)
    static let recording = Color(red: 0.95, green: 0.30, blue: 0.25)
    static let panelBg = Color.black.opacity(0.55)
    static let cellBg = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let cellSelected = Color(red: 0.15, green: 0.78, blue: 0.65)
}

// MARK: - 相机预览
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 主屏幕
struct CameraScreen: View {
    @StateObject private var engine = CameraEngine()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewView(session: engine.captureSession)
                .ignoresSafeArea()

            // 未授权提示
            if engine.permissionDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 48)).foregroundStyle(.white.opacity(0.7))
                    Text("需要相机权限").font(.headline).foregroundStyle(.white)
                    Text("请在系统设置中允许访问相机后重试")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.accent).foregroundStyle(.black)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 40)
            }

            // 顶部栏
            VStack {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(engine.isRecording ? Theme.recording : Theme.accent)
                            .frame(width: 8, height: 8)
                        Text(engine.isRecording ? "REC" : (engine.preRecordOption.seconds > 0 ? "预录 \(Int(engine.preRecordOption.seconds))s" : "STBY"))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.panelBg).cornerRadius(6)

                    if engine.isSaving {
                        Text("保存中…")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.panelBg).cornerRadius(6)
                    }

                    Spacer()

                    Text("\(Int(engine.batteryLevel * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.panelBg).cornerRadius(6)

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16)).foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Theme.panelBg).clipShape(Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                Spacer()
            }

            // 倒计时
            if let c = engine.countdown {
                Text("\(c)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 10)
            }

            // 消息提示
            if let msg = engine.lastMessage {
                VStack {
                    Spacer().frame(height: 120)
                    Text(msg)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Theme.panelBg).cornerRadius(20)
                    Spacer()
                }
            }

            // 底部控制栏
            VStack {
                Spacer()
                HStack(spacing: 34) {
                    // 补光
                    Button { engine.toggleTorch() } label: {
                        Image(systemName: engine.isNightFillLightEnabled ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(engine.isNightFillLightEnabled ? Theme.accent : .white)
                            .frame(width: 52, height: 52)
                            .background(Theme.panelBg).clipShape(Circle())
                    }

                    // 录制按钮
                    Button { engine.toggleRecording() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                            if engine.isRecording {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Theme.recording).frame(width: 30, height: 30)
                            } else {
                                Circle().fill(Theme.recording).frame(width: 58, height: 58)
                            }
                        }
                    }
                    .disabled(engine.isSaving)

                    // 镜头循环切换
                    Button {
                        let all = CameraLens.allCases
                        let idx = all.firstIndex(of: engine.currentLens) ?? 0
                        engine.switchLens(all[(idx + 1) % all.count])
                    } label: {
                        Text(engine.currentLens.shortName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Theme.panelBg).clipShape(Circle())
                    }
                }
                .padding(.bottom, 34)
            }
        }
        .statusBarHidden(true)
        .onAppear { engine.startIfNeeded() }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
    }
}

// MARK: - 设置面板
struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("防抖") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(StabilizationLevel.allCases, id: \.self) { v in
                                SettingButton(title: v.rawValue, selected: engine.stabilizationLevel == v) {
                                    engine.stabilizationLevel = v
                                    engine.applyStabilization()
                                }
                            }
                        }
                    }

                    section("预录") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(PreRecordOption.allCases, id: \.self) { v in
                                SettingButton(title: v.rawValue, selected: engine.preRecordOption == v) {
                                    engine.setPreRecord(v)
                                }
                            }
                        }
                    }

                    section("切换镜头") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(CameraLens.allCases, id: \.self) { v in
                                SettingButton(title: v.rawValue, selected: engine.currentLens == v) {
                                    engine.switchLens(v)
                                }
                            }
                        }
                    }

                    section("分辨率") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(VideoResolution.allCases, id: \.self) { v in
                                SettingButton(title: v.rawValue, selected: engine.videoResolution == v) {
                                    engine.setResolution(v)
                                }
                            }
                        }
                    }

                    section("帧率") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(FrameRateOption.allCases, id: \.self) { v in
                                SettingButton(title: v.displayName, selected: engine.frameRate == v) {
                                    engine.frameRate = v
                                    engine.applyFrameRate()
                                }
                            }
                        }
                    }

                    section("拍摄") {
                        ToggleRow(title: "延迟拍摄（3秒）", isOn: $engine.isDelayCaptureEnabled)
                        ToggleRow(title: "夜间补光", isOn: Binding(
                            get: { engine.isNightFillLightEnabled },
                            set: { v in if v != engine.isNightFillLightEnabled { engine.toggleTorch() } }
                        ))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
    }
}

struct SettingButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(selected ? Theme.cellSelected : Theme.cellBg)
                .cornerRadius(10)
        }
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.cellBg)
        .cornerRadius(10)
    }
}
