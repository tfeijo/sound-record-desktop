export type RecordingState = "idle" | "recording" | "processing" | "done" | "error";

export type MeetingStatus = "recording" | "transcribing" | "summarizing" | "done" | "error";

export interface WebSocketMessage {
  type: string;
  payload?: unknown;
}

export interface TranscriptSegment {
  speaker: string;
  start: number;
  end: number;
  text: string;
  confidence: number;
}

export interface SpeakerInfo {
  id: string;
  source: string;
  total_duration: number;
}

export interface TranscriptionResult {
  status: string;
  duration_seconds: number;
  segments: TranscriptSegment[];
  speakers: SpeakerInfo[];
  language_detected: string;
  warnings: string[];
  error?: string;
}

export interface Meeting {
  id: string;
  title: string;
  date: string;
  startTime?: string;
  endTime?: string;
  durationSeconds: number;
  speakerCount: number;
  status: MeetingStatus;
  audioPath?: string;
  micPath?: string;
  systemPath?: string;
  transcriptJson?: string;
  summaryJson?: string;
  obsidianPath?: string;
  meetUrl?: string;
  error?: string;
  createdAt: string;
  updatedAt: string;
}

export interface MeetingSummary {
  title: string;
  summary: string;
  decisions: string[];
  action_items: ActionItem[];
  topics: Topic[];
}

export interface ActionItem {
  description: string;
  assignee: string;
}

export interface Topic {
  title: string;
  summary: string;
}

export interface SpeakerProfile {
  id: string;
  name: string;
  embeddingPath?: string;
  createdAt: string;
}

export interface RecordingStartResponse {
  meetingId: string;
  status: RecordingState;
}

export interface RecordingStopResponse {
  status: RecordingState;
}

export interface RecordingStatusResponse {
  state: RecordingState;
  meetingId: string | null;
  duration: number;
}
