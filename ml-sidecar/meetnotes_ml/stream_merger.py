"""Merge mic and system audio transcription streams into a single chronological transcript."""

import logging
import re
from dataclasses import dataclass

logger = logging.getLogger(__name__)

_SPEAKER_PATTERN = re.compile(r"^Speaker \d+$")


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
    If user_name collides with a "Speaker N" label, system speakers
    are prefixed with "Participant" instead.

    Returns:
        - merged: list of MergedSegment in chronological order
        - speakers: list of speaker info dicts with id, source, total_duration
    """
    # Detect label collision: if user_name looks like "Speaker N", remap system labels
    remap_system = _SPEAKER_PATTERN.match(user_name) is not None

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
        if remap_system and _SPEAKER_PATTERN.match(speaker):
            speaker = speaker.replace("Speaker", "Participant")
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

    logger.info(
        "Merged %d mic + %d system = %d total segments, %d speakers",
        len(mic_segments), len(system_segments), len(merged), len(speakers),
    )
    return merged, speakers
