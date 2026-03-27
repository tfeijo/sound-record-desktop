import AVFoundation
import Observation

@Observable
final class AudioEngine {
    // MARK: - Published State

    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0.0
    private(set) var elapsedSeconds: Int = 0
    private(set) var currentMeetingID: UUID?
    private(set) var error: String?

    // MARK: - Private

    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
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
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            let bufferSize: AVAudioFrameCount = 4096
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
                [weak self] buffer, _ in
                guard let self else { return }
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

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
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

    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Calculate audio level from the raw input buffer
        updateAudioLevel(from: buffer)

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

        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else { return }

        do {
            try audioFile?.write(from: convertedBuffer)
        } catch {
            // Silently drop buffer on write error to avoid flooding logs
        }
    }

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelSamples = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

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
        let normalized = max(0.0, min(1.0, (db - minDb) / (-minDb)))

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = normalized
        }
    }

    private func startElapsedTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(start))
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false
        recordingStartTime = nil
        stopElapsedTimer()
    }
}
