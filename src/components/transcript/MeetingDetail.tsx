"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { getMeeting, regenerateSummary } from "@/lib/api";
import { TranscriptViewer } from "./TranscriptViewer";
import { ReportPreview } from "../meeting/ReportPreview";
import type { Meeting, MeetingSummary, TranscriptionResult } from "@/lib/types";

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

type Tab = "summary" | "transcript";

interface MeetingDetailProps {
  meetingId: string;
}

export function MeetingDetail({ meetingId }: MeetingDetailProps) {
  const [meeting, setMeeting] = useState<Meeting | null>(null);
  const [transcript, setTranscript] = useState<TranscriptionResult | null>(null);
  const [summary, setSummary] = useState<MeetingSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [regenerating, setRegenerating] = useState(false);
  const [activeTab, setActiveTab] = useState<Tab>("summary");

  const loadMeeting = useCallback(async () => {
    try {
      const m = await getMeeting(meetingId);
      setMeeting(m);

      // Parse transcript and summary independently so one bad field
      // does not prevent the other from loading
      if (m.transcriptJson) {
        try {
          const parsed = JSON.parse(m.transcriptJson);
          if (parsed && Array.isArray(parsed.segments)) {
            setTranscript(parsed as TranscriptionResult);
          }
        } catch {
          // Malformed transcript JSON — skip silently
        }
      }

      if (m.summaryJson) {
        try {
          const parsed = JSON.parse(m.summaryJson);
          if (parsed && typeof parsed.summary === "string") {
            setSummary(parsed as MeetingSummary);
          }
        } catch {
          // Malformed summary JSON — skip silently
        }
      }

      return m;
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load meeting");
      return null;
    } finally {
      setLoading(false);
    }
  }, [meetingId]);

  useEffect(() => {
    loadMeeting();
  }, [loadMeeting]);

  // Default to transcript tab if no summary available
  useEffect(() => {
    if (!loading && !summary && transcript) {
      setActiveTab("transcript");
    }
  }, [loading, summary, transcript]);

  const handleRegenerate = async () => {
    if (regenerating) return;
    setRegenerating(true);
    setError(null);
    try {
      await regenerateSummary(meetingId);
      // Poll until meeting status returns to "done" (or error/timeout)
      const maxAttempts = 30; // ~60 seconds max
      let attempts = 0;
      const poll = setInterval(async () => {
        attempts++;
        try {
          const m = await getMeeting(meetingId);
          if (m.status === "done" || m.status === "error" || attempts >= maxAttempts) {
            clearInterval(poll);
            await loadMeeting();
            setRegenerating(false);
            if (m.summaryJson) {
              setActiveTab("summary");
            }
          }
        } catch {
          clearInterval(poll);
          setRegenerating(false);
        }
      }, 2000);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to regenerate");
      setRegenerating(false);
    }
  };

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

  const hasSummary = summary !== null;
  const hasTranscript = transcript !== null;

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
          <div className="flex items-center gap-2">
            <StatusBadge status={meeting.status} />
          </div>
        </div>

        {/* Action buttons */}
        <div className="mb-6 flex items-center gap-3">
          {hasTranscript && (
            <button
              onClick={handleRegenerate}
              disabled={regenerating}
              className="rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-1.5 text-sm text-neutral-300 transition-colors hover:bg-neutral-700 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {regenerating ? "Regenerating..." : "Regenerate Summary"}
            </button>
          )}
          {meeting.obsidianPath && (
            <a
              href={`obsidian://open?path=${encodeURIComponent(meeting.obsidianPath)}`}
              className="rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-1.5 text-sm text-neutral-300 transition-colors hover:bg-neutral-700"
            >
              Open in Obsidian
            </a>
          )}
        </div>

        {/* Error */}
        {meeting.error && (
          <div className="mb-6 rounded-lg border border-red-800/50 bg-red-950/30 p-4">
            <p className="text-sm text-red-400">{meeting.error}</p>
          </div>
        )}

        {/* Tabs */}
        {(hasSummary || hasTranscript) && (
          <>
            <div className="mb-4 flex border-b border-neutral-800">
              {hasSummary && (
                <button
                  onClick={() => setActiveTab("summary")}
                  className={`px-4 py-2 text-sm font-medium transition-colors ${
                    activeTab === "summary"
                      ? "border-b-2 border-blue-500 text-blue-400"
                      : "text-neutral-500 hover:text-neutral-300"
                  }`}
                >
                  Summary
                </button>
              )}
              {hasTranscript && (
                <button
                  onClick={() => setActiveTab("transcript")}
                  className={`px-4 py-2 text-sm font-medium transition-colors ${
                    activeTab === "transcript"
                      ? "border-b-2 border-blue-500 text-blue-400"
                      : "text-neutral-500 hover:text-neutral-300"
                  }`}
                >
                  Transcript
                </button>
              )}
            </div>

            {activeTab === "summary" && summary && (
              <ReportPreview summary={summary} />
            )}

            {activeTab === "transcript" && transcript && (
              <TranscriptViewer
                transcript={transcript}
                meetingId={meetingId}
              />
            )}
          </>
        )}

        {/* Status-specific messages when no content yet */}
        {!hasSummary && !hasTranscript && (
          <>
            {meeting.status === "transcribing" && (
              <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
                <p className="text-neutral-400">Transcribing audio...</p>
                <p className="mt-1 text-sm text-neutral-500">
                  This may take a few minutes depending on the recording length.
                </p>
              </div>
            )}
            {meeting.status === "summarizing" && (
              <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
                <p className="text-neutral-400">Generating summary...</p>
              </div>
            )}
            {meeting.status === "recording" && (
              <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
                <p className="text-neutral-400">Recording in progress...</p>
              </div>
            )}
            {meeting.status === "done" && (
              <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-8 text-center">
                <p className="text-neutral-500">No content available.</p>
              </div>
            )}
          </>
        )}
      </div>
    </main>
  );
}
