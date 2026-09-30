import SwiftUI
import AVFoundation
import Photos
import Speech
import CoreMotion
import UIKit
import MediaPlayer
import Vision
import CoreML

// MARK: - App 入口
@main
struct FishingCameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen().preferredColorScheme(.dark)
        }
    }
}

// MARK: - 环形缓冲区
struct CircularFrameBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func write(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    func snapshot() -> [Element] {
        guard count > 0 else { return [] }
        var result: [Element] = []
        result.reserveCapacity(count)
        let startIndex = count < capacity ? 0 : writeIndex
        for offset in 0..<count {
            let index = (startIndex + offset) % capacity
            if let element = storage[index] { result.append(element) }
        }
        return result
    }

    mutating func clear() {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}

// MARK: - 枚举
enum CameraLens: String, CaseIterable {
    case ultraWide = "0.5×"
    case wide      = "1×"
    case telephoto = "3×"
    var displayName: String { rawValue }
}

enum VideoResolution: String, CaseIterable {
    case hd1080 = "1080P"
    case uhd4K  = "4K"
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd1080: return .hd1920x1080
        case .uhd4K:  return .hd4K3840x2160
        }
    }
    var width: Int { self == .hd1080 ? 1920 : 3840 }
    var height: Int { self == .hd1080 ? 1080 : 2160 }
}

enum FrameRateOption: Int, CaseIterable {
    case auto = 0
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120
    case fps240 = 240
    var displayName: String { self == .auto ? "自动" : "\(rawValue)fps" }
}

enum AspectRatioMode: String, CaseIterable {
    case ratio16x9 = "16:9"
    case ratio4x3  = "4:3"
    var ratioValue: Double {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3:  return 4.0 / 3.0
        }
    }
}

enum StabilizationLevel: String, CaseIterable {
    case auto     = "自动"
    case standard = "标准"
    case smooth   = "平滑"
    case enhanced = "增强"
}

enum VoiceLanguage: String, CaseIterable {
    case chineseMandarin = "zh-CN"
    case chineseCantonese = "zh-HK"
    case english = "en-US"
    var displayName: String {
        switch self {
        case .chineseMandarin: return "普通话"
        case .chineseCantonese: return "粤语"
        case .english: return "English"
        }
    }
}

