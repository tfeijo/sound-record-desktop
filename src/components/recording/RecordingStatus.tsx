"use client";

import { useRecordingStore } from "@/stores/recordingStore";

const stateLabels: Record<string, string> = {
  idle: "Idle",
  recording: "Recording",
  processing: "Processing",
  done: "Done",
  error: "Error",
};

export function RecordingStatus({ isConnected }: { isConnected: boolean }) {
  const state = useRecordingStore((s) => s.state);

  return (
    <div className="flex items-center gap-3 rounded-full bg-neutral-900 px-4 py-2 text-sm">
      {/* WebSocket connection indicator */}
      <div className="flex items-center gap-1.5">
        <span
          className={`inline-block h-2 w-2 rounded-full ${
            isConnected ? "bg-green-500" : "bg-red-500"
          }`}
        />
        <span className="text-neutral-400">
          {isConnected ? "Connected" : "Disconnected"}
        </span>
      </div>

      <span className="text-neutral-700">|</span>

      {/* Recording state */}
      <span className="text-neutral-300">{stateLabels[state] ?? state}</span>
    </div>
  );
}
