"use client";

import { useEffect, useRef, useCallback } from "react";
import { useRecordingStore } from "@/stores/recordingStore";
import * as api from "@/lib/api";

function formatDuration(totalSeconds: number): string {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return [h, m, s].map((v) => String(v).padStart(2, "0")).join(":");
}

/** Dynamically import Tauri invoke, returns null when not in Tauri shell. */
async function getTauriInvoke(): Promise<
  ((cmd: string, args?: Record<string, unknown>) => Promise<unknown>) | null
> {
  try {
    if (typeof window === "undefined" || !("__TAURI__" in window)) {
      return null;
    }
    const { invoke } = await import("@tauri-apps/api/core");
    return invoke;
  } catch {
    return null;
  }
}

interface StopRecordingResult {
  micPath: string;
  systemPath: string;
  durationSecs: number;
}

export function useRecording() {
  const state = useRecordingStore((s) => s.state);
  const duration = useRecordingStore((s) => s.duration);
  const meetingId = useRecordingStore((s) => s.meetingId);
  const error = useRecordingStore((s) => s.error);

  const store = useRecordingStore;
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Duration timer
  useEffect(() => {
    if (state === "recording") {
      store.getState().setDuration(0);
      intervalRef.current = setInterval(() => {
        store.setState((prev) => ({ ...prev, duration: prev.duration + 1 }));
      }, 1000);
    } else {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
    }

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
    };
  }, [state, store]);

  const startRecording = useCallback(async () => {
    try {
      const s = store.getState();
      s.setError(null);

      // 1. Call Go API to create meeting in DB
      const res = await api.startRecording();
      s.setMeetingId(res.meetingId);
      s.setState("recording");

      // 2. Start Tauri audio capture (if running inside Tauri)
      const invoke = await getTauriInvoke();
      if (invoke) {
        try {
          await invoke("start_recording", { meetingId: res.meetingId });
        } catch (tauriErr) {
          console.warn("Tauri start_recording failed:", tauriErr);
          // Don't fail the whole flow - Go already created the meeting
        }
      }
    } catch (err) {
      store
        .getState()
        .setError(err instanceof Error ? err.message : "Failed to start recording");
    }
  }, [store]);

  const stopRecording = useCallback(async () => {
    try {
      let stopBody: api.StopRecordingBody | undefined;

      // 1. Stop Tauri audio capture first (if running inside Tauri)
      const invoke = await getTauriInvoke();
      if (invoke) {
        try {
          const result = (await invoke("stop_recording")) as StopRecordingResult;
          stopBody = {
            micPath: result.micPath,
            systemPath: result.systemPath,
            duration: result.durationSecs,
          };
        } catch (tauriErr) {
          console.warn("Tauri stop_recording failed:", tauriErr);
        }
      }

      // 2. Call Go API with file paths so it can update the meeting record
      await api.stopRecording(stopBody);

      const s = store.getState();
      s.setState("idle");
      s.setAudioLevel(0);
    } catch (err) {
      store
        .getState()
        .setError(err instanceof Error ? err.message : "Failed to stop recording");
    }
  }, [store]);

  return {
    state,
    duration,
    meetingId,
    error,
    isRecording: state === "recording",
    startRecording,
    stopRecording,
    formattedDuration: formatDuration(duration),
  };
}