// MARK: - 相机引擎
@MainActor
final class CameraEngine: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var preRecordDuration: TimeInterval = 30
    @Published var currentLens: CameraLens = .wide
    @Published var isPreRecordEnabled = true
    @Published var videoResolution: VideoResolution = .hd1080
    @Published var frameRate: FrameRateOption = .auto
    @Published var aspectRatio: AspectRatioMode = .ratio16x9
    @Published var stabilizationLevel: StabilizationLevel = .auto
    @Published var isScreenOffMode = false
    @Published var isUIVisible = true
    @Published var isAutoContinuousPreRecord = false
    @Published var isNightFillLightEnabled = false
    @Published var isMusicPlaybackEnabled = false
    @Published var isDelayCaptureEnabled = false
    @Published var delayCaptureSeconds: Int = 3
    @Published var lastSavedMessage: String?
    @Published var batteryLevel: Float = 1.0

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.fishingcamera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentVideoDevice: AVCaptureDevice?

    private var frameBuffer: CircularFrameBuffer<CMSampleBuffer>?
    private var audioBuffer: CircularFrameBuffer<CMSampleBuffer>?
    private let fpsEstimate: Double = 30
    private var bufferCapacity: Int { Int(preRecordDuration * fpsEstimate) }

    private let writer = PreRecordWriter()
    private let batteryManager = BatteryManager()
    private let manualControls = ManualCameraControls()

    private var musicPlayer: AVAudioPlayer?
    private var delayTimer: Timer?

    func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = self.videoResolution.sessionPreset

            guard let videoDevice = self.videoDevice(for: .wide),
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
                  self.captureSession.canAddInput(videoInput) else {
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addInput(videoInput)
            self.currentVideoDevice = videoDevice

            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.captureSession.canAddInput(audioInput) {
                self.captureSession.addInput(audioInput)
            }

            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }

            self.audioOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            if self.captureSession.canAddOutput(self.audioOutput) {
                self.captureSession.addOutput(self.audioOutput)
            }

            self.applyStabilization()
            self.applyFrameRateInternal()
            self.captureSession.commitConfiguration()
            self.rebuildBuffers()
            self.captureSession.startRunning()

            Task { @MainActor in
                self.isSessionRunning = true
                self.batteryManager.startMonitoring { [weak self] level in
                    self?.batteryLevel = level
                }
                self.batteryManager.onLowBattery = { [weak self] in
                    self?.handleLowBattery()
                }
            }
        }
    }

    func switchLens(to lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.inputs
                .filter { $0 is AVCaptureDeviceInput && ($0 as! AVCaptureDeviceInput).device.hasMediaType(.video) }
                .forEach { self.captureSession.removeInput($0) }

            guard let device = self.videoDevice(for: lens),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addInput(input)
            self.currentVideoDevice = device
            self.captureSession.commitConfiguration()
            Task { @MainActor in self.currentLens = lens }
        }
    }

    private func videoDevice(for lens: CameraLens) -> AVCaptureDevice? {
        switch lens {
        case .ultraWide: return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .wide:      return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .telephoto: return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        }
    }

    func applyStabilization() {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoStabilizationSupported else { return }
        switch stabilizationLevel {
        case .auto:     connection.preferredVideoStabilizationMode = .auto
        case .standard: connection.preferredVideoStabilizationMode = .standard
        case .smooth:   connection.preferredVideoStabilizationMode = .cinematic
        case .enhanced:
            if #available(iOS 13.0, *) {
                connection.preferredVideoStabilizationMode = .cinematicExtended
            } else {
                connection.preferredVideoStabilizationMode = .cinematic
            }
        }
    }

    func applyFrameRate() {
        sessionQueue.async { [weak self] in self?.applyFrameRateInternal() }
    }

    private func applyFrameRateInternal() {
        guard let device = currentVideoDevice else { return }
        try? device.lockForConfiguration()
        let desiredFPS: Double = frameRate == .auto ? 30 : Double(frameRate.rawValue)
        let format = device.activeFormat
        let supportsFPS = format.videoSupportedFrameRateRanges.contains {
            desiredFPS >= $0.minFrameRate && desiredFPS <= $0.maxFrameRate
        }
        if supportsFPS {
            let duration = CMTimeMake(value: 1, timescale: Int32(desiredFPS))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.unlockForConfiguration()
    }

    private func rebuildBuffers() {
        frameBuffer = CircularFrameBuffer<CMSampleBuffer>(capacity: bufferCapacity)
        audioBuffer = CircularFrameBuffer<CMSampleBuffer>(capacity: bufferCapacity)
    }

    func updatePreRecordDuration(_ duration: TimeInterval) {
        preRecordDuration = duration
        sessionQueue.async { [weak self] in self?.rebuildBuffers() }
    }

    func startRecording() {
        guard !isRecording, let buffer = frameBuffer else { return }
        if isDelayCaptureEnabled && delayCaptureSeconds > 0 {
            startDelayCountdown()
            return
        }
        performStartRecording(buffer: buffer)
    }

    private func startDelayCountdown() {
        var remaining = delayCaptureSeconds
        SoundFeedbackManager.shared.playDelayTick()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                Task { @MainActor in
                    guard let self, let buffer = self.frameBuffer else { return }
                    self.performStartRecording(buffer: buffer)
                }
            } else {
                SoundFeedbackManager.shared.playDelayTick()
            }
        }
    }

    private func performStartRecording(buffer: CircularFrameBuffer<CMSampleBuffer>) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let frames = buffer.snapshot()
            let audio = self.audioBuffer?.snapshot() ?? []
            let url = self.makeOutputURL()
            self.writer.beginSession(historicalFrames: frames,
                                      historicalAudio: audio,
                                      outputURL: url,
                                      resolution: self.videoResolution,
                                      aspectRatio: self.aspectRatio)
            Task { @MainActor in
                self.isRecording = true
                SoundFeedbackManager.shared.playStartSound()
                if self.isMusicPlaybackEnabled { self.startMusicPlayback() }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        stopMusicPlayback()
        sessionQueue.async { [weak self] in
            self?.writer.endSession()
            Task { @MainActor in
                self?.isRecording = false
                SoundFeedbackManager.shared.playStopSound()
                if self?.isAutoContinuousPreRecord == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.startRecording()
                    }
                }
            }
        }
    }

    private func makeOutputURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return documents.appendingPathComponent("Fishing_\(formatter.string(from: Date())).mp4")
    }

    private func handleLowBattery() {
        if isRecording { stopRecording() }
        lastSavedMessage = "电量不足，已自动保存"
    }

    private func startMusicPlayback() {
        guard let url = Bundle.main.url(forResource: "background_music", withExtension: "mp3") else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            musicPlayer = try AVAudioPlayer(contentsOf: url)
            musicPlayer?.numberOfLoops = -1
            musicPlayer?.volume = 0.2
            musicPlayer?.play()
        } catch { print("[CameraEngine] 音乐播放失败: \(error)") }
    }

    private func stopMusicPlayback() {
        musicPlayer?.stop()
        musicPlayer = nil
    }

    func toggleNightFillLight() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice else { return }
            try? device.lockForConfiguration()
            if self.isNightFillLightEnabled {
                if device.isTorchAvailable { try? device.setTorchModeOn(level: 1.0) }
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        }
    }

    func setExposure(_ value: Float) { manualControls.setExposure(value, on: currentVideoDevice) }
    func setISO(_ value: Float) { manualControls.setISO(value, on: currentVideoDevice) }
    func setWhiteBalance(_ value: Float) { manualControls.setWhiteBalance(value, on: currentVideoDevice) }
    func setFocus(_ point: CGPoint) { manualControls.setFocus(point, on: currentVideoDevice) }
    func setZoom(_ factor: CGFloat) { manualControls.setZoom(factor, on: currentVideoDevice) }

    func captureFrameForAI(completion: @escaping (CVPixelBuffer?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let buffer = self.frameBuffer else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let frames = buffer.snapshot()
            guard let last = frames.last,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(last) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(pixelBuffer) }
        }
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Task { @MainActor in
            if output is AVCaptureVideoDataOutput {
                frameBuffer?.write(sampleBuffer)
                if isRecording { writer.appendFrame(sampleBuffer) }
            } else if output is AVCaptureAudioDataOutput {
                audioBuffer?.write(sampleBuffer)
                if isRecording { writer.appendAudio(sampleBuffer) }
            }
        }
    }
}

