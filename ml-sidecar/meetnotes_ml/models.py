"""Pydantic models for the stdin/stdout JSON protocol."""

from pydantic import BaseModel
from typing import Optional


class TranscriptionRequest(BaseModel):
    audio_paths: dict  # {"mic": "/path/mic.wav", "system": "/path/system.wav"}
    user_name: str = "User"
    language: Optional[str] = None  # None = auto-detect
    model_size: str = "base"  # tiny, base, small, medium, large-v2
    known_speakers: list = []


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
    status: str  # "success" or "error"
    duration_seconds: float = 0.0
    segments: list[Segment] = []
    speakers: list[SpeakerInfo] = []
    language_detected: str = ""
    error: Optional[str] = None
