"""Speaker diarization using pyannote.audio."""

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
        except ImportError:
            logger.warning("pyannote.audio not installed — diarization disabled")

    @property
    def available(self) -> bool:
        return self._pipeline is not None

    def diarize(self, audio_path: str) -> list[DiarizedSegment]:
        """Run speaker diarization on an audio file.

        Returns a list of DiarizedSegment with speaker labels (SPEAKER_00, SPEAKER_01, etc.).
        If pyannote is not available, returns an empty list (caller falls back to single speaker).
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