// MARK: - 预录写入器
final class PreRecordWriter {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isSessionActive = false
    private var currentOutputURL: URL?

    func beginSession(historicalFrames: [CMSampleBuffer],
                      historicalAudio: [CMSampleBuffer],
                      outputURL: URL,
                      resolution: VideoResolution,
                      aspectRatio: AspectRatioMode) {
        guard !isSessionActive else { return }
        currentOutputURL = outputURL

        let width = resolution.width
        let height = Int(Double(width) / aspectRatio.ratioValue)

        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: resolution == .uhd4K ? 30_000_000 : 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]

            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true

            if let v = videoInput, assetWriter!.canAdd(v) { assetWriter!.add(v) }
            if let a = audioInput, assetWriter!.canAdd(a) { assetWriter!.add(a) }

            assetWriter?.startWriting()

            if let firstFrame = historicalFrames.first {
                let startTime = CMSampleBufferGetPresentationTimeStamp(firstFrame)
                assetWriter?.startSession(atSourceTime: startTime)
            } else {
                assetWriter?.startSession(atSourceTime: .zero)
            }

            isSessionActive = true
            for frame in historicalFrames { appendFrame(frame) }
            for audio in historicalAudio { appendAudio(audio) }
        } catch {
            print("[PreRecordWriter] Setup failed: \(error)")
        }
    }

    func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isSessionActive, let input = videoInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isSessionActive, let input = audioInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func endSession() {
        guard isSessionActive, let url = currentOutputURL else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        assetWriter?.finishWriting { [weak self] in
            PhotoLibrarySaver.saveVideo(at: url) { _, _ in }
            self?.cleanup()
        }
    }

    private func cleanup() {
        assetWriter = nil; videoInput = nil; audioInput = nil
        isSessionActive = false; currentOutputURL = nil
    }
}

enum PhotoLibrarySaver {
    static func saveVideo(at url: URL, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(false, NSError(domain: "PhotoLibrarySaver", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "相册权限未授权"]))
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async { completion(success, error) }
            }
        }
    }
}

