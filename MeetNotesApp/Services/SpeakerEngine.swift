import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - Speaker Embedding

/// A 192-dimensional speaker voice embedding vector.
struct SpeakerEmbedding: Sendable {
    let vector: [Float]  // 192-dim ECAPA-TDNN output

    static let dimensions = 192

    /// Cosine similarity between two embedding vectors. Returns value in [-1, 1].
    /// Uses Accelerate framework for vectorized computation.
    func cosineSimilarity(to other: SpeakerEmbedding) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(vector, 1, other.vector, 1, &dotProduct, vDSP_Length(vector.count))
        vDSP_svesq(vector, 1, &normA, vDSP_Length(vector.count))
        vDSP_svesq(other.vector, 1, &normB, vDSP_Length(other.vector.count))

        let denominator = sqrtf(normA) * sqrtf(normB)
        guard denominator > 0 else { return 0 }
        return dotProduct / denominator
    }
}

// MARK: - Diarization Result

/// Result of speaker diarization containing updated segments and speaker count.
struct DiarizationResult: Sendable {
    let segments: [TranscriptSegment]
    let speakerCount: Int
}

// MARK: - Speaker Engine

/// Speaker diarization engine using CoreML ECAPA-TDNN embeddings with energy-based fallback.
///
/// Architecture supports two modes:
/// 1. **CoreML mode**: Loads an ECAPA-TDNN model to extract 192-dim speaker embeddings,
///    then clusters them using agglomerative clustering with cosine similarity.
/// 2. **Energy-based fallback** (default): Reads the WAV audio file, detects silence gaps
///    longer than 500ms, and assigns speaker changes at those boundaries.
///
/// The energy-based fallback is the working default since the CoreML model is not bundled
/// in SPM builds. Heavy computation runs off the main thread via a detached Task.
@MainActor @Observable
final class SpeakerEngine {
    // MARK: - Published State

    private(set) var isProcessing = false
    var error: String?

    /// Whether a CoreML speaker embedding model is available.
    private(set) var coreMLAvailable = false

    // MARK: - Initialization

    init() {
        // Attempt to load CoreML model (graceful failure expected in SPM builds)
        coreMLAvailable = Self.loadCoreMLModel()
    }

    // MARK: - Public API

    /// Run speaker diarization on transcript segments using the recorded audio.
    ///
    /// If a CoreML ECAPA-TDNN model is available, extracts speaker embeddings and clusters them.
    /// Otherwise, falls back to energy-based silence detection for speaker turn boundaries.
    /// Heavy computation runs on a background thread.
    func diarize(segments: [TranscriptSegment], audioPath: String) async -> DiarizationResult {
        guard !segments.isEmpty else {
            return DiarizationResult(segments: segments, speakerCount: 0)
        }

        isProcessing = true
        error = nil

        let useCoreML = coreMLAvailable

        // Run heavy computation off the main thread
        let result = await Task.detached {
            let worker = DiarizationWorker()
            if useCoreML {
                return worker.diarizeWithCoreML(segments: segments, audioPath: audioPath)
            } else {
                return worker.diarizeWithEnergyFallback(segments: segments, audioPath: audioPath)
            }
        }.value

        isProcessing = false
        return result
    }

    /// Match diarized speaker labels against enrolled speaker profiles.
    /// Replaces generic "Speaker N" labels with enrolled names when a profile's
    /// embedding matches (cosine similarity > 0.8). Architecture-ready — requires
    /// real embeddings from CoreML model to produce actual matches.
    static func matchSpeakers(
        result: DiarizationResult,
        profiles: [SpeakerProfile]
    ) -> DiarizationResult {
        guard !profiles.isEmpty else { return result }

        // Build a map of unique speaker labels to check
        let uniqueSpeakers = Set(result.segments.map(\.speaker))
        var labelToName: [String: String] = [:]

        // For each unique speaker label, try to match against enrolled profiles
        // This requires real embeddings — with stub embeddings, no matches will occur
        for _ in uniqueSpeakers {
            // Find segments for this speaker to get their embedding (if available)
            // Currently architecture-ready: when CoreML produces real embeddings,
            // they would be stored and compared here
            for profile in profiles {
                guard let embeddingData = profile.embeddingData else { continue }

                // Decode stored embedding
                let floatCount = embeddingData.count / MemoryLayout<Float>.stride
                guard floatCount == SpeakerEmbedding.dimensions else { continue }

                let storedVector: [Float] = embeddingData.withUnsafeBytes { buffer in
                    Array(buffer.bindMemory(to: Float.self))
                }
                let storedEmbedding = SpeakerEmbedding(vector: storedVector)

                // Compare — placeholder: when we have segment embeddings, compute similarity
                // For now, this path won't match since we don't store segment embeddings yet
                _ = storedEmbedding  // Architecture placeholder
            }
        }

        // Apply name replacements
        guard !labelToName.isEmpty else { return result }

        let updatedSegments = result.segments.map { segment in
            var s = segment
            if let name = labelToName[s.speaker] {
                s.speaker = name
            }
            return s
        }

        return DiarizationResult(
            segments: updatedSegments,
            speakerCount: result.speakerCount
        )
    }

