"use client";

import { useCallback, useMemo, useState } from "react";
import type { TranscriptionResult } from "@/lib/types";
import { SpeakerSegment } from "./SpeakerSegment";

function formatSpeakerDuration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  return `${Math.round(seconds / 60)}m`;
}

interface TranscriptViewerProps {
  transcript: TranscriptionResult;
  meetingId?: string;
  onTranscriptUpdate?: (updated: TranscriptionResult) => void;
}

export function TranscriptViewer({
  transcript: initialTranscript,
  meetingId,
  onTranscriptUpdate,
}: TranscriptViewerProps) {
  const [transcript, setTranscript] = useState(initialTranscript);

  const speakerList = useMemo(
    () => transcript.speakers.map((s) => s.id),
    [transcript.speakers],
  );

  const handleSpeakerRenamed = useCallback(
    (oldName: string, newName: string) => {
      setTranscript((prev) => {
        const updated = {
          ...prev,
          segments: prev.segments.map((seg) =>
            seg.speaker === oldName ? { ...seg, speaker: newName } : seg,
          ),
          speakers: prev.speakers.map((sp) =>
            sp.id === oldName ? { ...sp, id: newName } : sp,
          ),
        };
        onTranscriptUpdate?.(updated);
        return updated;
      });
    },
    [onTranscriptUpdate],
  );

  if (transcript.segments.length === 0) {
    return (
      <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center text-neutral-500">
        No transcript segments found.
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {/* Speaker summary */}
      <div className="flex flex-wrap gap-2">
        {transcript.speakers.map((speaker) => (
          <span
            key={speaker.id}
            className="rounded-full bg-neutral-800 px-3 py-1 text-xs text-neutral-300"
          >
            {speaker.id} ({speaker.source}) &middot;{" "}
            {formatSpeakerDuration(speaker.total_duration)}
          </span>
        ))}
        {transcript.language_detected && (
          <span className="rounded-full bg-neutral-800 px-3 py-1 text-xs text-neutral-400">
            Language: {transcript.language_detected}
          </span>
        )}
      </div>

      {/* Warnings */}
      {transcript.warnings.length > 0 && (
        <div className="rounded-lg border border-amber-800/50 bg-amber-950/30 p-3">
          {transcript.warnings.map((w, i) => (
            <p key={i} className="text-xs text-amber-400">
              {w}
            </p>
          ))}
        </div>
      )}

      {/* Rename hint */}
      {meetingId && speakerList.some((s) => /^(Speaker|Participant) \d+$/.test(s)) && (
        <p className="text-xs text-neutral-500">
          Click on a speaker name to assign a real name and save for future meetings.
        </p>
      )}

      {/* Segments */}
      <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-4 max-h-[60vh] overflow-y-auto">
        {transcript.segments.map((segment) => (
          <SpeakerSegment
            key={`${segment.speaker}-${segment.start}`}
            segment={segment}
            speakerList={speakerList}
            meetingId={meetingId}
            onSpeakerRenamed={handleSpeakerRenamed}
          />
        ))}
      </div>
    </div>
  );
}