// MARK: - 手动参数控制
final class ManualCameraControls {
    func setExposure(_ value: Float, on device: AVCaptureDevice?) {
        guard let device, device.isExposureModeSupported(.custom) else { return }
        try? device.lockForConfiguration()
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let clampedISO = min(max(value, minISO), maxISO)
        let duration = CMTimeMake(value: 1, timescale: 60)
        device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
        device.unlockForConfiguration()
    }
    func setISO(_ value: Float, on device: AVCaptureDevice?) {
        guard let device, device.isExposureModeSupported(.custom) else { return }
        try? device.lockForConfiguration()
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let clampedISO = min(max(value, minISO), maxISO)
        device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: clampedISO, completionHandler: nil)
        device.unlockForConfiguration()
    }
    func setWhiteBalance(_ value: Float, on device: AVCaptureDevice?) {
        guard let device, device.isWhiteBalanceModeSupported(.locked) else { return }
        try? device.lockForConfiguration()
        let temp = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: value, tint: 0)
        device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains(for: temp), completionHandler: nil)
        device.unlockForConfiguration()
    }
    func setFocus(_ point: CGPoint, on device: AVCaptureDevice?) {
        guard let device, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) else { return }
        try? device.lockForConfiguration()
        device.focusPointOfInterest = point
        device.focusMode = .autoFocus
        device.unlockForConfiguration()
    }
    func setZoom(_ factor: CGFloat, on device: AVCaptureDevice?) {
        guard let device else { return }
        try? device.lockForConfiguration()
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)
        let clampedZoom = min(max(factor, 1.0), maxZoom)
        device.videoZoomFactor = clampedZoom
        device.unlockForConfiguration()
    }
}

// MARK: - 语音引擎
protocol SpeechEngine: AnyObject {
    var onTextRecognized: ((String) -> Void)? { get set }
    func start(locale: Locale) async throws
    func stop()
}

@available(iOS 26.0, *)
final class ModernSpeechEngine: SpeechEngine {
    var onTextRecognized: ((String) -> Void)?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?

    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        Task { [weak self] in
            for try await result in transcriber.results {
                await MainActor.run { self?.onTextRecognized?(String(result.text.characters)) }
            }
        }
        try await analyzer.start()
    }
    func stop() { Task { try? await analyzer?.stop() } }
}

@available(iOS 10.0, *)
final class LegacySpeechEngine: NSObject, SpeechEngine, SFSpeechRecognizerDelegate {
    var onTextRecognized: ((String) -> Void)?
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(locale: Locale) async throws {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        speechRecognizer?.delegate = self
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "语音识别不可用"])
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard status == .authorized else {
            throw NSError(domain: "SpeechEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "语音识别权限未授权"])
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                DispatchQueue.main.async { self.onTextRecognized?(result.bestTranscription.formattedString) }
            }
            if error != nil || (result?.isFinal ?? false) { self.restartIfNeeded() }
        }
    }
    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
    }
    private func restartIfNeeded() { }
}

// MARK: - 语音控制引擎
@MainActor
final class VoiceCommandEngine: ObservableObject {
    @Published var isListening = false
    @Published var lastRecognizedText = ""
    @Published var isWakeWordActive = false
    @Published var wakeWord: String = "你好小钓"
    @Published var startPhrases: Set<String> = ["开始录像", "开始录制", "录一下"]
    @Published var stopPhrases: Set<String> = ["结束录像", "停止录制", "保存"]
    @Published var photoPhrases: Set<String> = ["拍照", "影相", "take a photo"]
    @Published var language: VoiceLanguage = .chineseMandarin

    var onStartCommand: (() -> Void)?
    var onStopCommand: (() -> Void)?
    var onPhotoCommand: (() -> Void)?

    private var engine: SpeechEngine?
    private var listeningTask: Task<Void, Never>?

