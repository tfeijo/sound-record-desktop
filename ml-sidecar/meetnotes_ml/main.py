"""Entry point: stdin/stdout JSON protocol."""

import os
import sys
import logging
import traceback

from .models import TranscriptionRequest, TranscriptionResponse, Segment, SpeakerInfo
from .whisper_engine import WhisperEngine

logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s [%(name)s] %(message)s")
logger = logging.getLogger("meetnotes_ml")


def detect_device():
    """Detect best available device."""
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda", "float16"
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "cpu", "int8"  # faster-whisper doesn't support MPS directly
    except ImportError:
        pass
    return "cpu", "int8"


def process_request(request: TranscriptionRequest) -> TranscriptionResponse:
    device, compute_type = detect_device()
    engine = WhisperEngine(model_size=request.model_size, device=device, compute_type=compute_type)

    all_segments: list[Segment] = []
    speakers: list[SpeakerInfo] = []
    warnings: list[str] = []
    total_duration = 0.0
    detected_language = ""

    # Transcribe mic audio (user)
    mic_path = request.audio_paths.get("mic")
    if mic_path:
        if not os.path.isfile(mic_path):
            warnings.append(f"Mic audio file not found: {mic_path}")
        else:
            try:
                mic_segments, lang, duration = engine.transcribe(mic_path, language=request.language)
                detected_language = lang
                total_duration = max(total_duration, duration)

                mic_duration = 0.0
                for seg in mic_segments:
                    all_segments.append(Segment(
                        speaker=request.user_name,
                        start=seg["start"],
                        end=seg["end"],
                        text=seg["text"],
                        confidence=seg["confidence"],
                    ))
                    mic_duration += seg["end"] - seg["start"]

                speakers.append(SpeakerInfo(id=request.user_name, source="mic", total_duration=mic_duration))
            except Exception as e:
                logger.error(f"Mic transcription failed: {e}")
                warnings.append(f"Mic transcription failed: {e}")

    # Transcribe system audio (other participants)
    system_path = request.audio_paths.get("system")
    if system_path:
        if not os.path.isfile(system_path):
            warnings.append(f"System audio file not found: {system_path}")
        else:
            try:
                sys_segments, lang, duration = engine.transcribe(system_path, language=request.language)
                if not detected_language:
                    detected_language = lang
                total_duration = max(total_duration, duration)

                sys_duration = 0.0
                for seg in sys_segments:
                    all_segments.append(Segment(
                        speaker="Speaker 1",  # Will be diarized in US-011
                        start=seg["start"],
                        end=seg["end"],
                        text=seg["text"],
                        confidence=seg["confidence"],
                    ))
                    sys_duration += seg["end"] - seg["start"]

                if sys_segments:
                    speakers.append(SpeakerInfo(id="Speaker 1", source="system", total_duration=sys_duration))
            except Exception as e:
                logger.error(f"System transcription failed: {e}")
                warnings.append(f"System transcription failed: {e}")

    # Sort all segments chronologically
    all_segments.sort(key=lambda s: s.start)

    status = "success" if not warnings else "partial"

    return TranscriptionResponse(
        status=status,
        duration_seconds=total_duration,
        segments=all_segments,
        speakers=speakers,
        language_detected=detected_language,
        warnings=warnings,
    )


def main():
    logger.info("MeetNotes ML sidecar started, waiting for input on stdin...")

    try:
        max_input = 1 * 1024 * 1024  # 1 MB cap
        raw = sys.stdin.read(max_input)
        if not raw.strip():
            logger.error("Empty input received")
            response = TranscriptionResponse(status="error", error="Empty input")
            print(response.model_dump_json())
            return

        request = TranscriptionRequest.model_validate_json(raw)
        logger.info(f"Processing request: model={request.model_size}, user={request.user_name}")

        response = process_request(request)

    except Exception as e:
        logger.error(f"Error processing request: {e}")
        logger.error(traceback.format_exc())
        response = TranscriptionResponse(status="error", error=str(e))

    print(response.model_dump_json())


if __name__ == "__main__":
    main()
