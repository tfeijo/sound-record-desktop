import type { TranscriptSegment } from "@/lib/types";
import { SpeakerLabel } from "./SpeakerLabel";

export const COLOR_PALETTE = [
  "text-blue-400",
  "text-emerald-400",
  "text-amber-400",
  "text-purple-400",
  "text-rose-400",
  "text-cyan-400",
  "text-orange-400",
  "text-pink-400",
];

export function getSpeakerColor(speaker: string, speakerList: string[]): string {
  const idx = speakerList.indexOf(speaker);
  return COLOR_PALETTE[(idx >= 0 ? idx : 0) % COLOR_PALETTE.length];
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

interface SpeakerSegmentProps {
  segment: TranscriptSegment;
  speakerList: string[];
  meetingId?: string;
  onSpeakerRenamed?: (oldName: string, newName: string) => void;
}

export function SpeakerSegment({
  segment,
  speakerList,
  meetingId,
  onSpeakerRenamed,
}: SpeakerSegmentProps) {
  const color = getSpeakerColor(segment.speaker, speakerList);

  return (
    <div className="flex gap-3 py-2 border-b border-neutral-800 last:border-0">
      <div className="flex flex-col items-end min-w-[80px] pt-0.5">
        {meetingId && onSpeakerRenamed ? (
          <SpeakerLabel
            speaker={segment.speaker}
            meetingId={meetingId}
            start={segment.start}
            end={segment.end}
            color={color}
            onRenamed={onSpeakerRenamed}
          />
        ) : (
          <span className={`text-sm font-medium ${color}`}>
            {segment.speaker}
          </span>
        )}
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