    func startListening() {
        guard !isListening else { return }
        let speechEngine: SpeechEngine
        if #available(iOS 26.0, *) {
            speechEngine = ModernSpeechEngine()
        } else {
            speechEngine = LegacySpeechEngine()
        }
        speechEngine.onTextRecognized = { [weak self] text in
            Task { @MainActor in
                self?.lastRecognizedText = text
                self?.processText(text)
            }
        }
        self.engine = speechEngine
        listeningTask = Task {
            do {
                try await speechEngine.start(locale: Locale(identifier: language.rawValue))
                await MainActor.run { self.isListening = true }
            } catch { print("[VoiceCommandEngine] Failed: \(error)") }
        }
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
        engine?.stop()
        isListening = false
    }

    private func processText(_ text: String) {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        if normalized.contains(wakeWord) {
            isWakeWordActive = true
            SoundFeedbackManager.shared.playWakeSound()
            return
        }
        if startPhrases.contains(where: { normalized.contains($0) }) { onStartCommand?() }
        else if stopPhrases.contains(where: { normalized.contains($0) }) { onStopCommand?() }
        else if photoPhrases.contains(where: { normalized.contains($0) }) { onPhotoCommand?() }
    }
}

// MARK: - 传感器
@MainActor
final class MotionManager: ObservableObject {
    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false
    private let motionManager = CMMotionManager()
    private let filteringFactor = 0.1

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data = data, let self else { return }
            self.roll = data.attitude.roll * self.filteringFactor + self.roll * (1 - self.filteringFactor)
            self.pitch = data.attitude.pitch * self.filteringFactor + self.pitch * (1 - self.filteringFactor)
            self.isLevel = abs(self.roll) < 0.02 && abs(self.pitch) < 0.02
        }
    }
    func stop() { motionManager.stopDeviceMotionUpdates() }
}

@MainActor
final class BatteryManager {
    var onLevelChange: ((Float) -> Void)?
    var lowBatteryThreshold: Float = 0.15
    var onLowBattery: (() -> Void)?
    private var timer: Timer?

    func startMonitoring(onLevel: @escaping (Float) -> Void) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        onLevelChange = onLevel
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let level = UIDevice.current.batteryLevel
                self.onLevelChange?(level)
                if level < self.lowBatteryThreshold { self.onLowBattery?() }
            }
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }
    deinit { stop() }
}

// MARK: - 声音反馈
final class SoundFeedbackManager {
    static let shared = SoundFeedbackManager()
    var isEnabled = true
    func playStartSound() { guard isEnabled else { return }; AudioServicesPlaySystemSound(1104) }
    func playStopSound() { guard isEnabled else { return }; AudioServicesPlaySystemSound(1105) }
    func playWakeSound() { guard isEnabled else { return }; AudioServicesPlaySystemSound(1057) }
    func playDelayTick() { guard isEnabled else { return }; AudioServicesPlaySystemSound(1103) }
}

// MARK: - 音量键控制
struct VolumeButtonModifier: ViewModifier {
    let onPrimaryAction: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 17.2, *) {
            content.overlay { VolumeButtonCaptureView(action: onPrimaryAction) }
        } else {
            content.overlay { LegacyVolumeButtonView(action: onPrimaryAction) }
        }
    }
}

@available(iOS 17.2, *)
private struct VolumeButtonCaptureView: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let interaction = AVCaptureEventInteraction { event in
            if event.phase == .ended { action() }
        }
        view.addInteraction(interaction)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct LegacyVolumeButtonView: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(true)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    func onVolumeButtonCapture(perform action: @escaping () -> Void) -> some View {
        modifier(VolumeButtonModifier(onPrimaryAction: action))
    }
}

// MARK: - AI 识鱼（需要你自己添加 CoreML 模型，否则此功能不可用）
@MainActor
final class FishClassifier: ObservableObject {
    @Published var detectedSpecies: String?
    @Published var confidence: Float = 0
    private var visionModel: VNCoreMLModel?
    private var isBusy = false

    init() { loadModel() }
    private func loadModel() {
        // 需要将 FishDetector.mlmodel 拖入项目，然后在此处加载
        // guard let model = try? VNCoreMLModel(for: FishDetector(configuration: MLModelConfiguration()).model) else { return }
        // self.visionModel = model
    }
    func classify(pixelBuffer: CVPixelBuffer) {
        guard !isBusy, let model = visionModel else { return }
        isBusy = true
        let request = VNCoreMLRequest(model: model) { [weak self] request, _ in
            defer { Task { @MainActor in self?.isBusy = false } }
            guard let results = request.results as? [VNRecognizedObjectObservation],
                  let top = results.first?.labels.first else { return }
            Task { @MainActor in
                self?.detectedSpecies = top.identifier
                self?.confidence = top.confidence
            }
        }
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        DispatchQueue.global(qos: .userInitiated).async { try? handler.perform([request]) }
    }
}