    // MARK: - CoreML Model Loading

    /// Attempt to load the CoreML ECAPA-TDNN model.
    /// Returns false when model file is not bundled (expected in SPM builds).
    private static func loadCoreMLModel() -> Bool {
        // CoreML ECAPA-TDNN model would be loaded here.
        // The model file (ECAPA_TDNN.mlmodelc) is not included in SPM builds.
        // When available, it would be loaded with:
        //
        //   let config = MLModelConfiguration()
        //   config.computeUnits = .all  // CPU + GPU + Neural Engine
        //   let model = try ECAPA_TDNN(configuration: config)
        //
        // For now, gracefully return false to use energy-based fallback.
        return false
    }
}

// MARK: - Diarization Worker (Off Main Thread)

/// Pure computation worker for speaker diarization. Runs on background threads.
/// Separated from SpeakerEngine (@MainActor) to avoid blocking the UI.
private struct DiarizationWorker: Sendable {
    /// Cosine similarity threshold for agglomerative clustering.
    let clusteringThreshold: Float = 0.7

    /// Minimum silence gap (in seconds) to trigger a speaker change.
    let silenceGapThreshold: Double = 0.5

    /// RMS energy threshold below which audio is considered silence.
    let silenceEnergyThreshold: Float = 0.01

    /// Expected sample rate for the input WAV file (matches AudioEngine output).
    let expectedSampleRate: Double = 16_000

    // MARK: - CoreML Path (Architecture Ready)

    /// CoreML-based diarization: extract embeddings per segment, then cluster.
    func diarizeWithCoreML(
        segments: [TranscriptSegment],
        audioPath: String
    ) -> DiarizationResult {
        // Load audio samples; degrade gracefully if loading fails
        guard let audioSamples = loadAudioSamples(from: audioPath) else {
            return fallbackSingleSpeaker(segments: segments)
        }

        // Extract embeddings for each segment
        var embeddings: [SpeakerEmbedding] = []
        for segment in segments {
            let startSample = Int(segment.start * expectedSampleRate)
            let endSample = min(Int(segment.end * expectedSampleRate), audioSamples.count)

            guard startSample < endSample, startSample < audioSamples.count else {
                embeddings.append(SpeakerEmbedding(vector: [Float](repeating: 0, count: SpeakerEmbedding.dimensions)))
                continue
            }

            let segmentSamples = Array(audioSamples[startSample..<endSample])
            if let embedding = extractEmbedding(audioSamples: segmentSamples) {
                embeddings.append(embedding)
            } else {
                embeddings.append(SpeakerEmbedding(vector: [Float](repeating: 0, count: SpeakerEmbedding.dimensions)))
            }
        }

        let clusterLabels = agglomerativeClustering(embeddings: embeddings)
        return assignSpeakerLabels(segments: segments, clusterLabels: clusterLabels)
    }

    /// Extract a 192-dim speaker embedding from audio samples using CoreML.
    /// Stub — returns nil until model is available.
    private func extractEmbedding(audioSamples _: [Float]) -> SpeakerEmbedding? {
        // When CoreML model is available:
        // 1. Convert audio samples to MLMultiArray
        // 2. Run inference with MLComputeUnits.all
        // 3. Extract 192-dim output vector
        // 4. Return SpeakerEmbedding(vector: outputVector)
        return nil
    }

    // MARK: - Agglomerative Clustering

    /// Agglomerative (bottom-up) hierarchical clustering using cosine similarity.
    ///
    /// Each embedding starts in its own cluster. At each step, the two most similar
    /// clusters are merged if their similarity exceeds `clusteringThreshold`.
    /// Uses average-linkage to compute inter-cluster similarity.
    private func agglomerativeClustering(embeddings: [SpeakerEmbedding]) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        if n == 1 { return [0] }

