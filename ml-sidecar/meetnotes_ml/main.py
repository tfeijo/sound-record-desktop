"""Entry point: stdin/stdout JSON protocol."""

import os
import sys
import logging
import traceback

from .models import TranscriptionRequest, TranscriptionResponse, Segment, SpeakerInfo
from .whisper_engine import WhisperEngine
from .diarization import Diarizer
from .align import align_segments
from .stream_merger import merge_streams

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

    mic_segments: list[dict] = []
    system_segments: list[dict] = []
    warnings: list[str] = []
    total_duration = 0.0
    detected_language = ""

    # --- Transcribe mic audio (user) ---
    mic_path = request.audio_paths.get("mic")
    if mic_path:
        if not os.path.isfile(mic_path):
            warnings.append(f"Mic audio file not found: {mic_path}")
        else:
            try:
                mic_segments, lang, duration = engine.transcribe(mic_path, language=request.language)
                detected_language = lang
                total_duration = max(total_duration, duration)
            except Exception as e:
                logger.error(f"Mic transcription failed: {e}")
                warnings.append(f"Mic transcription failed: {e}")

    # --- Transcribe system audio (other participants) ---
    system_path = request.audio_paths.get("system")
    if system_path:
        if not os.path.isfile(system_path):
            warnings.append(f"System audio file not found: {system_path}")
        else:
            try:
                system_segments, lang, duration = engine.transcribe(system_path, language=request.language)
                if not detected_language:
                    detected_language = lang
                total_duration = max(total_duration, duration)
            except Exception as e:
                logger.error(f"System transcription failed: {e}")
                warnings.append(f"System transcription failed: {e}")

    # --- Diarize system audio ---
    if system_segments and system_path:
        try:
            diarizer = Diarizer()
            if diarizer.available:
                diar_segments = diarizer.diarize(system_path)
                system_segments = align_segments(system_segments, diar_segments)
            else:
                # No diarization available — label all system segments as Speaker 1
                for seg in system_segments:
                    seg["speaker"] = "Speaker 1"
        except Exception as e:
            logger.error(f"Diarization failed, falling back to single speaker: {e}")
            warnings.append(f"Diarization failed: {e}")
            for seg in system_segments:
                seg["speaker"] = "Speaker 1"

    # --- Merge both streams ---
    merged, speaker_infos = merge_streams(mic_segments, system_segments, user_name=request.user_name)

    # Convert to response models
    segments = [
        Segment(
            speaker=m.speaker,
            start=m.start,
            end=m.end,
            text=m.text,
            confidence=m.confidence,
        )
        for m in merged
    ]

    speakers = [
        SpeakerInfo(id=s["id"], source=s["source"], total_duration=s["total_duration"])
        for s in speaker_infos
    ]

    status = "success" if not warnings else "partial"

    return TranscriptionResponse(
        status=status,
        duration_seconds=total_duration,
        segments=segments,
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
