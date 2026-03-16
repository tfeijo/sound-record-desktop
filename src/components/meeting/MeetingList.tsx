"use client";

import { useMeetings } from "@/hooks/useMeetings";
import { MeetingCard } from "./MeetingCard";

export function MeetingList() {
  const { meetings, loading, error, deleteMeeting } = useMeetings();

  if (loading && meetings.length === 0) {
    return (
      <div className="py-8 text-center text-sm text-neutral-500">
        Loading meetings...
      </div>
    );
  }

  if (error) {
    return (
      <div className="py-8 text-center text-sm text-red-400">
        {error}
      </div>
    );
  }

  if (meetings.length === 0) {
    return (
      <div className="py-8 text-center text-sm text-neutral-500">
        No meetings yet. Start recording to create your first meeting.
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      {meetings.map((meeting) => (
        <MeetingCard
          key={meeting.id}
          meeting={meeting}
          onDelete={deleteMeeting}
        />
      ))}
    </div>
  );
}