        var clusterAssignment = Array(0..<n)
        var nextClusterID = n

        // Precompute pairwise similarity matrix
        var similarityMatrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let sim = embeddings[i].cosineSimilarity(to: embeddings[j])
                similarityMatrix[i][j] = sim
                similarityMatrix[j][i] = sim
            }
        }

        var activeClusters = Set(0..<n)
        var clusterMembers: [Int: [Int]] = [:]
        for i in 0..<n {
            clusterMembers[i] = [i]
        }

        while activeClusters.count > 1 {
            var bestSim: Float = -1
            var bestPair: (Int, Int) = (-1, -1)

            let activeList = Array(activeClusters).sorted()
            for i in 0..<activeList.count {
                for j in (i + 1)..<activeList.count {
                    let clusterA = activeList[i]
                    let clusterB = activeList[j]

                    let membersA = clusterMembers[clusterA]!
                    let membersB = clusterMembers[clusterB]!
                    var totalSim: Float = 0
                    for a in membersA {
                        for b in membersB {
                            totalSim += similarityMatrix[a][b]
                        }
                    }
                    let avgSim = totalSim / Float(membersA.count * membersB.count)

                    if avgSim > bestSim {
                        bestSim = avgSim
                        bestPair = (clusterA, clusterB)
                    }
                }
            }

            if bestSim < clusteringThreshold { break }

            let (clusterA, clusterB) = bestPair
            let mergedMembers = clusterMembers[clusterA]! + clusterMembers[clusterB]!
            clusterMembers[nextClusterID] = mergedMembers

            for idx in mergedMembers {
                clusterAssignment[idx] = nextClusterID
            }

            activeClusters.remove(clusterA)
            activeClusters.remove(clusterB)
            activeClusters.insert(nextClusterID)
            clusterMembers.removeValue(forKey: clusterA)
            clusterMembers.removeValue(forKey: clusterB)

            nextClusterID += 1
        }

        // Remap to sequential 0-based labels
        var clusterMap: [Int: Int] = [:]
        var nextLabel = 0
        var result = [Int]()

        for assignment in clusterAssignment {
            if let label = clusterMap[assignment] {
                result.append(label)
            } else {
                clusterMap[assignment] = nextLabel
                result.append(nextLabel)
                nextLabel += 1
            }
        }

        return result
    }

    // MARK: - Energy-Based Fallback

    /// Energy-based speaker turn detection using silence gaps.
    ///
    /// Reads the WAV audio file, computes RMS energy in short windows, and identifies
    /// silence gaps longer than 500ms. Speaker changes are assumed at those gaps.
    /// This is the working default when CoreML embeddings are unavailable.
    ///
    /// **Known limitation:** Speaker cycling is round-robin (1→2→3→1...) since energy
    /// alone cannot re-identify a previous speaker. This means the same physical speaker
    /// may get different labels if they speak non-consecutively.
    func diarizeWithEnergyFallback(
        segments: [TranscriptSegment],
        audioPath: String
    ) -> DiarizationResult {
        guard let audioSamples = loadAudioSamples(from: audioPath) else {
            return fallbackSingleSpeaker(segments: segments)
        }

        let silenceGaps = detectSilenceGaps(in: audioSamples, sampleRate: expectedSampleRate)

        var currentSpeaker = 1
        var updatedSegments = [TranscriptSegment]()

        for (index, segment) in segments.enumerated() {
            var updated = segment

            if index == 0 {
                updated.speaker = "Speaker 1"
            } else {
                let gapStart = segments[index - 1].end
                let gapEnd = segment.start

                // Check if any silence gap overlaps with the inter-segment gap
                let hasSilenceGap = silenceGaps.contains { gap in
                    gap.start < gapEnd + 0.1 && gap.end > gapStart - 0.1
                }

                if hasSilenceGap {
                    currentSpeaker = (currentSpeaker % maxSpeakers(for: segments.count)) + 1
                }

                updated.speaker = "Speaker \(currentSpeaker)"
            }

            updatedSegments.append(updated)
        }

        let uniqueSpeakers = Set(updatedSegments.map(\.speaker)).count
        return DiarizationResult(segments: updatedSegments, speakerCount: uniqueSpeakers)
    }

    /// Determine a reasonable max speaker count based on segment count.
    private func maxSpeakers(for segmentCount: Int) -> Int {
        if segmentCount <= 4 { return 2 }
        if segmentCount <= 10 { return 3 }
        return 4
    }

    // MARK: - Silence Detection

    private struct SilenceGap {
        let start: Double   // seconds
        let end: Double     // seconds
    }

    /// Detect silence gaps in audio samples using windowed RMS energy.
    private func detectSilenceGaps(in samples: [Float], sampleRate: Double) -> [SilenceGap] {
        let windowSize = Int(sampleRate * 0.025)    // 25ms windows
        let hopSize = Int(sampleRate * 0.010)       // 10ms hop
        let totalSamples = samples.count

        guard totalSamples > windowSize else { return [] }

        var isSilence = [Bool]()
        var windowTimes = [Double]()
        var offset = 0

        while offset + windowSize <= totalSamples {
            var sumSquares: Float = 0
            for i in offset..<(offset + windowSize) {
                sumSquares += samples[i] * samples[i]
            }
            let rms = sqrtf(sumSquares / Float(windowSize))
            let time = Double(offset) / sampleRate

            isSilence.append(rms < silenceEnergyThreshold)
            windowTimes.append(time)
            offset += hopSize
        }

        var gaps = [SilenceGap]()
        var silenceStart: Double?

        for (index, silent) in isSilence.enumerated() {
            if silent {
                if silenceStart == nil {
                    silenceStart = windowTimes[index]
                }
            } else {
                if let start = silenceStart {
                    let end = windowTimes[index]
                    if end - start >= silenceGapThreshold {
                        gaps.append(SilenceGap(start: start, end: end))
                    }
                    silenceStart = nil
                }
            }
        }

        if let start = silenceStart, let lastTime = windowTimes.last {
            let end = lastTime + Double(windowSize) / sampleRate
            if end - start >= silenceGapThreshold {
                gaps.append(SilenceGap(start: start, end: end))
            }
        }

        return gaps
    }

    // MARK: - Audio Loading

    /// Load audio samples from a WAV file as Float32 mono at 16kHz.
    /// Resamples automatically if the file has a different sample rate.
    private func loadAudioSamples(from path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: expectedSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                return nil
            }

            let ratio = expectedSampleRate / audioFile.processingFormat.sampleRate
            let frameCount = AVAudioFrameCount(Double(audioFile.length) * ratio)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return nil
            }

            if audioFile.processingFormat.sampleRate != expectedSampleRate {
                guard let converter = AVAudioConverter(
                    from: audioFile.processingFormat,
                    to: targetFormat
                ) else { return nil }

                let sourceFrameCount = AVAudioFrameCount(audioFile.length)
                guard let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: sourceFrameCount
                ) else { return nil }
                try audioFile.read(into: sourceBuffer)

                var hasProvidedData = false
                var conversionError: NSError?
                converter.convert(to: buffer, error: &conversionError) { _, outStatus in
                    if hasProvidedData {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    hasProvidedData = true
                    outStatus.pointee = .haveData
                    return sourceBuffer
                }
                guard conversionError == nil else { return nil }
            } else {
                try audioFile.read(into: buffer)
            }

            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(buffer.frameLength)
            ))
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Assign "Speaker N" labels to segments based on cluster labels.
    private func assignSpeakerLabels(
        segments: [TranscriptSegment],
        clusterLabels: [Int]
    ) -> DiarizationResult {
        guard segments.count == clusterLabels.count else {
            return DiarizationResult(segments: segments, speakerCount: 0)
        }

        var updatedSegments = [TranscriptSegment]()
        for (index, segment) in segments.enumerated() {
            var updated = segment
            updated.speaker = "Speaker \(clusterLabels[index] + 1)"
            updatedSegments.append(updated)
        }

        let uniqueSpeakers = Set(clusterLabels).count
        return DiarizationResult(segments: updatedSegments, speakerCount: uniqueSpeakers)
    }

    /// Fallback: assign all segments to Speaker 1 when audio loading fails.
    private func fallbackSingleSpeaker(segments: [TranscriptSegment]) -> DiarizationResult {
        let updated = segments.map { segment in
            var s = segment
            s.speaker = "Speaker 1"
            return s
        }
        return DiarizationResult(segments: updated, speakerCount: 1)
    }
}
