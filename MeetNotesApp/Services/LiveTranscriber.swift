@preconcurrency import AVFoundation
import Observation
import Speech

@MainActor @Observable
final class LiveTranscriber {
    // MARK: - Published State

    private(set) var liveSegments: [TranscriptSegment] = []
    private(set) var isTranscribing = false
    private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var error: String?

    // MARK: - Private

    @ObservationIgnored private nonisolated(unsafe) var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private nonisolated(unsafe) var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private nonisolated(unsafe) var currentTask: SFSpeechRecognitionTask?
    @ObservationIgnored private nonisolated(unsafe) var nextRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private nonisolated(unsafe) var nextTask: SFSpeechRecognitionTask?

    @ObservationIgnored private nonisolated(unsafe) var chunkStartTime: TimeInterval = 0
    @ObservationIgnored private nonisolated(unsafe) var nextChunkStartTime: TimeInterval = 0
    @ObservationIgnored private nonisolated(unsafe) var recordingStartDate: Date?
    @ObservationIgnored private nonisolated(unsafe) var chunkTimer: DispatchSourceTimer?
    @ObservationIgnored private nonisolated(unsafe) var overlapTimer: DispatchSourceTimer?

    /// Accumulated final segments from completed chunks.
    @ObservationIgnored private nonisolated(unsafe) var finalizedSegments: [TranscriptSegment] = []
    /// Last words from the previous chunk, used for deduplication.
    @ObservationIgnored private nonisolated(unsafe) var previousChunkLastWords: [String] = []
    /// Current chunk index (0-based).
    @ObservationIgnored private nonisolated(unsafe) var chunkIndex: Int = 0

    /// Partial text from the current active recognition, shown live.
    @ObservationIgnored private nonisolated(unsafe) var currentPartialText: String = ""
    @ObservationIgnored private nonisolated(unsafe) var currentChunkFinalText: String = ""

    /// Audio format from the hardware, set once on first buffer.
    @ObservationIgnored private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    private let chunkDuration: TimeInterval = 55.0
    private let overlapDuration: TimeInterval = 5.0
    private let transcriptionQueue = DispatchQueue(label: "com.meetnotes.livetranscriber")

    // MARK: - Public API

