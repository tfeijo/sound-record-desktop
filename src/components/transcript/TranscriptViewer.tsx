"use client";

import type { TranscriptionResult } from "@/lib/types";
import { SpeakerSegment } from "./SpeakerSegment";

interface TranscriptViewerProps {
  transcript: TranscriptionResult;
}

export function TranscriptViewer({ transcript }: TranscriptViewerProps) {
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
            {Math.round(speaker.total_duration / 60)}m
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

      {/* Segments */}
      <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-4 max-h-[600px] overflow-y-auto">
        {transcript.segments.map((segment, i) => (
          <SpeakerSegment key={i} segment={segment} />
        ))}
      </div>
    </div>
  );
}
