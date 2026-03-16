import { create } from "zustand";
import type { RecordingState } from "@/lib/types";

interface RecordingStore {
  state: RecordingState;
  duration: number;
  meetingId: string | null;
  error: string | null;
  audioLevel: number;

  setState: (state: RecordingState) => void;
  setDuration: (duration: number) => void;
  setMeetingId: (meetingId: string | null) => void;
  setError: (error: string | null) => void;
  setAudioLevel: (level: number) => void;
  reset: () => void;
}

export const useRecordingStore = create<RecordingStore>((set) => ({
  state: "idle",
  duration: 0,
  meetingId: null,
  error: null,
  audioLevel: 0,

  setState: (state) => set({ state }),
  setDuration: (duration) => set({ duration }),
  setMeetingId: (meetingId) => set({ meetingId }),
  setError: (error) => set({ error, state: error ? "error" : "idle" }),
  setAudioLevel: (level) => set({ audioLevel: level }),
  reset: () =>
    set({
      state: "idle",
      duration: 0,
      meetingId: null,
      error: null,
      audioLevel: 0,
    }),
}));
