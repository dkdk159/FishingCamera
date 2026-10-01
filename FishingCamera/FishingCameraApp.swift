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
        WindowGroup { CameraScreen().preferredColorScheme(.dark) }
    }
}

// MARK: - 环形缓冲区（带锁，线程安全）
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
        var result: [Element] = []
        result.reserveCapacity(count)
        let startIndex = count < capacity ? 0 : writeIndex
        for offset in 0..<count {
            let i = (startIndex + offset) % capacity
            if let e = storage[i] { result.append(e) }
        }
        return result
    }
    mutating func clear() {
        lock.lock(); defer { lock.unlock() }
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0; count = 0
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
}

enum VideoResolution: String, CaseIterable {
    case uhd4K_16x9 = "4K", uhd4K_4x3 = "4K (4:3)"
    case hd1080_16x9 = "1080p", hd1080_4x3 = "1080p (4:3)", hd720 = "720p"

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .uhd4K_16x9, .uhd4K_4x3: return .hd4K3840x2160
        case .hd720: return .hd1280x720
        default: return .hd1920x1080
        }
    }
    var outputSize: (w: Int, h: Int) {
        switch self {
        case .uhd4K_16x9: return (3840, 2160)
        case .uhd4K_4x3: return (3840, 2880)
        case .hd1080_16x9: return (1920, 1080)
        case .hd1080_4x3: return (1920, 1440)
        case .hd720: return (1280, 720)
        }
    }
    var maxFrameRate: Int {
        switch self {
        case .uhd4K_16x9, .uhd4K_4x3: return 60
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
    case off = "关", standard = "标准", smooth = "平滑", auto = "自动"
    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .smooth: return .cinematic
        case .auto: return .auto
        }
    }
}

enum PreRecordOption: String, CaseIterable {
    case off = "关", s5 = "5秒", s15 = "15秒"
    case s30 = "30秒", m1 = "1分钟", m2 = "2分钟"
    var seconds: TimeInterval {
        switch self {
        case .off: return 0
        case .s5: return 5; case .s15: return 15; case .s30: return 30
        case .m1: return 60; case .m2: return 120
        }
    }
}

enum ShutterSoundOption: String, CaseIterable {
    case standard = "标准", soft = "柔和", action = "运动", none = "静音"
    var soundID: SystemSoundID? {
        switch self {
        case .standard: return 1104
        case .soft: return 1105
        case .action: return 1103
        case .none: return nil
        }
    }
}

// MARK: - H.264 硬件编码器
final class H264VideoEncoder {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    var onEncodedSample: ((CMSampleBuffer) -> Void)?

