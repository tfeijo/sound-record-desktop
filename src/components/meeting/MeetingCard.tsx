"use client";

import type { Meeting, MeetingStatus } from "@/lib/types";

interface MeetingCardProps {
  meeting: Meeting;
  onDelete: (id: string) => void;
}

const STATUS_LABELS: Record<MeetingStatus, string> = {
  recording: "Recording",
  transcribing: "Transcribing",
  summarizing: "Summarizing",
  done: "Done",
  error: "Error",
};

const STATUS_COLORS: Record<MeetingStatus, string> = {
  recording: "bg-red-500/20 text-red-400",
  transcribing: "bg-yellow-500/20 text-yellow-400",
  summarizing: "bg-blue-500/20 text-blue-400",
  done: "bg-green-500/20 text-green-400",
  error: "bg-red-500/20 text-red-400",
};

function formatDuration(seconds: number): string {
  if (seconds <= 0) return "0m";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function formatDate(dateStr: string): string {
  try {
    const d = new Date(dateStr);
    return d.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
  } catch {
    return dateStr;
  }
}

export function MeetingCard({ meeting, onDelete }: MeetingCardProps) {
  const handleClick = () => {
    window.location.href = `/meeting?id=${meeting.id}`;
  };

  const handleDelete = (e: React.MouseEvent) => {
    e.stopPropagation();
    onDelete(meeting.id);
  };

  return (
    <div
      onClick={handleClick}
      className="group cursor-pointer rounded-lg border border-neutral-800 bg-neutral-900 p-4 transition-colors hover:border-neutral-700 hover:bg-neutral-800/80"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-sm font-medium text-neutral-100">
            {meeting.title || "Untitled Meeting"}
          </h3>
          <div className="mt-1 flex items-center gap-3 text-xs text-neutral-400">
            <span>{formatDate(meeting.date)}</span>
            {meeting.durationSeconds > 0 && (
              <span>{formatDuration(meeting.durationSeconds)}</span>
            )}
            {meeting.speakerCount > 0 && (
              <span>
                {meeting.speakerCount} speaker{meeting.speakerCount !== 1 ? "s" : ""}
              </span>
            )}
          </div>
          {meeting.error && (
            <p className="mt-1 truncate text-xs text-red-400">{meeting.error}</p>
          )}
        </div>

        <div className="flex items-center gap-2">
          <span
            className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_COLORS[meeting.status]}`}
          >
            {STATUS_LABELS[meeting.status]}
          </span>
          <button
            onClick={handleDelete}
            className="rounded p-1 text-neutral-500 opacity-0 transition-opacity hover:bg-neutral-700 hover:text-neutral-300 group-hover:opacity-100"
            title="Delete meeting"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <path d="M3 6h18" />
              <path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6" />
              <path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2" />
            </svg>
          </button>
        </div>
      </div>
    </div>
  );
}
