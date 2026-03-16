"use client";

import { useCallback, useRef, useState } from "react";
import { enrollSpeaker } from "@/lib/api";

interface SpeakerLabelProps {
  speaker: string;
  meetingId: string;
  start: number;
  end: number;
  color: string;
  onRenamed: (oldName: string, newName: string) => void;
}

export function SpeakerLabel({
  speaker,
  meetingId,
  start,
  end,
  color,
  onRenamed,
}: SpeakerLabelProps) {
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const isGenericLabel = /^(Speaker \d+|Participant \d+)$/.test(speaker);

  const handleClick = useCallback(() => {
    if (!isGenericLabel) return;
    setEditing(true);
    // Focus after render
    setTimeout(() => inputRef.current?.focus(), 0);
  }, [isGenericLabel]);

  const handleSave = useCallback(
    async (newName: string) => {
      const trimmed = newName.trim();
      if (!trimmed || trimmed === speaker) {
        setEditing(false);
        return;
      }

      setSaving(true);
      try {
        await enrollSpeaker({
          meetingId,
          speaker,
          name: trimmed,
          start,
          end,
        });
        onRenamed(speaker, trimmed);
      } catch {
        // Silently fail — name stays as-is
      } finally {
        setSaving(false);
        setEditing(false);
      }
    },
    [meetingId, speaker, start, end, onRenamed],
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === "Enter") {
        handleSave(e.currentTarget.value);
      } else if (e.key === "Escape") {
        setEditing(false);
      }
    },
    [handleSave],
  );

  const handleBlur = useCallback(
    (e: React.FocusEvent<HTMLInputElement>) => {
      handleSave(e.currentTarget.value);
    },
    [handleSave],
  );

  if (editing) {
    return (
      <input
        ref={inputRef}
        defaultValue=""
        placeholder={speaker}
        disabled={saving}
        onKeyDown={handleKeyDown}
        onBlur={handleBlur}
        className="w-full rounded border border-neutral-600 bg-neutral-800 px-1 py-0 text-sm text-neutral-200 outline-none focus:border-blue-500"
        aria-label={`Rename ${speaker}`}
      />
    );
  }

  if (isGenericLabel) {
    return (
      <button
        onClick={handleClick}
        className={`text-sm font-medium ${color} cursor-pointer underline decoration-dotted underline-offset-2 hover:brightness-125`}
        title="Click to assign a name"
        aria-label={`Assign name to ${speaker}`}
      >
        {speaker}
      </button>
    );
  }

  return (
    <span className={`text-sm font-medium ${color}`}>{speaker}</span>
  );
}