    /// Request speech recognition authorization. Call before starting transcription.
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = status
                if status != .authorized {
                    self?.error = "Speech recognition not authorized. Enable in System Settings > Privacy & Security > Speech Recognition."
                }
            }
        }
    }

    /// Start live transcription. Call after AudioEngine has started.
    func start() {
        guard !isTranscribing else { return }
        error = nil
        liveSegments = []
        finalizedSegments = []
        previousChunkLastWords = []
        currentPartialText = ""
        currentChunkFinalText = ""
        chunkIndex = 0

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer is not available on this device."
            return
        }

        if !speechRecognizer.supportsOnDeviceRecognition {
            error = "On-device speech recognition is not supported. An internet connection may be required."
            // Continue anyway -- will fall back to server-based
        }

        recordingStartDate = Date()
        chunkStartTime = 0
        isTranscribing = true

        startNewChunk(isOverlap: false)
        scheduleChunkRotation()
    }

    /// Stop live transcription.
    func stop() {
        guard isTranscribing else { return }
        isTranscribing = false

        chunkTimer?.cancel()
        chunkTimer = nil
        overlapTimer?.cancel()
        overlapTimer = nil

        currentTask?.finish()
        currentTask = nil
        currentRequest?.endAudio()
        currentRequest = nil

        nextTask?.finish()
        nextTask = nil
        nextRequest?.endAudio()
        nextRequest = nil

        speechRecognizer = nil
        audioFormat = nil
    }

    /// Append an audio buffer from AudioEngine. Called from the audio tap (non-main thread).
    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        // Store format on first buffer
        if audioFormat == nil {
            audioFormat = buffer.format
        }

        currentRequest?.append(buffer)
        nextRequest?.append(buffer)
    }

    // MARK: - Chunk Management

    private func startNewChunk(isOverlap: Bool) {
        guard let speechRecognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition

        let chunkStart: TimeInterval
        if isOverlap {
            chunkStart = nextChunkStartTime
        } else {
            chunkStart = chunkStartTime
        }

        let task = speechRecognizer.recognitionTask(with: request) {
            [weak self] result, taskError in
            guard let self else { return }
            self.handleRecognitionResult(
                result: result,
                error: taskError,
                chunkStartOffset: chunkStart,
                isOverlapChunk: isOverlap
            )
        }

        if isOverlap {
            nextRequest = request
            nextTask = task
        } else {
            currentRequest = request
            currentTask = task
        }
    }

    private func scheduleChunkRotation() {
        // At chunkDuration - overlapDuration, start the next chunk (overlap begins)
        let overlapStartDelay = chunkDuration - overlapDuration

        let oTimer = DispatchSource.makeTimerSource(queue: transcriptionQueue)
        oTimer.schedule(deadline: .now() + overlapStartDelay, repeating: chunkDuration)
        oTimer.setEventHandler { [weak self] in
            guard let self, self.isTranscribing else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isTranscribing else { return }
                self.nextChunkStartTime = self.chunkStartTime + overlapStartDelay
                self.startNewChunk(isOverlap: true)
            }
        }
        oTimer.resume()
        overlapTimer = oTimer

        // At chunkDuration, finalize the current chunk and rotate
        let cTimer = DispatchSource.makeTimerSource(queue: transcriptionQueue)
        cTimer.schedule(deadline: .now() + chunkDuration, repeating: chunkDuration)
        cTimer.setEventHandler { [weak self] in
            guard let self, self.isTranscribing else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isTranscribing else { return }
                self.rotateChunk()
            }
        }
        cTimer.resume()
        chunkTimer = cTimer
    }

    private func rotateChunk() {
        // Finalize the current chunk
        let finalText = currentChunkFinalText
        let lastWords = extractLastWords(from: finalText, count: 10)
        previousChunkLastWords = lastWords

        // Create finalized segment from current chunk
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let segment = TranscriptSegment(
                id: UUID(),
                speaker: "Speaker",
                start: chunkStartTime,
                end: chunkStartTime + chunkDuration,
                text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: 0.8
            )
            finalizedSegments.append(segment)
        }

        // End current chunk
        currentTask?.finish()
        currentRequest?.endAudio()

        // Promote next chunk to current
        currentRequest = nextRequest
        currentTask = nextTask
        nextRequest = nil
        nextTask = nil

        chunkStartTime = nextChunkStartTime
        currentChunkFinalText = ""
        currentPartialText = ""
        chunkIndex += 1

        updateLiveSegments()
    }

    // MARK: - Recognition Result Handling

    private nonisolated func handleRecognitionResult(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        chunkStartOffset: TimeInterval,
        isOverlapChunk: Bool
    ) {
        if let error {
            let msg = error.localizedDescription
            // Ignore cancellation errors during normal stop
            if (error as NSError).code != 216 { // kAFAssistantErrorDomain canceled
                Task { @MainActor [weak self] in
                    // Only set error if still transcribing
                    if self?.isTranscribing == true {
                        self?.error = "Recognition error: \(msg)"
                    }
                }
            }
            return
        }

        guard let result else { return }

        let text = result.bestTranscription.formattedString
        let isFinal = result.isFinal

        Task { @MainActor [weak self] in
            guard let self else { return }

            if isOverlapChunk {
                // For overlap chunk, don't update display yet -- it becomes current after rotation
                if isFinal {
                    self.currentChunkFinalText = text
                }
            } else {
                if isFinal {
                    self.currentChunkFinalText = text
                } else {
                    self.currentPartialText = text
                }
                self.updateLiveSegments()
            }
        }
    }

    // MARK: - Merge & Deduplication

    private func updateLiveSegments() {
        var segments = finalizedSegments

        // Add current partial/live text
        let liveText = currentPartialText.isEmpty ? currentChunkFinalText : currentPartialText
        if !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let deduplicatedText = deduplicateOverlap(
                newText: liveText,
                previousLastWords: previousChunkLastWords
            )

            if !deduplicatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let elapsed = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
                let segment = TranscriptSegment(
                    id: UUID(),
                    speaker: "Speaker",
                    start: chunkStartTime,
                    end: elapsed,
                    text: deduplicatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: 0.5 // partial result
                )
                segments.append(segment)
            }
        }

        liveSegments = segments
    }

    /// Remove overlapping words from the start of newText that match the end of previous chunk.
    private func deduplicateOverlap(newText: String, previousLastWords: [String]) -> String {
        guard !previousLastWords.isEmpty else { return newText }

        let newWords = newText.split(separator: " ").map(String.init)
        guard !newWords.isEmpty else { return newText }

        // Try to find the longest matching prefix in newWords that matches a suffix of previousLastWords
        var bestMatchLength = 0

        for matchLen in 1...min(previousLastWords.count, newWords.count) {
            let prevSuffix = Array(previousLastWords.suffix(matchLen))
            let newPrefix = Array(newWords.prefix(matchLen))

            if wordsMatch(prevSuffix, newPrefix) {
                bestMatchLength = matchLen
            }
        }

        if bestMatchLength > 0 {
            let remaining = Array(newWords.dropFirst(bestMatchLength))
            return remaining.joined(separator: " ")
        }

        return newText
    }

    /// Fuzzy word matching -- case-insensitive, ignoring punctuation.
    private func wordsMatch(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        for (wa, wb) in zip(a, b) {
            let cleanA = wa.lowercased().filter { $0.isLetter || $0.isNumber }
            let cleanB = wb.lowercased().filter { $0.isLetter || $0.isNumber }
            if cleanA != cleanB { return false }
        }
        return true
    }

    private func extractLastWords(from text: String, count: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        return Array(words.suffix(count))
    }
}
