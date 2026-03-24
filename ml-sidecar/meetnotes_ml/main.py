"""Entry point: stdin/stdout JSON-lines streaming protocol."""

import json
import os
import sys
import logging
import traceback

from .models import (
    StreamInit, StreamChunk, StreamFinalize,
    ReadyResponse, ChunkResult, FinalResult, ErrorResponse,
    Segment, SpeakerInfo,
)
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


def send(msg) -> None:
    """Write a single JSON-line to stdout and flush."""
    print(msg.model_dump_json(), flush=True)


def parse_incoming(line: str) -> StreamInit | StreamChunk | StreamFinalize:
    """Parse an incoming JSON-line and return the appropriate request model."""
    raw = json.loads(line)
    msg_type = raw.get("type")
    dispatch = {
        "init": StreamInit,
        "chunk": StreamChunk,
        "finalize": StreamFinalize,
    }
    cls = dispatch.get(msg_type)
    if cls is None:
        raise ValueError(f"Unknown message type: {msg_type}")
    return cls.model_validate(raw)


class StreamingSession:
    """Manages state for a single streaming transcription session."""

    def __init__(self):
        self.engine: WhisperEngine | None = None
        self.diarizer: Diarizer | None = None
        self.device: str = "cpu"
        self.language: str | None = None
        self.user_name: str = "User"
        self.all_mic_segments: list[dict] = []
        self.all_system_segments: list[dict] = []
        self.all_warnings: list[str] = []
        self.detected_language: str = ""
        self.total_duration: float = 0.0
        self.system_audio_paths: list[tuple[str, float]] = []  # (path, offset_seconds)

    def handle_init(self, msg: StreamInit) -> None:
        try:
            self.device, compute_type = detect_device()
            self.language = msg.language
            self.user_name = msg.user_name
            # TODO(US-006): use msg.known_speakers for speaker identification hints

            logger.info(f"Init: model={msg.model_size}, device={self.device}, user={msg.user_name}")
            self.engine = WhisperEngine(model_size=msg.model_size, device=self.device, compute_type=compute_type)
            self.diarizer = Diarizer()

            send(ReadyResponse(model_size=msg.model_size, device=self.device))
        except Exception as e:
            logger.error(f"Init failed: {e}")
            send(ErrorResponse(error=f"Init failed: {e}"))

    def handle_chunk(self, msg: StreamChunk) -> None:
        if self.engine is None:
            send(ErrorResponse(chunk_id=msg.chunk_id, error="Not initialized — send 'init' first"))
            return

        warnings: list[str] = []
        chunk_language = ""
        new_mic_segs: list[dict] = []
        new_sys_segs: list[dict] = []

        # Transcribe mic audio
        mic_path = msg.audio_paths.get("mic")
        if mic_path:
            if not os.path.isfile(mic_path):
                warnings.append(f"Mic audio file not found: {mic_path}")
            else:
                try:
                    segs, lang, duration = self.engine.transcribe(mic_path, language=self.language)
                    for seg in segs:
                        seg["start"] += msg.offset_seconds
                        seg["end"] += msg.offset_seconds
                        seg["speaker"] = self.user_name
                    new_mic_segs = segs
                    self.all_mic_segments.extend(segs)
                    if lang:
                        chunk_language = lang
                        if not self.detected_language:
                            self.detected_language = lang
                    self.total_duration = max(self.total_duration, msg.offset_seconds + duration)
                except Exception as e:
                    logger.error(f"Chunk {msg.chunk_id} mic transcription failed: {e}")
                    warnings.append(f"Mic transcription failed: {e}")

        # Transcribe system audio
        system_path = msg.audio_paths.get("system")
        if system_path:
            if not os.path.isfile(system_path):
                warnings.append(f"System audio file not found: {system_path}")
            else:
                try:
                    segs, lang, duration = self.engine.transcribe(system_path, language=self.language)
                    for seg in segs:
                        seg["start"] += msg.offset_seconds
                        seg["end"] += msg.offset_seconds
                    new_sys_segs = segs
                    self.all_system_segments.extend(segs)
                    self.system_audio_paths.append((system_path, msg.offset_seconds))
                    if lang and not chunk_language:
                        chunk_language = lang
                    if lang and not self.detected_language:
                        self.detected_language = lang
                    self.total_duration = max(self.total_duration, msg.offset_seconds + duration)
                except Exception as e:
                    logger.error(f"Chunk {msg.chunk_id} system transcription failed: {e}")
                    warnings.append(f"System transcription failed: {e}")

        self.all_warnings.extend(warnings)

        # Build chunk result from this chunk's segments only
        chunk_result_segs = []
        for seg in new_mic_segs:
            chunk_result_segs.append(Segment(
                speaker=seg.get("speaker", self.user_name),
                start=seg["start"], end=seg["end"],
                text=seg["text"], confidence=seg.get("confidence", 0.0),
            ))
        for seg in new_sys_segs:
            chunk_result_segs.append(Segment(
                speaker=seg.get("speaker", "Speaker 1"),
                start=seg["start"], end=seg["end"],
                text=seg["text"], confidence=seg.get("confidence", 0.0),
            ))

        send(ChunkResult(
            chunk_id=msg.chunk_id,
            segments=chunk_result_segs,
            language_detected=chunk_language,
            warnings=warnings,
        ))

    def handle_finalize(self) -> None:
        # Run diarization on accumulated system segments
        if self.all_system_segments and self.diarizer and self.diarizer.available:
            try:
                # Diarize using all system audio paths, offsetting to absolute time
                all_diar_segments = []
                for path, offset in self.system_audio_paths:
                    if os.path.isfile(path):
                        diar = self.diarizer.diarize(path)
                        for d in diar:
                            d.start += offset
                            d.end += offset
                        all_diar_segments.extend(diar)
                if all_diar_segments:
                    self.all_system_segments = align_segments(self.all_system_segments, all_diar_segments)
            except Exception as e:
                logger.error(f"Finalize diarization failed: {e}")
                self.all_warnings.append(f"Diarization failed: {e}")
                for seg in self.all_system_segments:
                    seg["speaker"] = "Speaker 1"
        else:
            for seg in self.all_system_segments:
                seg.setdefault("speaker", "Speaker 1")

        # Merge streams
        merged, speaker_infos = merge_streams(
            self.all_mic_segments, self.all_system_segments, user_name=self.user_name,
        )

        segments = [
            Segment(speaker=m.speaker, start=m.start, end=m.end, text=m.text, confidence=m.confidence)
            for m in merged
        ]
        speakers = [
            SpeakerInfo(id=s["id"], source=s["source"], total_duration=s["total_duration"])
            for s in speaker_infos
        ]

        status = "success" if not self.all_warnings else "partial"

        send(FinalResult(
            status=status,
            duration_seconds=self.total_duration,
            segments=segments,
            speakers=speakers,
            language_detected=self.detected_language,
            warnings=self.all_warnings,
        ))


def main():
    logger.info("MeetNotes ML sidecar started (streaming mode), reading JSON-lines from stdin...")

    session = StreamingSession()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            msg = parse_incoming(line)

            if isinstance(msg, StreamInit):
                session = StreamingSession()
                session.handle_init(msg)
            elif isinstance(msg, StreamChunk):
                session.handle_chunk(msg)
            elif isinstance(msg, StreamFinalize):
                session.handle_finalize()

        except Exception as e:
            logger.error(f"Error processing message: {e}")
            logger.error(traceback.format_exc())
            send(ErrorResponse(error=str(e)))

    logger.info("Stdin closed, sidecar exiting")


if __name__ == "__main__":
    main()
