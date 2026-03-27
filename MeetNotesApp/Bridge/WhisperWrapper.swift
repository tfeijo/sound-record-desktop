import Foundation

// MARK: - Whisper Model Size

/// Supported whisper.cpp GGML model sizes.
enum WhisperModelSize: String, CaseIterable, Identifiable, Codable {
    case tiny
    case base
    case small

    var id: String { rawValue }

    /// Human-readable label with approximate download size.
    var displayName: String {
        switch self {
        case .tiny:  return "Tiny (~75 MB)"
        case .base:  return "Base (~142 MB)"
        case .small: return "Small (~466 MB)"
        }
    }

    /// Remote URL for the GGML model file on Hugging Face.
    var remoteURL: URL {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
        return URL(string: "\(base)/ggml-\(rawValue).bin")!
    }

    /// Local filename stored under ~/Library/Application Support/MeetNotes/models/.
    var fileName: String {
        "ggml-\(rawValue).bin"
    }
}

// MARK: - WhisperWrapper

/// Swift-friendly wrapper around the whisper C bridge.
///
/// This layer translates between the C `wb_*` API and Swift value types.
/// When whisper.cpp is not linked (stub bridge returning NULL), every call
/// gracefully returns an empty result so the app can fall back to the live
/// transcript.
///
/// ## Integration path
/// 1. Vendor whisper.cpp sources into the Xcode project.
/// 2. Replace `whisper-bridge.c` stub with real `whisper.h` calls.
/// 3. This wrapper needs **no changes** — its public API stays the same.
final class WhisperWrapper: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance. Thread-safe thanks to `@unchecked Sendable` + NSLock.
    static let shared = WhisperWrapper()

    // MARK: - State

    private let lock = NSLock()
    /// `true` when the C bridge is functional (wb_init returned non-NULL).
    private(set) var isAvailable: Bool = false

    // MARK: - Model directory

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("MeetNotes", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Returns the local path for a given model size, or nil if not yet downloaded.
    static func localModelPath(for size: WhisperModelSize) -> URL? {
        let url = modelsDirectory.appendingPathComponent(size.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Init / Teardown

    private init() {
        // TODO: When whisper.cpp is linked, call wb_init here with a default model.
        isAvailable = false
    }

    // MARK: - Transcription (public API)

    /// Transcribe an audio file using whisper.cpp.
    ///
    /// - Parameters:
    ///   - audioPath: Path to a 16-kHz mono WAV file.
    ///   - modelSize: Which GGML model to use.
    ///   - progressHandler: Called on a background thread with 0.0–1.0 progress.
    /// - Returns: An array of transcript segments, or an empty array when the C bridge
    ///   is unavailable (stub mode).
    ///
    /// This method is **synchronous** and expected to be called from a background
    /// thread / Swift concurrency task. The caller (``WhisperTranscriber``) wraps
    /// it in `Task.detached`.
    func transcribe(
        audioPath: String,
        modelSize: WhisperModelSize,
        progressHandler: ((Float) -> Void)? = nil
    ) -> [TranscriptSegment] {
        // TODO: Replace this stub with real whisper.cpp C bridge calls.
        //
        // Real implementation outline:
        // 1. let modelPath = Self.localModelPath(for: modelSize)?.path
        // 2. let ctx = wb_init(modelPath)
        // 3. let count = wb_transcribe(ctx, audioPath, progressCallback, userData)
        // 4. for i in 0..<count { let seg = wb_get_segment(ctx, i); … }
        // 5. wb_free(ctx)

        // Simulate progress for UI testing
        let steps = 20
        for step in 0...steps {
            progressHandler?(Float(step) / Float(steps))
            Thread.sleep(forTimeInterval: 0.05) // 1 s total simulated time
        }

        // Return empty — the caller will keep the live transcript as fallback.
        return []
    }
}
