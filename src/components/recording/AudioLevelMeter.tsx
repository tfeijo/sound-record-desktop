"use client";

import { useRecordingStore } from "@/stores/recordingStore";

export function AudioLevelMeter() {
  const level = useRecordingStore((s) => s.audioLevel);
  const state = useRecordingStore((s) => s.state);

  if (state !== "recording") return null;

  // Clamp level to 0-100
  const clamped = Math.max(0, Math.min(100, level));

  // Color based on level
  let barColor = "bg-green-500";
  if (clamped > 80) {
    barColor = "bg-red-500";
  } else if (clamped > 50) {
    barColor = "bg-yellow-500";
  }

  return (
    <div className="w-64">
      <div className="h-2 w-full overflow-hidden rounded-full bg-neutral-800">
        <div
          className={`h-full rounded-full transition-all duration-100 ${barColor}`}
          style={{ width: `${clamped}%` }}
        />
      </div>
      <p className="mt-1 text-center text-xs text-neutral-500">Audio Level</p>
    </div>
  );
}
