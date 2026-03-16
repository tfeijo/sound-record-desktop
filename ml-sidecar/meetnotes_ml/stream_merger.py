"""Merge mic and system audio transcription streams into a single chronological transcript."""

import logging
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass
class MergedSegment:
    speaker: str
    start: float
    end: float
    text: str
    confidence: float = 0.0
    source: str = ""  # "mic" or "system"


def merge_streams(
    mic_segments: list[dict],
    system_segments: list[dict],
    user_name: str = "User",
) -> tuple[list[MergedSegment], list[dict]]:
    """Merge mic (user) and system (other participants) transcript segments.

    Mic segments are always labeled with user_name.
    System segments retain their diarized speaker labels.

    Returns:
        - merged: list of MergedSegment in chronological order
        - speakers: list of speaker info dicts with id, source, total_duration
    """
    merged: list[MergedSegment] = []
    speaker_durations: dict[str, float] = {}
    speaker_sources: dict[str, str] = {}

    # Add mic segments (always = user)
    for seg in mic_segments:
        merged.append(MergedSegment(
            speaker=user_name,
            start=seg["start"],
            end=seg["end"],
            text=seg["text"],
            confidence=seg.get("confidence", 0.0),
            source="mic",
        ))
        duration = seg["end"] - seg["start"]
        speaker_durations[user_name] = speaker_durations.get(user_name, 0.0) + duration
        speaker_sources[user_name] = "mic"

    # Add system segments (diarized speakers)
    for seg in system_segments:
        speaker = seg.get("speaker", "Speaker 1")
        merged.append(MergedSegment(
            speaker=speaker,
            start=seg["start"],
            end=seg["end"],
            text=seg["text"],
            confidence=seg.get("confidence", 0.0),
            source="system",
        ))
        duration = seg["end"] - seg["start"]
        speaker_durations[speaker] = speaker_durations.get(speaker, 0.0) + duration
        speaker_sources[speaker] = "system"

    # Sort chronologically
    merged.sort(key=lambda s: s.start)

    # Build speaker info
    speakers = [
        {"id": name, "source": speaker_sources[name], "total_duration": round(dur, 2)}
        for name, dur in speaker_durations.items()
    ]

    logger.info(f"Merged {len(mic_segments)} mic + {len(system_segments)} system = {len(merged)} total segments, {len(speakers)} speakers")
    return merged, speakers