    func setup(width: Int, height: Int, fps: Int, bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = session {
            VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(old)
            session = nil
        }
        // 硬件加速 key 仅 iOS 17.4+；低版本传 nil 即可（系统默认优先硬件）
        var spec: CFDictionary? = nil
        if #available(iOS 17.4, *) {
            spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        }
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let sb = sampleBuffer, let refcon = refcon else { return }
                let encoder = Unmanaged<H264VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.onEncodedSample?(sb)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let s = newSession else {
            print("[Encoder] 创建失败 \(status)"); return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(s)
        self.session = s
        print("[Encoder] H.264 就绪 \(width)x\(height) @\(fps)")
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) {
        lock.lock(); let s = session; lock.unlock()
        guard let session = s else { return }
        var props: [String: Any] = [:]
        if forceKeyframe {
            props[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: props.isEmpty ? nil : props as CFDictionary,
            sourceFrameRefcon: nil, infoFlagsOut: nil
        )
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
    @Published var videoResolution: VideoResolution = .hd1080_16x9
    @Published var frameRate: FrameRateOption = .fps30
    @Published var stabilizationLevel: StabilizationLevel = .auto
    @Published var preRecordOption: PreRecordOption = .s30
    @Published var batteryLevel: Float = 1.0
    @Published var lastSavedMessage: String?
    @Published var voiceEnabled = true
    @Published var isVoiceListening = false
    @Published var isScreenOffMode = false
    @Published var isAutoPreRecordEnabled = false
    @Published var shutterSound: ShutterSoundOption = .standard
    @Published var isRecordingStatusVisible = true
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

    override init() {
        super.init()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .videoRecording,
                                 options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try? session.setActive(true)

        voiceManager.onStart = { [weak self] in
            guard let self = self, !self.isRecordingInternal else { return }
            self.startRecording()
        }
        voiceManager.onStop = { [weak self] in
            guard let self = self, self.isRecordingInternal else { return }
            self.stopRecording()
        }

        encoder.onEncodedSample = { [weak self] sampleBuffer in
            guard let self = self else { return }
            self.sessionQueue.async {
                if self.preRecordOnInternal {
                    self.compressedVideoBuffer?.write(sampleBuffer)
                }
                if self.isRecordingInternal {
                    self.writer.appendVideo(sampleBuffer)
                }
            }
        }

        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRecording == true ? self?.stopRecording() : self?.startRecording()
            }
            return .success
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

            if let conn = self.videoOutput.connection(with: .video) {
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = self.stabilizationLevel.avMode
                }
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }

            self.captureSession.commitConfiguration()
            self.setupEncoder()
            self.rebuildBuffers()
            self.applyFrameRate()
            self.captureSession.startRunning()

            DispatchQueue.main.async {
                self.batteryManager.start { [weak self] lvl in self?.batteryLevel = lvl }
                self.startVoiceListening()
            }
        }
    }

    private func setupEncoder() {
        let (w, h) = videoResolution.outputSize
        let fps = frameRate.rawValue
        let bitrate = computeBitrate(resolution: videoResolution, fps: fps)
        encoder.setup(width: w, height: h, fps: fps, bitrate: bitrate)
    }

    private func computeBitrate(resolution: VideoResolution, fps: Int) -> Int {
        let base: Int
        switch resolution {
        case .uhd4K_16x9, .uhd4K_4x3: base = 40_000_000
        case .hd1080_16x9, .hd1080_4x3: base = 16_000_000
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
            let desired = Double(frameRate.rawValue)
            let finalFPS = min(desired, Double(videoResolution.maxFrameRate))
            let format = device.activeFormat
            if format.videoSupportedFrameRateRanges.contains(where: { finalFPS >= $0.minFrameRate && finalFPS <= $0.maxFrameRate }) {
                let d = CMTime(value: 1, timescale: CMTimeScale(finalFPS))
                device.activeVideoMinFrameDuration = d
                device.activeVideoMaxFrameDuration = d
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func startVoiceListening() {
        guard voiceEnabled else { return }
        voiceManager.startWords = customStartWords
        voiceManager.stopWords = customStopWords
        voiceManager.start { [weak self] listening in
            self?.isVoiceListening = listening
        }
    }

    func switchLens(_ lens: CameraLens) {
        guard lens.isAvailable else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .filter { $0.device.hasMediaType(.video) }
                .forEach { self.captureSession.removeInput($0) }
            guard let device = self.deviceFor(lens),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration(); return
            }
            self.captureSession.addInput(input)
            self.currentVideoDevice = device
            if let conn = self.videoOutput.connection(with: .video) {
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = self.stabilizationLevel.avMode
                }
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }
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
            self.setupEncoder()
            self.applyFrameRate()
            self.rebuildBuffers()
        }
    }

    func setStabilization(_ s: StabilizationLevel) {
        DispatchQueue.main.async { self.stabilizationLevel = s }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let conn = self.videoOutput.connection(with: .video),
               conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = s.avMode
            }
        }
    }

    func setPreRecord(_ p: PreRecordOption) {
        DispatchQueue.main.async { self.preRecordOption = p }
        sessionQueue.async { [weak self] in self?.rebuildBuffers() }
    }

    func toggleVoice() {
        voiceEnabled.toggle()
        if voiceEnabled { startVoiceListening() } else { voiceManager.stop() }
    }

    func toggleScreenOffMode() { isScreenOffMode.toggle() }
    func toggleAutoPreRecord() { isAutoPreRecordEnabled.toggle() }

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isRecordingInternal else { return }
            let allSamples = self.compressedVideoBuffer?.snapshot() ?? []
            let validSamples = self.trimToKeyframe(allSamples)
            self.writer.begin(
                videoSamples: validSamples,
                audioSamples: self.audioBuffer?.snapshot() ?? [],
                outputURL: self.makeURL()
            )
            self.isRecordingInternal = true
            DispatchQueue.main.async {
                self.isRecording = true
                if self.shutterSound != .none { BeepPlayer.shared.playStart() }
                else { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
            }
        }
    }

    private func trimToKeyframe(_ samples: [CMSampleBuffer]) -> [CMSampleBuffer] {
        for (i, sample) in samples.enumerated() {
            if isKeyFrame(sample) { return Array(samples[i...]) }
        }
        return []
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.isRecordingInternal else { return }
            self.isRecordingInternal = false
            DispatchQueue.main.async {
                self.isRecording = false
                if self.shutterSound != .none { BeepPlayer.shared.playStop() }
                else { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
            }
            self.writer.end { [weak self] url in
                guard let self = self else { return }
                if let url = url {
                    PhotoLibrarySaver.save(url)
                    self.lastSavedMessage = "✓ 已保存到相册"
                } else {
                    self.lastSavedMessage = "保存失败"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.lastSavedMessage = nil }
                if self.isAutoPreRecordEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.startRecording()
                    }
                }
            }
        }
    }

    private func makeURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        return dir.appendingPathComponent("Fishing_\(fmt.string(from: Date())).mp4")
    }
}