// MARK: - 蓝牙按钮控制（可选）
final class BluetoothButtonHandler {
    static let shared = BluetoothButtonHandler()
    private init() {}
    func startListening() {
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .bluetoothButtonPressed, object: nil)
            return .success
        }
    }
}

extension Notification.Name {
    static let bluetoothButtonPressed = Notification.Name("bluetoothButtonPressed")
}

// MARK: - UI 主题
struct FishingTheme {
    static let accent = Color(red: 0.15, green: 0.78, blue: 0.65)
    static let recording = Color(red: 0.95, green: 0.30, blue: 0.25)
    static let panelBg = Color.black.opacity(0.45)
    static let cornerRadius: CGFloat = 16
}

// MARK: - 主屏幕
struct CameraScreen: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var voice = VoiceCommandEngine()
    @StateObject private var motion = MotionManager()
    @State private var showControlPanel = true
    @State private var showGrid = true

    var body: some View {
        ZStack {
            CameraPreviewView(session: engine.captureSession).ignoresSafeArea()
            if showGrid && engine.isUIVisible {
                GridOverlay().ignoresSafeArea()
                LevelIndicator(motion: motion)
                    .position(x: UIScreen.main.bounds.width / 2, y: 120)
            }
            if engine.isScreenOffMode {
                Color.black.opacity(0.97).ignoresSafeArea()
                    .onTapGesture { engine.isScreenOffMode = false }
            }
            if engine.isUIVisible && !engine.isScreenOffMode {
                VStack { TopStatusBar(engine: engine, voice: voice); Spacer() }
            }
            if showControlPanel && engine.isUIVisible && !engine.isScreenOffMode {
                HStack {
                    Spacer()
                    ControlPanel(engine: engine, showGrid: $showGrid)
                        .padding(.trailing, 12)
                }
            }
            if engine.isUIVisible && !engine.isScreenOffMode {
                VStack { Spacer(); BottomRecordBar(engine: engine, voice: voice) }
            }
            if let msg = engine.lastSavedMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(FishingTheme.panelBg)
                        .clipShape(Capsule())
                        .padding(.bottom, 140)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { engine.lastSavedMessage = nil }
                    }
                }
            }
        }
        .statusBarHidden(engine.isScreenOffMode)
        .onAppear {
            engine.configureSession()
            motion.start()
            voice.onStartCommand = { engine.startRecording() }
            voice.onStopCommand = { engine.stopRecording() }
            voice.startListening()
            BluetoothButtonHandler.shared.startListening()
            NotificationCenter.default.addObserver(forName: .bluetoothButtonPressed, object: nil, queue: .main) { _ in
                engine.isRecording ? engine.stopRecording() : engine.startRecording()
            }
        }
        .onDisappear {
            voice.stopListening()
            motion.stop()
        }
        .onVolumeButtonCapture {
            engine.isRecording ? engine.stopRecording() : engine.startRecording()
        }
    }
}

// MARK: - 预览层
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 网格与水平仪
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { path in
                for i in 1..<3 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        }
    }
}

struct LevelIndicator: View {
    @ObservedObject var motion: MotionManager
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(motion.isLevel ? FishingTheme.accent : .yellow).frame(width: 6, height: 6)
            Text(String(format: "%.1f°", motion.roll * 180 / .pi))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(FishingTheme.panelBg)
        .clipShape(Capsule())
    }
}

// MARK: - 顶部状态栏
struct TopStatusBar: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var voice: VoiceCommandEngine
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(engine.isPreRecordEnabled ? FishingTheme.accent : .gray).frame(width: 8, height: 8)
                Text(engine.isPreRecordEnabled ? "预录 \(Int(engine.preRecordDuration))s" : "预录关")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(FishingTheme.panelBg).clipShape(Capsule())

            HStack(spacing: 4) {
                Image(systemName: engine.batteryLevel < 0.2 ? "battery.25" : "battery.100").font(.system(size: 12))
                Text("\(Int(engine.batteryLevel * 100))%").font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(engine.batteryLevel < 0.2 ? FishingTheme.recording : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(FishingTheme.panelBg).clipShape(Capsule())

            Spacer()

            Image(systemName: voice.isWakeWordActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 16))
                .foregroundStyle(voice.isWakeWordActive ? FishingTheme.accent : .white.opacity(0.6))
                .padding(8).background(FishingTheme.panelBg).clipShape(Circle())
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }
}

