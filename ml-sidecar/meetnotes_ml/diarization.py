"""Speaker diarization using pyannote.audio with incremental chunk support."""

import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Cosine similarity threshold for merging speakers across chunks.
# Values above this indicate the same person. Tuned for typical meeting recordings.
MERGE_SIMILARITY_THRESHOLD = 0.7


@dataclass
class DiarizedSegment:
    speaker: str
    start: float
    end: float


class Diarizer:
    def __init__(self, use_auth_token: str | None = None):
        """Initialize pyannote diarization pipeline.

        Requires HF_TOKEN env var or explicit token for pyannote model access.
        Falls back to no-op if pyannote is not installed.
        """
        self._pipeline = None
        self._embedding_model = None
        self._speaker_embeddings: dict[str, list] = {}  # label -> list of embedding vectors
        self._chunk_counter = 0  # tracks chunks for unique label prefixing

        try:
            from pyannote.audio import Pipeline

            token = use_auth_token
            if not token:
                import os
                token = os.environ.get("HF_TOKEN")

            if not token:
                logger.warning("No HF_TOKEN found — diarization will assign all segments to 'Speaker 1'")
                return

            logger.info("Loading pyannote diarization pipeline...")
            self._pipeline = Pipeline.from_pretrained(
                "pyannote/speaker-diarization-3.1",
                use_auth_token=token,
            )
            logger.info("Diarization pipeline loaded")

            # Try to load embedding model for cross-chunk speaker matching
            try:
                from pyannote.audio import Model, Inference
                self._embedding_model = Inference(
                    Model.from_pretrained("pyannote/embedding", use_auth_token=token),
                    window="whole",
                )
                logger.info("Speaker embedding model loaded")
            except Exception as e:
                logger.warning(f"Embedding model not available, cross-chunk matching disabled: {e}")

        except ImportError:
            logger.warning("pyannote.audio not installed — diarization disabled")

    @property
    def available(self) -> bool:
        return self._pipeline is not None

    def diarize(self, audio_path: str) -> list[DiarizedSegment]:
        """Run speaker diarization on an audio file.

        Returns a list of DiarizedSegment with speaker labels.
        If pyannote is not available, returns an empty list.
        """
        if not self._pipeline:
            logger.info("Diarization not available — returning single-speaker fallback")
            return []

        logger.info(f"Diarizing: {audio_path}")
        diarization = self._pipeline(audio_path)

        segments = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            segments.append(DiarizedSegment(
                speaker=speaker,
                start=turn.start,
                end=turn.end,
            ))

        # Rename speakers to friendly labels (Speaker 1, Speaker 2, ...)
        speaker_map: dict[str, str] = {}
        counter = 1
        for seg in segments:
            if seg.speaker not in speaker_map:
                speaker_map[seg.speaker] = f"Speaker {counter}"
                counter += 1
            seg.speaker = speaker_map[seg.speaker]

        logger.info(f"Diarization complete: {len(segments)} turns, {len(speaker_map)} speakers")
        return segments

    def add_chunk(self, audio_path: str, offset: float = 0.0) -> list[DiarizedSegment]:
        """Diarize a chunk and accumulate speaker embeddings for cross-chunk matching.

        Each chunk's speakers get unique labels (e.g., "c0_Speaker 1", "c1_Speaker 1")
        to avoid false identity between different people who happen to get the same
        pyannote label in different chunks. The finalize() pass merges them by voice similarity.

        Args:
            audio_path: Path to the chunk audio file.
            offset: Absolute time offset to add to segment timestamps.

        Returns diarized segments with timestamps offset to absolute meeting time.
        """
        if not self._pipeline:
            return []

        # Diarize this chunk
        raw_segments = self.diarize(audio_path)

        chunk_idx = self._chunk_counter
        self._chunk_counter += 1

        # Prefix labels with chunk index to ensure uniqueness across chunks
        for seg in raw_segments:
            seg.speaker = f"c{chunk_idx}_{seg.speaker}"
            seg.start += offset
            seg.end += offset

        # Extract embedding for dominant speaker in this chunk
        # NOTE: whole-audio embedding is a blend of all speakers in the chunk.
        # This is a known limitation — minority speakers may not get embeddings.
        # TODO: extract per-speaker embeddings by slicing audio at turn boundaries.
        if self._embedding_model is not None:
            try:
                embedding = self._embedding_model(audio_path)
                if raw_segments:
                    speaker_durations: dict[str, float] = {}
                    for seg in raw_segments:
                        dur = seg.end - seg.start
                        speaker_durations[seg.speaker] = speaker_durations.get(seg.speaker, 0.0) + dur
                    dominant = max(speaker_durations, key=speaker_durations.get)
                    if dominant not in self._speaker_embeddings:
                        self._speaker_embeddings[dominant] = []
                    self._speaker_embeddings[dominant].append(embedding)
            except Exception as e:
                logger.warning(f"Embedding extraction failed for chunk {chunk_idx}: {e}")

        return raw_segments

    def finalize(self, all_segments: list[DiarizedSegment]) -> list[DiarizedSegment]:
        """Final alignment pass to consolidate speaker labels across all chunks.

        Merges speakers with similar voice embeddings (cosine similarity > threshold),
        then assigns clean friendly labels (Speaker 1, Speaker 2, ...).
        """
        if not self._speaker_embeddings or len(self._speaker_embeddings) < 2:
            # No embeddings — just clean up the chunk-prefixed labels
            return self._assign_friendly_labels(all_segments)

        try:
            import numpy as np
            from scipy.spatial.distance import cosine

            # Build mean embedding per speaker
            logger.info(f"Finalize: {len(self._speaker_embeddings)} speakers with embeddings")
            mean_embeddings: dict[str, np.ndarray] = {}
            for label, embs in self._speaker_embeddings.items():
                mean_embeddings[label] = np.mean([e.data for e in embs], axis=0)

            # Find speaker pairs that are likely the same person
            labels = list(mean_embeddings.keys())
            merge_map: dict[str, str] = {}
            for i in range(len(labels)):
                for j in range(i + 1, len(labels)):
                    sim = 1 - cosine(mean_embeddings[labels[i]], mean_embeddings[labels[j]])
                    if sim > MERGE_SIMILARITY_THRESHOLD:
                        merge_map[labels[j]] = labels[i]
                        logger.info(f"Merging speaker '{labels[j]}' into '{labels[i]}' (similarity={sim:.2f})")

            # Resolve transitive merge chains (A->B, B->C becomes A->C, B->C)
            for key in list(merge_map.keys()):
                target = merge_map[key]
                while target in merge_map:
                    target = merge_map[target]
                merge_map[key] = target

            # Apply merges
            if merge_map:
                for seg in all_segments:
                    if seg.speaker in merge_map:
                        seg.speaker = merge_map[seg.speaker]

        except ImportError:
            logger.warning("numpy/scipy not available, skipping cross-chunk speaker merging")
        except Exception as e:
            logger.warning(f"Speaker merging failed: {e}")

        return self._assign_friendly_labels(all_segments)

    @staticmethod
    def _assign_friendly_labels(segments: list[DiarizedSegment]) -> list[DiarizedSegment]:
        """Replace chunk-prefixed labels with clean friendly labels (Speaker 1, Speaker 2, ...)."""
        label_map: dict[str, str] = {}
        counter = 1
        for seg in segments:
            if seg.speaker not in label_map:
                label_map[seg.speaker] = f"Speaker {counter}"
                counter += 1
            seg.speaker = label_map[seg.speaker]
        return segments
