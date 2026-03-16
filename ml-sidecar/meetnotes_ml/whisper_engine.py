"""Whisper transcription engine using faster-whisper."""

import logging
from pathlib import Path

from faster_whisper import WhisperModel

logger = logging.getLogger(__name__)


class WhisperEngine:
    def __init__(self, model_size: str = "base", device: str = "cpu", compute_type: str = "int8"):
        logger.info(f"Loading Whisper model: {model_size} on {device} ({compute_type})")
        self.model = WhisperModel(model_size, device=device, compute_type=compute_type)
        logger.info("Whisper model loaded")

    def transcribe(self, audio_path: str, language: str | None = None) -> tuple[list[dict], str, float]:
        """Transcribe audio file, return list of segments, detected language, and duration."""
        logger.info(f"Transcribing: {audio_path}")

        segments, info = self.model.transcribe(
            audio_path,
            language=language,
            beam_size=5,
            word_timestamps=True,
            vad_filter=True,
        )

        result = []
        for segment in segments:
            result.append({
                "start": segment.start,
                "end": segment.end,
                "text": segment.text.strip(),
                "confidence": segment.avg_logprob,
                "words": [
                    {"start": w.start, "end": w.end, "text": w.word, "probability": w.probability}
                    for w in (segment.words or [])
                ],
            })

        detected_language = info.language if info else "unknown"
        duration = info.duration if info else 0.0
        logger.info(f"Transcription complete: {len(result)} segments, language={detected_language}, duration={duration:.1f}s")

        return result, detected_language, duration
