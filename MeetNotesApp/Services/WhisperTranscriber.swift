import Foundation
import Observation

/// High-accuracy offline transcription using whisper.cpp.
///
/// After recording stops, ``WorkspaceView`` calls ``transcribe(audioPath:modelSize:)``
/// which:
/// 1. Ensures the requested GGML model is downloaded (via ``ModelDownloadManager``).
/// 2. Runs whisper.cpp on a background thread through ``WhisperWrapper``.
/// 3. Reports processing progress to the UI.
/// 4. Returns an array of ``TranscriptSegment`` that replaces the live SFSpeech transcript.
///
/// When the C bridge is in stub mode (whisper.cpp not linked), the service returns
/// an empty array and the caller keeps the live transcript as-is.
@MainActor @Observable
final class WhisperTranscriber {

    // MARK: - Observable state

    /// Processing progress (0.0–1.0). Combines model download + transcription.
    private(set) var progress: Float = 0
    /// `true` while transcription (or model download) is running.
    private(set) var isProcessing = false
    /// `true` when the C bridge is actually functional (whisper.cpp linked).
    var isBridgeAvailable: Bool { WhisperWrapper.shared.isAvailable }
    /// Human-readable error, or nil.
    var error: String?

    /// The selected model size. Persisted in UserDefaults for convenience.
    var selectedModelSize: WhisperModelSize {
        get {
            let raw = UserDefaults.standard.string(forKey: "whisperModelSize") ?? "base"
            return WhisperModelSize(rawValue: raw) ?? .base
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "whisperModelSize")
        }
    }

    // MARK: - Dependencies

    let downloadManager = ModelDownloadManager()

    // MARK: - Public API

    /// Run whisper.cpp transcription on a recorded audio file.
    ///
    /// - Parameters:
    ///   - audioPath: Absolute path to the 16-kHz mono WAV file produced by ``AudioEngine``.
    ///   - modelSize: The GGML model variant to use (default: user's selected size).
    /// - Returns: Transcript segments from whisper.cpp, or an empty array if the bridge
    ///   is unavailable / an error occurred.
    ///
    /// The method updates ``progress`` and ``isProcessing`` on the main actor so the
    /// UI can display a progress indicator.
    func transcribe(
        audioPath: String,
        modelSize: WhisperModelSize? = nil
    ) async -> [TranscriptSegment] {
        let model = modelSize ?? selectedModelSize
        error = nil
        progress = 0
        isProcessing = true

        defer {
            isProcessing = false
        }

        // Phase 1: Ensure model is downloaded (0%–50% of progress)
        progress = 0.01
        guard await downloadManager.ensureModel(model) != nil else {
            if let dlError = downloadManager.error {
                error = dlError
            } else {
                error = "Model download was cancelled."
            }
            return []
        }
        progress = 0.5

        // Phase 2: Run whisper.cpp transcription (50%–100%)
        let path = audioPath
        let segments: [TranscriptSegment] = await Task.detached(priority: .userInitiated) {
            WhisperWrapper.shared.transcribe(
                audioPath: path,
                modelSize: model
            ) { [weak self] whisperProgress in
                // Map 0..1 whisper progress to 0.5..1.0 overall progress
                let overall = 0.5 + whisperProgress * 0.5
                Task { @MainActor [weak self] in
                    self?.progress = overall
                }
            }
        }.value

        progress = 1.0
        return segments
    }

    /// Cancel any in-progress model download (transcription itself is not cancellable
    /// in the current stub, but will be once the real C bridge supports it).
    func cancel() {
        downloadManager.cancelDownload()
        isProcessing = false
        progress = 0
    }
}
