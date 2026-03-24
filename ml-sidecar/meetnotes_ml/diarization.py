"""Speaker diarization using pyannote.audio with incremental chunk support."""

import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)


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
        self._raw_label_counter = 0  # tracks how many raw pyannote labels we've seen
        self._label_map: dict[str, str] = {}  # SPEAKER_XX -> Speaker N (consistent across chunks)

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

        Returns a list of DiarizedSegment with consistent speaker labels across calls.
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

        # Map raw pyannote labels to consistent friendly labels
        for seg in segments:
            seg.speaker = self._map_speaker(seg.speaker)

        unique = set(seg.speaker for seg in segments)
        logger.info(f"Diarization complete: {len(segments)} turns, {len(unique)} speakers")
        return segments

    def add_chunk(self, audio_path: str, offset: float = 0.0) -> list[DiarizedSegment]:
        """Diarize a chunk and accumulate speaker embeddings for cross-chunk matching.

        Args:
            audio_path: Path to the chunk audio file.
            offset: Absolute time offset to add to segment timestamps.

        Returns diarized segments with timestamps offset to absolute meeting time.
        """
        segments = self.diarize(audio_path)

        # Apply offset
        for seg in segments:
            seg.start += offset
            seg.end += offset

        # Extract embeddings for speaker matching (if available)
        if self._embedding_model is not None:
            try:
                embedding = self._embedding_model(audio_path)
                # Associate embedding with the dominant speaker in this chunk
                if segments:
                    speaker_durations: dict[str, float] = {}
                    for seg in segments:
                        dur = seg.end - seg.start
                        speaker_durations[seg.speaker] = speaker_durations.get(seg.speaker, 0.0) + dur
                    dominant = max(speaker_durations, key=speaker_durations.get)
                    if dominant not in self._speaker_embeddings:
                        self._speaker_embeddings[dominant] = []
                    self._speaker_embeddings[dominant].append(embedding)
            except Exception as e:
                logger.warning(f"Embedding extraction failed for chunk: {e}")

        return segments

    def finalize(self, all_segments: list[DiarizedSegment]) -> list[DiarizedSegment]:
        """Final alignment pass to consolidate speaker labels across all chunks.

        If embeddings are available, merges speakers that have similar voice profiles.
        Otherwise, returns segments as-is (labels are already consistent via _map_speaker).
        """
        if not self._speaker_embeddings or len(self._speaker_embeddings) < 2:
            return all_segments

        try:
            import numpy as np
            from scipy.spatial.distance import cosine

            # Build mean embedding per speaker
            mean_embeddings: dict[str, any] = {}
            for label, embs in self._speaker_embeddings.items():
                mean_embeddings[label] = np.mean([e.data for e in embs], axis=0)

            # Find speaker pairs that are likely the same person (cosine similarity > 0.7)
            labels = list(mean_embeddings.keys())
            merge_map: dict[str, str] = {}
            for i in range(len(labels)):
                for j in range(i + 1, len(labels)):
                    sim = 1 - cosine(mean_embeddings[labels[i]], mean_embeddings[labels[j]])
                    if sim > 0.7:
                        # Merge j into i (keep the earlier-seen label)
                        merge_map[labels[j]] = labels[i]
                        logger.info(f"Merging speaker '{labels[j]}' into '{labels[i]}' (similarity={sim:.2f})")

            if merge_map:
                for seg in all_segments:
                    if seg.speaker in merge_map:
                        seg.speaker = merge_map[seg.speaker]

        except ImportError:
            logger.warning("numpy/scipy not available, skipping cross-chunk speaker merging")
        except Exception as e:
            logger.warning(f"Speaker merging failed: {e}")

        return all_segments

    def _map_speaker(self, raw_label: str) -> str:
        """Map a raw pyannote label (SPEAKER_XX) to a consistent friendly label."""
        if raw_label not in self._label_map:
            self._raw_label_counter += 1
            self._label_map[raw_label] = f"Speaker {self._raw_label_counter}"
        return self._label_map[raw_label]
