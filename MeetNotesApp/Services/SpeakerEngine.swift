@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - Speaker Embedding

/// A 192-dimensional speaker voice embedding vector.
struct SpeakerEmbedding {
    let vector: [Float]  // 192-dim ECAPA-TDNN output

    static let dimensions = 192

    /// Cosine similarity between two embedding vectors. Returns value in [-1, 1].
    func cosineSimilarity(to other: SpeakerEmbedding) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<vector.count {
            dotProduct += vector[i] * other.vector[i]
            normA += vector[i] * vector[i]
            normB += other.vector[i] * other.vector[i]
        }

        let denominator = sqrtf(normA) * sqrtf(normB)
        guard denominator > 0 else { return 0 }
        return dotProduct / denominator
    }
}

// MARK: - Diarization Result

/// Result of speaker diarization containing updated segments and speaker count.
struct DiarizationResult {
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
/// in SPM builds.
@MainActor @Observable
final class SpeakerEngine {
    // MARK: - Published State

    private(set) var isProcessing = false
    var error: String?

    /// Whether a CoreML speaker embedding model is available.
    private(set) var coreMLAvailable = false

    // MARK: - Configuration

    /// Cosine similarity threshold for agglomerative clustering.
    /// Embeddings with similarity above this threshold are merged into the same speaker cluster.
    private let clusteringThreshold: Float = 0.7

    /// Minimum silence gap (in seconds) to trigger a speaker change in energy-based fallback.
    private let silenceGapThreshold: Double = 0.5

    /// RMS energy threshold below which audio is considered silence.
    private let silenceEnergyThreshold: Float = 0.01

    /// Sample rate expected for the input WAV file (matches AudioEngine output).
    private let expectedSampleRate: Double = 16_000

    // MARK: - Initialization

    init() {
        // Attempt to load CoreML model (graceful failure expected in SPM builds)
        coreMLAvailable = loadCoreMLModel()
    }

    // MARK: - Public API

    /// Run speaker diarization on transcript segments using the recorded audio.
    ///
    /// If a CoreML ECAPA-TDNN model is available, extracts speaker embeddings and clusters them.
    /// Otherwise, falls back to energy-based silence detection for speaker turn boundaries.
    ///
    /// - Parameters:
    ///   - segments: Transcript segments from whisper.cpp (or live transcription).
    ///   - audioPath: File path to the 16kHz mono WAV recording.
    /// - Returns: A `DiarizationResult` with updated segments containing speaker labels.
    func diarize(segments: [TranscriptSegment], audioPath: String) async -> DiarizationResult {
        guard !segments.isEmpty else {
            return DiarizationResult(segments: segments, speakerCount: 0)
        }

        isProcessing = true
        error = nil
        defer { isProcessing = false }

        if coreMLAvailable {
            return await diarizeWithCoreML(segments: segments, audioPath: audioPath)
        } else {
            return await diarizeWithEnergyFallback(segments: segments, audioPath: audioPath)
        }
    }

    // MARK: - CoreML Path (Architecture Ready)

