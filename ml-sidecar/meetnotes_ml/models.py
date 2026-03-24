"""Pydantic models for the stdin/stdout JSON-lines streaming protocol."""

from typing import Literal

from pydantic import BaseModel


# ---------------------------------------------------------------------------
# Shared types
# ---------------------------------------------------------------------------

class Segment(BaseModel):
    speaker: str
    start: float
    end: float
    text: str
    confidence: float = 0.0


class SpeakerInfo(BaseModel):
    id: str
    source: str  # "mic" or "system"
    total_duration: float


# ---------------------------------------------------------------------------
# Streaming request messages  (Go → Python, one JSON per line on stdin)
# ---------------------------------------------------------------------------

class StreamInit(BaseModel):
    """Sent once at recording start. Loads model + diarizer."""
    type: Literal["init"] = "init"
    model_size: Literal["tiny", "base", "small", "medium", "large-v2"] = "base"
    language: str | None = None
    user_name: str = "User"
    known_speakers: list[str] = []


class StreamChunk(BaseModel):
    """Sent every ~10s with new audio to transcribe."""
    type: Literal["chunk"] = "chunk"
    chunk_id: int
    audio_paths: dict[str, str]  # {"mic": "/tmp/chunk_3_mic.wav", "system": "/tmp/chunk_3_sys.wav"}
    offset_seconds: float  # absolute offset from meeting start


class StreamFinalize(BaseModel):
    """Sent when recording stops. Triggers final consolidation."""
    type: Literal["finalize"] = "finalize"


# ---------------------------------------------------------------------------
# Streaming response messages  (Python → Go, one JSON per line on stdout)
# ---------------------------------------------------------------------------

class ReadyResponse(BaseModel):
    """Sent after init succeeds."""
    type: Literal["ready"] = "ready"
    model_size: str
    device: str


class ChunkResult(BaseModel):
    """Sent after each chunk is processed."""
    type: Literal["chunk_result"] = "chunk_result"
    chunk_id: int
    segments: list[Segment] = []
    language_detected: str = ""
    warnings: list[str] = []


class FinalResult(BaseModel):
    """Sent after finalize — the complete consolidated transcript."""
    type: Literal["final_result"] = "final_result"
    status: Literal["success", "partial", "error"]
    duration_seconds: float = 0.0
    segments: list[Segment] = []
    speakers: list[SpeakerInfo] = []
    language_detected: str = ""
    warnings: list[str] = []


class ErrorResponse(BaseModel):
    """Sent on any error (non-fatal, sidecar keeps running)."""
    type: Literal["error"] = "error"
    chunk_id: int | None = None  # set if error is chunk-specific
    error: str


# ---------------------------------------------------------------------------
# Legacy types (used by current single-shot flow; will be removed once
# streaming is fully wired in US-005)
# ---------------------------------------------------------------------------

class TranscriptionRequest(BaseModel):
    audio_paths: dict[str, str]
    user_name: str = "User"
    language: str | None = None
    model_size: Literal["tiny", "base", "small", "medium", "large-v2"] = "base"
    known_speakers: list[str] = []


class TranscriptionResponse(BaseModel):
    status: Literal["success", "partial", "error"]
    duration_seconds: float = 0.0
    segments: list[Segment] = []
    speakers: list[SpeakerInfo] = []
    language_detected: str = ""
    warnings: list[str] = []
    error: str | None = None
