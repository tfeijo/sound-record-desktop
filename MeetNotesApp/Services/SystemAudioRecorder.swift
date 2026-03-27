@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import Observation

/// Captures system audio using ScreenCaptureKit's SCStream (audio-only).
///
/// This class runs an SCStream configured for audio capture with video minimized
/// (1x1 pixel). It writes received CMSampleBuffers to a WAV file at 16 kHz mono Float32.
///
/// **Threading model:** The class is `@MainActor` for observable state. Audio callbacks
/// arrive on a non-main serial queue; file writes happen on a dedicated write queue
/// protected by `NSLock`, matching the pattern in `AudioEngine`.
@MainActor @Observable
final class SystemAudioRecorder: NSObject {
    // MARK: - Observable State

    private(set) var isCapturing = false
    var warning: String?

    // MARK: - Private Properties

    @ObservationIgnored private nonisolated(unsafe) var stream: SCStream?
    @ObservationIgnored private nonisolated(unsafe) var _audioFile: AVAudioFile?
    @ObservationIgnored private let fileLock = NSLock()
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "com.meetnotes.systemaudiowrite")
    @ObservationIgnored private let callbackQueue = DispatchQueue(label: "com.meetnotes.systemaudiocallback")

    // MARK: - Public API

    /// Begin capturing system audio, writing to a WAV file for the given meeting ID.
    /// Returns immediately. Sets `warning` if permission is denied (mic-only fallback).
    func startCapture(meetingID: UUID) async {
        warning = nil

        // 1. Get shareable content to find a display for the content filter
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            self.warning = "Screen Recording permission required for system audio. Recording mic only."
            return
        }

        guard let display = content.displays.first else {
            self.warning = "No display found for system audio capture. Recording mic only."
            return
        }

        // 2. Configure stream: audio-only (1x1 video to satisfy API requirement)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.width = 1
        config.height = 1

        // 3. Create content filter for the display (captures all audio)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 4. Prepare output WAV file
        let fileURL = AudioEngine.recordingsDirectory
            .appendingPathComponent("meeting_\(meetingID.uuidString)_system.wav")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            self.warning = "Failed to create audio format for system audio."
            return
        }

        do {
            try ensureRecordingsDirectory()
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            setAudioFile(file)
        } catch {
            self.warning = "Failed to create system audio file: \(error.localizedDescription)"
            return
        }

        // 5. Create and start the stream
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = scStream

        do {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
            try await scStream.startCapture()
            isCapturing = true
        } catch {
            self.warning = "System audio capture failed: \(error.localizedDescription). Recording mic only."
            cleanupFile()
        }
    }

    /// Stop system audio capture and finalize the WAV file.
    func stopCapture() async {
        guard isCapturing, let scStream = stream else {
            isCapturing = false
            return
        }

        do {
            try await scStream.stopCapture()
        } catch {
            // Best-effort stop; file is still valid up to the last written buffer
        }

        stream = nil
        isCapturing = false
        // Drain pending writes before closing file
        writeQueue.sync {
            fileLock.lock()
            _audioFile = nil
            fileLock.unlock()
        }
    }

    // MARK: - File Path Helper

    static func systemPath(for meetingID: UUID) -> String {
        AudioEngine.recordingsDirectory
            .appendingPathComponent("meeting_\(meetingID.uuidString)_system.wav")
            .path
    }

    // MARK: - Private Helpers

    private func ensureRecordingsDirectory() throws {
        let dir = AudioEngine.recordingsDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
    }

    /// Thread-safe setter for the audio file. Avoids calling NSLock directly in async contexts.
    private nonisolated func setAudioFile(_ file: AVAudioFile?) {
        fileLock.lock()
        _audioFile = file
        fileLock.unlock()
    }

    private func cleanupFile() {
        setAudioFile(nil)
        stream = nil
    }
}

// MARK: - SCStreamOutput

extension SystemAudioRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = Self.convertToPCMBuffer(sampleBuffer) else { return }

        // Write on dedicated queue (never on the callback thread)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            try? self._audioFile?.write(from: pcmBuffer)
        }
    }

    /// Convert a CMSampleBuffer (from ScreenCaptureKit audio) into an AVAudioPCMBuffer.
    private nonisolated static func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription else { return nil }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else {
            return nil
        }

        pcmBuffer.frameLength = frameCount

        // Copy audio data from the sample buffer into the PCM buffer
        guard let blockBuffer = sampleBuffer.dataBuffer else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let srcData = dataPointer else { return nil }

        // Copy into each audio buffer in the PCM buffer's buffer list
        let audioBufferListPtr = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        var offset = 0
        for buffer in audioBufferListPtr {
            guard let dest = buffer.mData else { continue }
            let bytesToCopy = min(Int(buffer.mDataByteSize), totalLength - offset)
            if bytesToCopy > 0 {
                memcpy(dest, srcData.advanced(by: offset), bytesToCopy)
                offset += bytesToCopy
            }
        }

        return pcmBuffer
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.isCapturing = false
            self?.warning = "System audio stream stopped: \(error.localizedDescription)"
        }
    }
}
