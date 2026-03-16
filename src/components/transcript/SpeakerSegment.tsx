"use client";

import type { TranscriptSegment } from "@/lib/types";

const SPEAKER_COLORS: Record<string, string> = {};
const COLOR_PALETTE = [
  "text-blue-400",
  "text-emerald-400",
  "text-amber-400",
  "text-purple-400",
  "text-rose-400",
  "text-cyan-400",
  "text-orange-400",
  "text-pink-400",
];

function getSpeakerColor(speaker: string): string {
  if (!SPEAKER_COLORS[speaker]) {
    const idx = Object.keys(SPEAKER_COLORS).length % COLOR_PALETTE.length;
    SPEAKER_COLORS[speaker] = COLOR_PALETTE[idx];
  }
  return SPEAKER_COLORS[speaker];
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

interface SpeakerSegmentProps {
  segment: TranscriptSegment;
}

export function SpeakerSegment({ segment }: SpeakerSegmentProps) {
  const color = getSpeakerColor(segment.speaker);

  return (
    <div className="flex gap-3 py-2 border-b border-neutral-800 last:border-0">
      <div className="flex flex-col items-end min-w-[80px] pt-0.5">
        <span className={`text-sm font-medium ${color}`}>
          {segment.speaker}
        </span>
        <span className="text-xs text-neutral-500">
          {formatTimestamp(segment.start)}
        </span>
      </div>
      <p className="flex-1 text-sm text-neutral-200 leading-relaxed">
        {segment.text}
      </p>
    </div>
  );
}
