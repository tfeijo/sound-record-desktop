@preconcurrency import AVFoundation
import Observation

@MainActor @Observable
final class AudioEngine {
    // MARK: - Published State

    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0.0
    private(set) var elapsedSeconds: Int = 0
    private(set) var currentMeetingID: UUID?
    var error: String?

    /// Callback invoked with each raw audio buffer from the hardware mic tap.
    /// Set this before calling `startRecording()` to receive buffers (e.g., for live transcription).
    @ObservationIgnored nonisolated(unsafe) var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Private

    private var engine = AVAudioEngine()
    private let fileLock = NSLock()
    @ObservationIgnored private nonisolated(unsafe) var _audioFile: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "com.meetnotes.audiowrite")
    private var recordingStartTime: Date?
    private var levelTimer: Timer?

    // MARK: - Recording Directory

    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("MeetNotes", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    // MARK: - Public API

    /// Start recording mic audio to a WAV file.
    /// Returns the meeting UUID so the caller can create a SwiftData Meeting.
    @discardableResult
    func startRecording() -> UUID {
        let meetingID = UUID()
        currentMeetingID = meetingID
        error = nil
        audioLevel = 0.0
        elapsedSeconds = 0

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            self.error = "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone."
            return meetingID
        case .notDetermined:
            // Will be triggered by inputNode access below
            break
        case .authorized:
            break
        @unknown default:
            break
        }

        do {
            try ensureRecordingsDirectory()
            let fileURL = Self.recordingsDirectory
                .appendingPathComponent("meeting_\(meetingID.uuidString)_mic.wav")

            let inputNode = engine.inputNode
            let hardwareFormat = inputNode.outputFormat(forBus: 0)

            // Target format: 16 kHz mono Float32
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                self.error = "Failed to create target audio format"
                return meetingID
            }

            // Create converter from hardware format to target format
            guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
                self.error = "Failed to create audio converter from \(hardwareFormat) to \(targetFormat)"
                return meetingID
            }

            // Create output WAV file with target format
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            fileLock.lock()
            _audioFile = file
            fileLock.unlock()

            let bufferSize: AVAudioFrameCount = 4096
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
                [weak self] buffer, _ in
                guard let self else { return }
                // Forward raw buffer to external handler (e.g., LiveTranscriber)
                self.audioBufferHandler?(buffer)
                self.processBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }

            try engine.start()
            isRecording = true
            recordingStartTime = Date()
            startElapsedTimer()

        } catch {
            self.error = "Recording failed: \(error.localizedDescription)"
            cleanup()
        }

        return meetingID
    }

    func stopRecording() {
        guard isRecording else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        fileLock.lock()
        _audioFile = nil
        fileLock.unlock()

        audioBufferHandler = nil
        isRecording = false
        recordingStartTime = nil
        stopElapsedTimer()
        audioLevel = 0.0
    }

    /// The file path for a given meeting UUID.
    static func micPath(for meetingID: UUID) -> String {
        recordingsDirectory
            .appendingPathComponent("meeting_\(meetingID.uuidString)_mic.wav")
            .path
    }

    // MARK: - Private Helpers

    private nonisolated func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Calculate audio level from the raw input buffer
        let level = Self.calculateLevel(from: buffer)
        Task { @MainActor [weak self] in
            self?.audioLevel = level
        }

        // Convert to target format and write
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (16_000.0 / buffer.format.sampleRate)
        )
        guard frameCapacity > 0,
              let convertedBuffer = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: frameCapacity
              )
        else { return }

        var hasProvidedData = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else { return }

        // Write on a dedicated queue to avoid blocking the audio render thread
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            try? self._audioFile?.write(from: convertedBuffer)
        }
    }

    private nonisolated static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let channelSamples = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        // RMS calculation
        var sumOfSquares: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelSamples[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrtf(sumOfSquares / Float(frameLength))

        // Normalize to 0.0-1.0 range using a reasonable dB scale
        // -60 dB (silence) to 0 dB (max) mapped to 0.0-1.0
        let minDb: Float = -60.0
        let db = 20.0 * log10f(max(rms, 1e-6))
        return max(0.0, min(1.0, (db - minDb) / (-minDb)))
    }

    private func startElapsedTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let start = self.recordingStartTime else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func ensureRecordingsDirectory() throws {
        let dir = Self.recordingsDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
    }

    private func cleanup() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        fileLock.lock()
        _audioFile = nil
        fileLock.unlock()
        isRecording = false
        recordingStartTime = nil
        stopElapsedTimer()
    }
}