// MARK: - 底部录制栏
struct BottomRecordBar: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var voice: VoiceCommandEngine
    var body: some View {
        HStack(spacing: 36) {
            Button {
                withAnimation {
                    let all = CameraLens.allCases
                    let idx = all.firstIndex(of: engine.currentLens) ?? 0
                    engine.switchLens(to: all[(idx + 1) % all.count])
                }
            } label: {
                Text(engine.currentLens.displayName)
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(FishingTheme.panelBg).clipShape(Circle())
            }
            Button {
                engine.isRecording ? engine.stopRecording() : engine.startRecording()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    if engine.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(FishingTheme.recording).frame(width: 28, height: 28)
                    } else {
                        Circle().fill(FishingTheme.recording).frame(width: 56, height: 56)
                    }
                }
            }
            Button {
                voice.isListening ? voice.stopListening() : voice.startListening()
            } label: {
                Image(systemName: voice.isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(voice.isListening ? FishingTheme.accent : .gray)
                    .frame(width: 44, height: 44).background(FishingTheme.panelBg).clipShape(Circle())
            }
        }
        .padding(.bottom, 24)
    }
}

// MARK: - 右侧控制面板
struct ControlPanel: View {
    @ObservedObject var engine: CameraEngine
    @Binding var showGrid: Bool
    var body: some View {
        VStack(spacing: 12) {
            PanelButton(icon: engine.isPreRecordEnabled ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle", isActive: engine.isPreRecordEnabled) {
                engine.isPreRecordEnabled.toggle()
            }
            VStack(spacing: 2) {
                Text("\(Int(engine.preRecordDuration))s").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("预录").font(.system(size: 9)).foregroundStyle(.gray)
            }
            .frame(width: 52, height: 52).background(FishingTheme.panelBg).clipShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture {
                let durations: [TimeInterval] = [5, 15, 30, 60, 120]
                let idx = durations.firstIndex(of: engine.preRecordDuration) ?? 2
                engine.updatePreRecordDuration(durations[(idx + 1) % durations.count])
            }
            PanelButton(icon: engine.videoResolution == .uhd4K ? "4k.tv.fill" : "tv", isActive: engine.videoResolution == .uhd4K) {
                engine.videoResolution = engine.videoResolution == .uhd4K ? .hd1080 : .uhd4K
            }
            PanelButton(icon: "speedometer", isActive: engine.frameRate != .auto) {
                let all = FrameRateOption.allCases
                let idx = all.firstIndex(of: engine.frameRate) ?? 0
                engine.frameRate = all[(idx + 1) % all.count]
                engine.applyFrameRate()
            }
            PanelButton(icon: engine.aspectRatio == .ratio4x3 ? "rectangle" : "rectangle.expand.vertical", isActive: engine.aspectRatio == .ratio4x3) {
                engine.aspectRatio = engine.aspectRatio == .ratio4x3 ? .ratio16x9 : .ratio4x3
            }
            PanelButton(icon: "grid", isActive: showGrid) { withAnimation { showGrid.toggle() } }
            PanelButton(icon: engine.isScreenOffMode ? "moon.fill" : "moon", isActive: engine.isScreenOffMode) {
                withAnimation { engine.isScreenOffMode.toggle() }
            }
            PanelButton(icon: "repeat.circle", isActive: engine.isAutoContinuousPreRecord) {
                engine.isAutoContinuousPreRecord.toggle()
            }
            PanelButton(icon: engine.isNightFillLightEnabled ? "flashlight.on.fill" : "flashlight.off.fill", isActive: engine.isNightFillLightEnabled) {
                engine.isNightFillLightEnabled.toggle()
                engine.toggleNightFillLight()
            }
            PanelButton(icon: "timer", isActive: engine.isDelayCaptureEnabled) {
                engine.isDelayCaptureEnabled.toggle()
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: FishingTheme.cornerRadius)
            .fill(FishingTheme.panelBg)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: FishingTheme.cornerRadius)))
    }
}

struct PanelButton: View {
    let icon: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isActive ? FishingTheme.accent : .white)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(isActive ? FishingTheme.accent.opacity(0.2) : Color.clear))
        }
    }
}