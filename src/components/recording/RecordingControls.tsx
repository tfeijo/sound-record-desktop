"use client";

import { useRecording } from "@/hooks/useRecording";

const statusLabels: Record<string, string> = {
  idle: "Ready to record",
  recording: "Recording...",
  processing: "Processing...",
  done: "Done",
  error: "Error",
};

function MicrophoneIcon() {
  return (
    <svg
      width="32"
      height="32"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="9" y="1" width="6" height="12" rx="3" />
      <path d="M5 10a7 7 0 0 0 14 0" />
      <line x1="12" y1="17" x2="12" y2="21" />
      <line x1="8" y1="21" x2="16" y2="21" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg
      width="28"
      height="28"
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <rect x="4" y="4" width="16" height="16" rx="2" />
    </svg>
  );
}

export function RecordingControls() {
  const {
    state,
    isRecording,
    formattedDuration,
    error,
    startRecording,
    stopRecording,
  } = useRecording();

  const handleClick = () => {
    if (isRecording) {
      stopRecording();
    } else if (state === "idle" || state === "done" || state === "error") {
      startRecording();
    }
  };

  const isDisabled = state === "processing";

  return (
    <div className="flex flex-col items-center gap-6">
      {/* Record / Stop button */}
      <button
        onClick={handleClick}
        disabled={isDisabled}
        aria-label={isRecording ? "Stop recording" : "Start recording"}
        className={`
          relative flex h-24 w-24 items-center justify-center rounded-full
          text-white transition-all duration-200
          ${isRecording
            ? "bg-red-600 shadow-lg shadow-red-600/40 hover:bg-red-500"
            : "bg-red-600 shadow-lg shadow-red-600/30 hover:scale-105 hover:bg-red-500 hover:shadow-red-500/40 active:scale-95"
          }
          ${isDisabled ? "cursor-not-allowed opacity-50" : "cursor-pointer"}
        `}
      >
        {/* Pulse ring when recording */}
        {isRecording && (
          <>
            <span className="absolute inset-0 animate-ping rounded-full bg-red-500 opacity-20" />
            <span className="absolute -inset-2 animate-pulse rounded-full border-2 border-red-500/40" />
          </>
        )}
        <span className="relative z-10">
          {isRecording ? <StopIcon /> : <MicrophoneIcon />}
        </span>
      </button>

      {/* Duration timer */}
      <p className="font-mono text-2xl font-medium tabular-nums text-neutral-100">
        {formattedDuration}
      </p>

      {/* Status text */}
      <p
        className={`text-sm ${
          state === "error" ? "text-red-400" : "text-neutral-400"
        }`}
      >
        {state === "error" && error ? error : statusLabels[state] ?? state}
      </p>
    </div>
  );
}
