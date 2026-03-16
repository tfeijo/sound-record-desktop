"use client";

import { useCallback, useEffect } from "react";
import { useMeetingStore } from "@/stores/meetingStore";
import { listMeetings, deleteMeeting } from "@/lib/api";

export function useMeetings() {
  const { meetings, loading, error, setMeetings, setLoading, setError, removeMeeting } =
    useMeetingStore();

  const fetchMeetings = useCallback(async () => {
    setLoading(true);
    try {
      const data = await listMeetings();
      setMeetings(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load meetings");
    } finally {
      setLoading(false);
    }
  }, [setMeetings, setLoading, setError]);

  const handleDelete = useCallback(
    async (id: string) => {
      try {
        await deleteMeeting(id);
        removeMeeting(id);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Failed to delete meeting");
      }
    },
    [removeMeeting, setError],
  );

  useEffect(() => {
    fetchMeetings();
  }, [fetchMeetings]);

  return { meetings, loading, error, refetch: fetchMeetings, deleteMeeting: handleDelete };
}
