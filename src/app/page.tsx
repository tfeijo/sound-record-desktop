"use client";

import { useEffect } from "react";
import { RecordingControls } from "@/components/recording/RecordingControls";
import { RecordingStatus } from "@/components/recording/RecordingStatus";
import { AudioLevelMeter } from "@/components/recording/AudioLevelMeter";
import { useWebSocket } from "@/hooks/useWebSocket";
import { useRecordingStore } from "@/stores/recordingStore";

export default function Home() {
  const { isConnected } = useWebSocket();

  // Listen for Tauri recording:level events (emitted by Rust AudioCapture)
  useEffect(() => {
    let unlisten: (() => void) | null = null;

    async function setupTauriListener() {
      try {
        if (typeof window === "undefined" || !("__TAURI__" in window)) {
          return;
        }
        const { listen } = await import("@tauri-apps/api/event");
        unlisten = await listen<{ level: number }>(
          "recording:level",
          (event) => {
            useRecordingStore.getState().setAudioLevel(event.payload.level);
          },
        );
      } catch {
        // Not in Tauri environment, ignore
      }
    }

    setupTauriListener();

    return () => {
      if (unlisten) {
        unlisten();
      }
    };
  }, []);

  return (
    <main className="relative flex min-h-screen flex-col items-center justify-center bg-neutral-950 text-white">
      {/* Status badge - top right */}
      <div className="absolute right-4 top-4">
        <RecordingStatus isConnected={isConnected} />
      </div>

      {/* Title */}
      <h1 className="mb-16 text-4xl font-bold tracking-tight text-neutral-100">
        MeetNotes
      </h1>

      {/* Main recording controls */}
      <RecordingControls />

      {/* Audio level meter */}
      <div className="mt-8">
        <AudioLevelMeter />
      </div>
    </main>
  );
}