// MARK: - 数据输出
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let shouldForceKey = isRecordingInternal && (compressedVideoBuffer?.count ?? 0) == 0
            encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts, forceKeyframe: shouldForceKey)
        } else if output === audioOutput {
            if preRecordOnInternal, var buf = audioBuffer { buf.write(sampleBuffer) }
            if isRecordingInternal { writer.appendAudio(sampleBuffer) }
            voiceManager.feedAudio(sampleBuffer)
        }
    }
}

// MARK: - 预录写入器（所有方法只在 writerQueue 调用）
final class PreRecordWriter {
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?
    private var active = false
    private var url: URL?
    private let queue = DispatchQueue(label: "com.fishingcamera.writer")

    func begin(videoSamples: [CMSampleBuffer], audioSamples: [CMSampleBuffer], outputURL: URL) {
        queue.async { [weak self] in
            guard let self = self, !self.active else { return }
            self.url = outputURL
            do {
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                let w = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

                // passthrough 必须提供 sourceFormatHint，从首个已编码帧取格式描述
                var vHint: CMFormatDescription? = nil
                for s in videoSamples {
                    if let fd = CMSampleBufferGetFormatDescription(s) { vHint = fd; break }
                }
                guard let vfd = vHint else {
                    print("[Writer] 无视频格式描述，放弃写入"); return
                }
                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vfd)
                vIn.expectsMediaDataInRealTime = false
                vIn.transform = CGAffineTransform(rotationAngle: .pi / 2) // 竖屏
                guard w.canAdd(vIn) else { print("[Writer] 无法添加视频轨道"); return }
                w.add(vIn)

                // 音频：只指定 AAC，采样率/声道跟随麦克风源，避免声明不一致
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVEncoderBitRateKey: 128_000
                ])
                aIn.expectsMediaDataInRealTime = false
                if w.canAdd(aIn) { w.add(aIn) }

                guard w.startWriting() else {
                    print("[Writer] startWriting 失败: \(w.error?.localizedDescription ?? "?")"); return
                }

                // 从首个关键帧开始
                var v = videoSamples
                if let ki = v.firstIndex(where: { isKeyFrame($0) }) {
                    v = Array(v[ki...])
                } else { v = [] }

                let start: CMTime
                if let f = v.first {
                    start = CMSampleBufferGetPresentationTimeStamp(f)
                } else if let f = audioSamples.first {
                    start = CMSampleBufferGetPresentationTimeStamp(f)
                } else {
                    start = .zero
                }
                w.startSession(atSourceTime: start)

