"""Pydantic models for the stdin/stdout JSON protocol."""

from typing import Literal

from pydantic import BaseModel


class TranscriptionRequest(BaseModel):
    audio_paths: dict[str, str]  # {"mic": "/path/mic.wav", "system": "/path/system.wav"}
    user_name: str = "User"
    language: str | None = None  # None = auto-detect
    model_size: Literal["tiny", "base", "small", "medium", "large-v2"] = "base"
    known_speakers: list[str] = []


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


class TranscriptionResponse(BaseModel):
    status: Literal["success", "partial", "error"]
    duration_seconds: float = 0.0
    segments: list[Segment] = []
    speakers: list[SpeakerInfo] = []
    language_detected: str = ""
    warnings: list[str] = []
    error: str | None = None
