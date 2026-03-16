"use client";

import { useCallback, useEffect } from "react";
import { useMeetingStore } from "@/stores/meetingStore";
import { listMeetings, deleteMeeting } from "@/lib/api";

export function useMeetings() {
  const meetings = useMeetingStore((s) => s.meetings);
  const loading = useMeetingStore((s) => s.loading);
  const error = useMeetingStore((s) => s.error);

  const fetchMeetings = useCallback(async () => {
    const store = useMeetingStore.getState();
    store.setLoading(true);
    try {
      const data = await listMeetings();
      useMeetingStore.getState().setMeetings(data);
    } catch (err) {
      useMeetingStore.getState().setError(
        err instanceof Error ? err.message : "Failed to load meetings",
      );
    } finally {
      useMeetingStore.getState().setLoading(false);
    }
  }, []);

  const handleDelete = useCallback(async (id: string) => {
    try {
      await deleteMeeting(id);
      useMeetingStore.getState().removeMeeting(id);
    } catch (err) {
      useMeetingStore.getState().setError(
        err instanceof Error ? err.message : "Failed to delete meeting",
      );
    }
  }, []);

  useEffect(() => {
    fetchMeetings();
  }, [fetchMeetings]);

  return { meetings, loading, error, refetch: fetchMeetings, deleteMeeting: handleDelete };
}
