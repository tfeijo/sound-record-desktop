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

      const invoke = await getTauriInvoke();
      if (invoke) {
        // Tauri orchestrates everything: audio capture + Go backend
        const result = (await invoke("start_recording")) as {
          meetingId: string;
          micPath: string;
          systemPath: string;
        };
        s.setMeetingId(result.meetingId);
        s.setState("recording");
        console.log("[Tauri] Recording started:", result.meetingId);
      } else {
        // Browser fallback: call Go API directly (no audio capture)
        const res = await api.startRecording();
        s.setMeetingId(res.meetingId);
        s.setState("recording");
        console.warn("[Browser] Recording started without audio capture");
      }
    } catch (err) {
      store
        .getState()
        .setError(err instanceof Error ? err.message : "Failed to start recording");
    }
  }, [store]);

  const stopRecording = useCallback(async () => {
    try {
      const invoke = await getTauriInvoke();
      if (invoke) {
        // Tauri orchestrates everything: stop audio + notify Go backend
        await invoke("stop_recording");
      } else {
        // Browser fallback
        await api.stopRecording();
      }

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