                // 严格按 PTS 交替写入历史帧
                let a = audioSamples.filter {
                    CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)) >= CMTimeGetSeconds(start) - 0.02
                }
                var vi = 0, ai = 0
                while vi < v.count || ai < a.count {
                    let takeV: Bool
                    if ai >= a.count { takeV = true }
                    else if vi >= v.count { takeV = false }
                    else {
                        let vt = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(v[vi]))
                        let at = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(a[ai]))
                        takeV = vt <= at
                    }
                    if takeV {
                        if vIn.isReadyForMoreMediaData { vIn.append(v[vi]) }
                        vi += 1
                    } else {
                        if aIn.isReadyForMoreMediaData { aIn.append(a[ai]) }
                        ai += 1
                    }
                }

                self.writer = w
                self.vInput = vIn
                self.aInput = aIn
                self.active = true
                print("[Writer] begin v=\(v.count) a=\(a.count)")
            } catch {
                print("[Writer] begin error: \(error)")
            }
        }
    }

    func appendVideo(_ s: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active,
                  let input = self.vInput,
                  let w = self.writer, w.status == .writing else { return }
            if input.isReadyForMoreMediaData { input.append(s) }
        }
    }

    func appendAudio(_ s: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.active,
                  let input = self.aInput,
                  let w = self.writer, w.status == .writing else { return }
            if input.isReadyForMoreMediaData { input.append(s) }
        }
    }

    func end(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.active, let u = self.url, let w = self.writer else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.active = false
            self.vInput?.markAsFinished()
            self.aInput?.markAsFinished()
            let v = self.vInput, a = self.aInput
            self.vInput = nil; self.aInput = nil; self.writer = nil; self.url = nil
            w.finishWriting {
                let ok = w.status == .completed
                let url = ok ? u : nil
                if let e = w.error { print("[Writer] finish error: \(e)") }
                DispatchQueue.main.async { completion(url) }
            }
        }
    }
}