    /// Attempt to load the CoreML ECAPA-TDNN model.
    /// Returns false when model file is not bundled (expected in SPM builds).
    private func loadCoreMLModel() -> Bool {
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

    /// Extract a 192-dim speaker embedding from an audio segment using CoreML.
    /// Stub implementation — returns nil until model is available.
    private func extractEmbedding(audioSamples _: [Float]) -> SpeakerEmbedding? {
        // When CoreML model is available:
        // 1. Convert audio samples to MLMultiArray
        // 2. Run inference with MLComputeUnits.all
        // 3. Extract 192-dim output vector
        // 4. Return SpeakerEmbedding(vector: outputVector)
        return nil
    }

    /// CoreML-based diarization: extract embeddings per segment, then cluster.
    private func diarizeWithCoreML(
        segments: [TranscriptSegment],
        audioPath: String
    ) async -> DiarizationResult {
        // Load audio samples
        guard let audioSamples = loadAudioSamples(from: audioPath) else {
            error = "Failed to load audio for CoreML diarization"
            return DiarizationResult(segments: segments, speakerCount: 0)
        }

        // Extract embeddings for each segment
        var embeddings: [SpeakerEmbedding] = []
        for segment in segments {
            let startSample = Int(segment.start * expectedSampleRate)
            let endSample = min(Int(segment.end * expectedSampleRate), audioSamples.count)

            guard startSample < endSample, startSample < audioSamples.count else {
                // Use a zero embedding for segments outside audio range
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

        // Cluster embeddings using agglomerative clustering
        let clusterLabels = agglomerativeClustering(embeddings: embeddings)

        // Assign speaker labels
        return assignSpeakerLabels(segments: segments, clusterLabels: clusterLabels)
    }

    // MARK: - Agglomerative Clustering

    /// Agglomerative (bottom-up) hierarchical clustering using cosine similarity.
    ///
    /// Each embedding starts in its own cluster. At each step, the two most similar
    /// clusters are merged if their similarity exceeds `clusteringThreshold`.
    /// Uses average-linkage to compute inter-cluster similarity.
    ///
    /// - Parameter embeddings: Array of speaker embeddings to cluster.
    /// - Returns: Array of cluster labels (0-based) aligned with the input embeddings.
    func agglomerativeClustering(embeddings: [SpeakerEmbedding]) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        if n == 1 { return [0] }

        // Each element starts in its own cluster
        var clusterAssignment = Array(0..<n)
        var nextClusterID = n

        // Precompute pairwise similarity matrix (upper triangle)
        var similarityMatrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let sim = embeddings[i].cosineSimilarity(to: embeddings[j])
                similarityMatrix[i][j] = sim
                similarityMatrix[j][i] = sim
            }
        }

        // Track which cluster IDs are active
        var activeClusters = Set(0..<n)

        // Map from cluster ID to member indices
        var clusterMembers: [Int: [Int]] = [:]
        for i in 0..<n {
            clusterMembers[i] = [i]
        }

        // Iteratively merge the most similar pair of clusters
        while activeClusters.count > 1 {
            var bestSim: Float = -1
            var bestPair: (Int, Int) = (-1, -1)

            let activeList = Array(activeClusters).sorted()
            for i in 0..<activeList.count {
                for j in (i + 1)..<activeList.count {
                    let clusterA = activeList[i]
                    let clusterB = activeList[j]

                    // Average-linkage: mean similarity between all pairs
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

            // Stop merging if best similarity is below threshold
            if bestSim < clusteringThreshold {
                break
            }

            // Merge bestPair into a new cluster
            let (clusterA, clusterB) = bestPair
            let mergedMembers = clusterMembers[clusterA]! + clusterMembers[clusterB]!
            clusterMembers[nextClusterID] = mergedMembers

            // Update assignments
            for idx in mergedMembers {
                clusterAssignment[idx] = nextClusterID
            }

            // Update active clusters
            activeClusters.remove(clusterA)
            activeClusters.remove(clusterB)
            activeClusters.insert(nextClusterID)
            clusterMembers.removeValue(forKey: clusterA)
            clusterMembers.removeValue(forKey: clusterB)

            nextClusterID += 1
        }

        // Remap cluster IDs to sequential 0-based labels
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
    /// silence gaps longer than 500ms. Speaker changes are assumed at these gaps.
    /// This provides a reasonable baseline when CoreML embeddings are unavailable.
    private func diarizeWithEnergyFallback(
        segments: [TranscriptSegment],
        audioPath: String
    ) async -> DiarizationResult {
        // Load audio samples for energy analysis
        guard let audioSamples = loadAudioSamples(from: audioPath) else {
            // If audio loading fails, assign all segments to Speaker 1
            error = "Failed to load audio for energy analysis; assigning single speaker"
            let updated = segments.map { segment in
                var s = segment
                s.speaker = "Speaker 1"
                return s
            }
            return DiarizationResult(segments: updated, speakerCount: 1)
        }

        // Detect silence gaps in the audio
        let silenceGaps = detectSilenceGaps(in: audioSamples, sampleRate: expectedSampleRate)

        // Assign speaker labels based on silence gaps between segments
        var currentSpeaker = 1
        var updatedSegments = [TranscriptSegment]()

        for (index, segment) in segments.enumerated() {
            var updated = segment

            if index == 0 {
                // First segment is always Speaker 1
                updated.speaker = "Speaker 1"
            } else {
                let previousEnd = segments[index - 1].end
                let currentStart = segment.start
                let gapStart = previousEnd
                let gapEnd = currentStart

                // Check if any silence gap falls between the previous and current segment
                let hasSilenceGap = silenceGaps.contains { gap in
                    gap.start >= gapStart - 0.1 && gap.end <= gapEnd + 0.1
                        && gap.duration >= silenceGapThreshold
                }

                if hasSilenceGap {
                    // Speaker change detected at silence gap
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
        // Heuristic: cap at a reasonable number based on meeting size
        if segmentCount <= 4 { return 2 }
        if segmentCount <= 10 { return 3 }
        return 4
    }

    // MARK: - Silence Detection

    /// A detected silence gap in the audio.
    struct SilenceGap {
        let start: Double   // seconds
        let end: Double     // seconds
        var duration: Double { end - start }
    }

    /// Detect silence gaps in audio samples using windowed RMS energy.
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM audio samples.
    ///   - sampleRate: Sample rate of the audio (e.g., 16000).
    /// - Returns: Array of silence gaps sorted by start time.
    private func detectSilenceGaps(in samples: [Float], sampleRate: Double) -> [SilenceGap] {
        let windowSize = Int(sampleRate * 0.025)    // 25ms windows
        let hopSize = Int(sampleRate * 0.010)       // 10ms hop
        let totalSamples = samples.count

        guard totalSamples > windowSize else { return [] }

        // Compute RMS energy per window
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

        // Find contiguous silence regions
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

        // Handle trailing silence
        if let start = silenceStart, let lastTime = windowTimes.last {
            let end = lastTime + Double(windowSize) / sampleRate
            if end - start >= silenceGapThreshold {
                gaps.append(SilenceGap(start: start, end: end))
            }
        }

        return gaps
    }

    // MARK: - Audio Loading

    /// Load audio samples from a WAV file as Float32 mono at the expected sample rate.
    private func loadAudioSamples(from path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audioFile.processingFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                return nil
            }

            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }

            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else { return nil }
            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(buffer.frameLength)
            ))
            return samples
        } catch {
            return nil
        }
    }

    // MARK: - Label Assignment

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
}
