"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getMeeting } from "@/lib/api";
import { TranscriptViewer } from "./TranscriptViewer";
import type { Meeting, TranscriptionResult } from "@/lib/types";

function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

function StatusBadge({ status }: { status: string }) {
  const colors: Record<string, string> = {
    recording: "bg-red-500/20 text-red-400",
    transcribing: "bg-amber-500/20 text-amber-400",
    summarizing: "bg-blue-500/20 text-blue-400",
    done: "bg-emerald-500/20 text-emerald-400",
    error: "bg-red-500/20 text-red-400",
  };
  return (
    <span
      className={`rounded-full px-3 py-1 text-xs font-medium ${colors[status] ?? "bg-neutral-800 text-neutral-400"}`}
    >
      {status}
    </span>
  );
}

interface MeetingDetailProps {
  meetingId: string;
}

export function MeetingDetail({ meetingId }: MeetingDetailProps) {
  const [meeting, setMeeting] = useState<Meeting | null>(null);
  const [transcript, setTranscript] = useState<TranscriptionResult | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const m = await getMeeting(meetingId);
        setMeeting(m);

        if (m.transcriptJson) {
          const parsed = JSON.parse(m.transcriptJson) as TranscriptionResult;
          setTranscript(parsed);
        }
      } catch (err) {
        setError(err instanceof Error ? err.message : "Failed to load meeting");
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [meetingId]);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-neutral-950 text-white">
        <p className="text-neutral-500">Loading...</p>
      </main>
    );
  }

  if (error || !meeting) {
    return (
      <main className="flex min-h-screen flex-col items-center justify-center gap-4 bg-neutral-950 text-white">
        <p className="text-red-400">{error ?? "Meeting not found"}</p>
        <Link
          href="/"
          className="text-sm text-neutral-400 hover:text-neutral-200"
        >
          Back to dashboard
        </Link>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-neutral-950 text-white">
      <div className="mx-auto max-w-4xl px-6 py-8">
        {/* Header */}
        <div className="mb-6 flex items-start justify-between">
          <div>
            <Link
              href="/"
              className="mb-2 inline-block text-sm text-neutral-500 hover:text-neutral-300"
            >
              &larr; Back
            </Link>
            <h1 className="text-2xl font-bold">{meeting.title}</h1>
            <div className="mt-1 flex items-center gap-3 text-sm text-neutral-400">
              <span>{meeting.date}</span>
              {meeting.durationSeconds > 0 && (
                <span>{formatDuration(meeting.durationSeconds)}</span>
              )}
              {meeting.speakerCount > 0 && (
                <span>
                  {meeting.speakerCount} speaker
                  {meeting.speakerCount !== 1 ? "s" : ""}
                </span>
              )}
            </div>
          </div>
          <StatusBadge status={meeting.status} />
        </div>

        {/* Error */}
        {meeting.error && (
          <div className="mb-6 rounded-lg border border-red-800/50 bg-red-950/30 p-4">
            <p className="text-sm text-red-400">{meeting.error}</p>
          </div>
        )}

        {/* Transcript */}
        {transcript ? (
          <section>
            <h2 className="mb-3 text-lg font-semibold text-neutral-200">
              Transcript
            </h2>
            <TranscriptViewer transcript={transcript} />
          </section>
        ) : meeting.status === "transcribing" ? (
          <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
            <p className="text-neutral-400">Transcribing audio...</p>
            <p className="mt-1 text-sm text-neutral-500">
              This may take a few minutes depending on the recording length.
            </p>
          </div>
        ) : meeting.status === "recording" ? (
          <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
            <p className="text-neutral-400">Recording in progress...</p>
          </div>
        ) : (
          <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
            <p className="text-neutral-500">No transcript available.</p>
          </div>
        )}
      </div>
    </main>
  );
}