private func isKeyFrame(_ sb: CMSampleBuffer) -> Bool {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
        as? [[CFString: Any]], let a = arr.first else { return true }
    return !(a[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
}

// MARK: - 提示音（不受静音开关影响，钓鱼时也能听到）
final class BeepPlayer {
    static let shared = BeepPlayer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    /// 生成指定频率的短促 beep 音频缓冲
    private func makeBuffer(freq: Float, duration: TimeInterval) -> AVAudioPCMBuffer {
        let sampleRate: Float = 44100
        let frameCount = AVAudioFrameCount(duration * Double(sampleRate))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let ch = buf.floatChannelData![0]
        let gain: Float = 0.6
        let fade = Int(Double(sampleRate) * 0.01) // 10ms 淡入淡出避免爆音
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            var s = sin(2 * .pi * freq * t) * gain
            if i < fade { s *= Float(i) / Float(fade) }
            else if i > Int(frameCount) - fade { s *= Float(Int(frameCount) - i) / Float(fade) }
            ch[i] = s
        }
        return buf
    }

    private func play(freq: Float, duration: TimeInterval) {
        let buf = makeBuffer(freq: freq, duration: duration)
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !engine.isRunning { try? engine.start() }
        player.play()
        // 同时震动，双重反馈
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    func playStart() { play(freq: 880, duration: 0.15) }   // 高音叮
    func playStop()  { play(freq: 523, duration: 0.20) }   // 低音叮
    func playError() { play(freq: 220, duration: 0.30) }  // 错误提示
}

enum PhotoLibrarySaver {
    static func save(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, err in
                if let err = err { print("[Photo] \(err)") }
            }
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
            self.roll = d.attitude.roll; self.pitch = d.attitude.pitch
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
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var running = false
    private var onListeningChanged: ((Bool) -> Void)?
    private var lastStartTime: TimeInterval = 0
    private var lastStopTime: TimeInterval = 0

    func start(_ onChange: @escaping (Bool) -> Void) {
        guard !running else { return }
        onListeningChanged = onChange
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            guard st == .authorized else { return }
            DispatchQueue.main.async { self?.begin() }
        }
    }

    private func begin() {
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let req = request else { return }
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self = self else { return }
            if let r = result {
                let text = r.bestTranscription.formattedString.replacingOccurrences(of: " ", with: "")
                let now = Date().timeIntervalSince1970
                if self.startWords.contains(where: { text.contains($0) }) {
                    if now - self.lastStartTime > 2.0 {
                        self.lastStartTime = now
                        self.onStart?()
                    }
                } else if self.stopWords.contains(where: { text.contains($0) }) {
                    if now - self.lastStopTime > 2.0 {
                        self.lastStopTime = now
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
        task?.cancel(); task = nil; request = nil; running = false
        DispatchQueue.main.async { self.onListeningChanged?(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.begin() }
    }

    func feedAudio(_ sampleBuffer: CMSampleBuffer) {
        guard running, let req = request else { return }
        guard let pcm = sampleBuffer.toPCMBuffer() else { return }
        req.append(pcm)
    }

    func stop() {
        task?.cancel(); task = nil; request = nil; running = false
        DispatchQueue.main.async { self.onListeningChanged?(false) }
    }
}

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block
        )
        guard status == noErr else { return nil }
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
        if #available(iOS 17.2, *) { content.background(VolumeBtn(action: action)) }
        else { content }
    }
}
@available(iOS 17.2, *)
private struct VolumeBtn: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.isUserInteractionEnabled = false
        // 动态创建 AVCaptureEventInteraction，避免编译时符号依赖
        if let cls = NSClassFromString("AVCaptureEventInteraction") as? NSObject.Type {
            let sel = NSSelectorFromString("initWithHandler:")
            if cls.responds(to: sel) {
                let handler: @convention(block) (AnyObject) -> Void = { e in
                    if let phase = e.value(forKey: "phase") as? Int, phase == 2 { // .ended
                        DispatchQueue.main.async { action() }
                    }
                }
                let interaction = cls.perform(sel, with: handler)?.takeUnretainedValue()
                if let interaction = interaction as? UIInteraction {
                    v.addInteraction(interaction)
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

// MARK: - 预览
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        if let conn = v.previewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 主界面
struct CameraScreen: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var motion = MotionManager()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            CameraPreviewView(session: engine.captureSession).ignoresSafeArea()

            if engine.isScreenOffMode {
                Color.black.opacity(0.97).ignoresSafeArea()
                    .onTapGesture { engine.toggleScreenOffMode() }
            }

            if !engine.isScreenOffMode {
                VStack {
                    HStack(spacing: 8) {
                        if engine.isRecordingStatusVisible {
                            Pill(text: engine.isRecording ? "● REC" : "STBY",
                                 color: engine.isRecording ? .red : .white)
                        }
                        if engine.isVoiceListening {
                            Pill(text: "🎙 语音", color: .green)
                        }
                        Spacer()
                        Pill(text: "\(Int(engine.batteryLevel * 100))%",
                             color: engine.batteryLevel < 0.2 ? .red : .white)
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.white).padding(8)
                                .background(Color.black.opacity(0.5)).clipShape(Circle())
                        }
                    }.padding(.horizontal, 16).padding(.top, 8)
                    Spacer()
                }
            }

            if !engine.isScreenOffMode {
                VStack {
                    Spacer()
                    HStack(spacing: 36) {
                        Button {
                            let avail = CameraLens.allCases.filter { $0.isAvailable }
                            guard !avail.isEmpty else { return }
                            let idx = avail.firstIndex(of: engine.currentLens) ?? 0
                            engine.switchLens(avail[(idx + 1) % avail.count])
                        } label: {
                            Text(engine.currentLens.rawValue)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white).frame(width: 64, height: 44)
                                .background(Color.black.opacity(0.6)).cornerRadius(8)
                        }
                        Button {
                            engine.isRecording ? engine.stopRecording() : engine.startRecording()
                        } label: {
                            ZStack {
                                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                                if engine.isRecording {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 28, height: 28)
                                } else {
                                    Circle().fill(Color.red).frame(width: 56, height: 56)
                                }
                            }
                        }
                        Button { engine.toggleVoice() } label: {
                            Image(systemName: engine.voiceEnabled ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 16))
                                .foregroundColor(engine.voiceEnabled ? .green : .white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.6)).clipShape(Circle())
                        }
                        Button { engine.toggleScreenOffMode() } label: {
                            Image(systemName: engine.isScreenOffMode ? "moon.fill" : "moon")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.6)).clipShape(Circle())
                        }
                    }.padding(.bottom, 30)
                }
            }

            if let msg = engine.lastSavedMessage {
                VStack {
                    Spacer()
                    Text(msg).padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.black.opacity(0.7)).foregroundColor(.white)
                        .cornerRadius(20).padding(.bottom, 120)
                }
            }
        }
        .onAppear { engine.startSession(); motion.start() }
        .onDisappear { motion.stop() }
        .onVolumeButton {
            engine.isRecording ? engine.stopRecording() : engine.startRecording()
        }
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
    }
}

