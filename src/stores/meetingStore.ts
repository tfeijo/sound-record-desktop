import { create } from "zustand";
import type { Meeting } from "@/lib/types";

interface MeetingStore {
  meetings: Meeting[];
  loading: boolean;
  error: string | null;

  setMeetings: (meetings: Meeting[]) => void;
  setLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  removeMeeting: (id: string) => void;
  updateMeeting: (meeting: Meeting) => void;
}

export const useMeetingStore = create<MeetingStore>((set) => ({
  meetings: [],
  loading: false,
  error: null,

  setMeetings: (meetings) => set({ meetings, error: null }),
  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error, loading: false }),
  removeMeeting: (id) =>
    set((state) => ({
      meetings: state.meetings.filter((m) => m.id !== id),
    })),
  updateMeeting: (meeting) =>
    set((state) => ({
      meetings: state.meetings.map((m) =>
        m.id === meeting.id ? meeting : m,
      ),
    })),
}));
