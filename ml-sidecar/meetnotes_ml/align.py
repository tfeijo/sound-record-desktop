"""Align Whisper transcription segments with diarization speaker labels."""

import logging

from .diarization import DiarizedSegment

logger = logging.getLogger(__name__)


def align_segments(
    transcription_segments: list[dict],
    diarization_segments: list[DiarizedSegment],
) -> list[dict]:
    """Assign speaker labels from diarization to transcription segments.

    For each transcription segment, find the diarization segment with the
    greatest overlap and assign its speaker label. If no diarization data
    is available, all segments get "Speaker 1".
    """
    if not diarization_segments:
        # No diarization — label everything as Speaker 1
        for seg in transcription_segments:
            seg["speaker"] = "Speaker 1"
        return transcription_segments

    for seg in transcription_segments:
        seg["speaker"] = _find_best_speaker(seg["start"], seg["end"], diarization_segments)

    return transcription_segments


def _find_best_speaker(start: float, end: float, diar_segments: list[DiarizedSegment]) -> str:
    """Find the diarization speaker with maximum overlap for a time range."""
    best_speaker = "Speaker 1"
    best_overlap = 0.0

    for dseg in diar_segments:
        overlap_start = max(start, dseg.start)
        overlap_end = min(end, dseg.end)
        overlap = max(0.0, overlap_end - overlap_start)

        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = dseg.speaker

    return best_speaker