struct Pill: View {
    let text: String; let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(color).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.black.opacity(0.5)).clipShape(Capsule())
    }
}

// MARK: - 设置界面
struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.presentationMode) var dismiss
    private let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("防抖") {
                        ForEach(StabilizationLevel.allCases, id: \.self) { s in
                            Cell(title: s.rawValue, selected: engine.stabilizationLevel == s) {
                                engine.setStabilization(s)
                            }
                        }
                    }
                    group("预录") {
                        ForEach(PreRecordOption.allCases, id: \.self) { p in
                            Cell(title: p.rawValue, selected: engine.preRecordOption == p) {
                                engine.setPreRecord(p)
                            }
                        }
                    }
                    HStack {
                        Text("自动预录（结束后自动开始下一个）")
                            .font(.system(size: 14)).foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { engine.isAutoPreRecordEnabled },
                            set: { _ in engine.toggleAutoPreRecord() }
                        )).accentColor(.green)
                    }.padding(.horizontal, 4)

                    group("切换镜头") {
                        ForEach(CameraLens.allCases, id: \.self) { l in
                            Cell(title: l.rawValue, selected: engine.currentLens == l, enabled: l.isAvailable) {
                                engine.switchLens(l)
                            }
                        }
                    }
                    group("分辨率") {
                        ForEach(VideoResolution.allCases, id: \.self) { r in
                            Cell(title: r.rawValue, selected: engine.videoResolution == r) {
                                engine.setResolution(r)
                            }
                        }
                    }
                    group("帧率") {
                        ForEach(FrameRateOption.allCases, id: \.self) { f in
                            let ok = f.rawValue <= engine.videoResolution.maxFrameRate
                            Cell(title: f.displayName, selected: engine.frameRate == f, enabled: ok) {
                                engine.setFrameRate(f)
                            }
                        }
                    }
                    group("快门声") {
                        ForEach(ShutterSoundOption.allCases, id: \.self) { s in
                            Cell(title: s.rawValue, selected: engine.shutterSound == s) {
                                engine.shutterSound = s
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义语音指令").font(.system(size: 14, weight: .bold)).foregroundColor(.gray)
                        TextField("开始词（逗号分隔）", text: Binding(
                            get: { engine.customStartWords.joined(separator: ",") },
                            set: { engine.customStartWords = $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                        )).textFieldStyle(RoundedBorderTextFieldStyle()).foregroundColor(.white)
                        TextField("结束词（逗号分隔）", text: Binding(
                            get: { engine.customStopWords.joined(separator: ",") },
                            set: { engine.customStopWords = $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
                        )).textFieldStyle(RoundedBorderTextFieldStyle()).foregroundColor(.white)
                    }.padding(.top, 8)
                }.padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss.wrappedValue.dismiss() } label: {
                        Image(systemName: "chevron.left").foregroundColor(.white)
                    }
                }
            }
        }.preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func group<C: View>(_ t: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(.system(size: 14, weight: .bold)).foregroundColor(.gray)
            LazyVGrid(columns: cols, spacing: 10) { content() }
        }
    }
}

struct Cell: View {
    let title: String; let selected: Bool
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .bold : .regular))
                .foregroundColor(enabled ? .white : .gray)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Color(white: 0.2)).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.white : Color.clear, lineWidth: 2))
        }.disabled(!enabled)
    }
}
