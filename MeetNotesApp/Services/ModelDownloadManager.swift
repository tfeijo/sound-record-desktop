import Foundation
import Observation

/// Downloads whisper GGML model files on first use and reports progress.
///
/// Models are stored at `~/Library/Application Support/MeetNotes/models/`.
/// The manager checks whether a model is already present before downloading.
@MainActor @Observable
final class ModelDownloadManager {

    // MARK: - Observable state

    /// Overall download progress (0.0–1.0). Reset when a new download starts.
    private(set) var downloadProgress: Float = 0
    /// `true` while a download is actively in progress.
    private(set) var isDownloading = false
    /// Human-readable error string, or nil.
    var error: String?

    // MARK: - Private

    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?

    // MARK: - Public API

    /// Returns `true` when the model file already exists on disk.
    func isModelAvailable(_ size: WhisperModelSize) -> Bool {
        WhisperWrapper.localModelPath(for: size) != nil
    }

    /// Ensure the model is available locally. Downloads it if necessary.
    ///
    /// - Parameter size: The model variant to ensure.
    /// - Returns: The local file URL on success, or nil on failure.
    func ensureModel(_ size: WhisperModelSize) async -> URL? {
        // Already present?
        if let existing = WhisperWrapper.localModelPath(for: size) {
            return existing
        }

        return await downloadModel(size)
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    // MARK: - Download

    private func downloadModel(_ size: WhisperModelSize) async -> URL? {
        error = nil
        isDownloading = true
        downloadProgress = 0

        let destination = WhisperWrapper.modelsDirectory
            .appendingPathComponent(size.fileName)

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(
                at: WhisperWrapper.modelsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            self.error = "Failed to create models directory: \(error.localizedDescription)"
            isDownloading = false
            return nil
        }

        // Use URLSession delegate for progress tracking
        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress
            }
        }

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        do {
            let (tempURL, response) = try await session.download(from: size.remoteURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                self.error = "Download failed with status \(code)"
                isDownloading = false
                return nil
            }

            // Move to final location (overwrite if partial exists)
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tempURL, to: destination)

            isDownloading = false
            downloadProgress = 1.0
            return destination

        } catch is CancellationError {
            isDownloading = false
            return nil
        } catch {
            self.error = "Download error: \(error.localizedDescription)"
            isDownloading = false
            return nil
        }
    }
}

// MARK: - URLSession Download Delegate (progress tracking)

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressHandler: (Float) -> Void

    init(progressHandler: @escaping (Float) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async download(from:) call.
    }
}
