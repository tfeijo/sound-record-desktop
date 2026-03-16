"use client";

import { useEffect } from "react";
import { useRecordingStore } from "@/stores/recordingStore";

/**
 * Listens to Tauri-emitted events (recording:level, recording:started, recording:stopped)
 * and updates the recording store. These events come from Rust, not Go WebSocket.
 */
export function useTauriEvents() {
  useEffect(() => {
    let unlisten: (() => void)[] = [];

    async function setup() {
      try {
        if (typeof window === "undefined" || !("__TAURI__" in window)) {
          return;
        }
        const { listen } = await import("@tauri-apps/api/event");

        const u1 = await listen<{ level: number }>("recording:level", (event) => {
          // Tauri emits 0.0-1.0, AudioLevelMeter expects 0-100
          useRecordingStore.getState().setAudioLevel(event.payload.level * 100);
        });

        const u2 = await listen<{ meetingId: string }>("recording:started", (event) => {
          console.log("[TauriEvent] recording:started", event.payload);
        });

        const u3 = await listen<{ meetingId: string; micPath: string; systemPath: string }>(
          "recording:stopped",
          (event) => {
            console.log("[TauriEvent] recording:stopped", event.payload);
          },
        );

        unlisten = [u1, u2, u3];
      } catch {
        // Not in Tauri context
      }
    }

    setup();

    return () => {
      unlisten.forEach((fn) => fn());
    };
  }, []);
}
