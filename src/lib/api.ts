import type {
  Meeting,
  RecordingStartResponse,
  RecordingStopResponse,
  RecordingStatusResponse,
  SpeakerProfile,
} from "./types";

const API_BASE = "http://localhost:9876";

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    throw new Error(`API error: ${res.status} ${res.statusText}`);
  }
  return res.json() as Promise<T>;
}

export function startRecording(): Promise<RecordingStartResponse> {
  return request<RecordingStartResponse>("/api/recording/start", {
    method: "POST",
  });
}

export interface StopRecordingBody {
  micPath?: string;
  systemPath?: string;
  duration?: number;
}

export function stopRecording(
  body?: StopRecordingBody,
): Promise<RecordingStopResponse> {
  return request<RecordingStopResponse>("/api/recording/stop", {
    method: "POST",
    body: body ? JSON.stringify(body) : undefined,
  });
}

export function getRecordingStatus(): Promise<RecordingStatusResponse> {
  return request<RecordingStatusResponse>("/api/recording/status");
}

export function getMeeting(id: string): Promise<Meeting> {
  return request<Meeting>(`/api/meetings/${id}`);
}

export function listMeetings(
  limit = 50,
  offset = 0,
): Promise<Meeting[]> {
  return request<Meeting[]>(`/api/meetings?limit=${limit}&offset=${offset}`);
}

export function deleteMeeting(id: string): Promise<void> {
  return request<void>(`/api/meetings/${id}`, { method: "DELETE" });
}

export function getSettings(): Promise<Record<string, string>> {
  return request<Record<string, string>>("/api/settings");
}

export function updateSettings(
  settings: Record<string, string>,
): Promise<Record<string, string>> {
  return request<Record<string, string>>("/api/settings", {
    method: "PUT",
    body: JSON.stringify(settings),
  });
}

// --- Speaker Profiles ---

export function listSpeakers(): Promise<SpeakerProfile[]> {
  return request<SpeakerProfile[]>("/api/speakers");
}

export function createSpeaker(name: string): Promise<SpeakerProfile> {
  return request<SpeakerProfile>("/api/speakers", {
    method: "POST",
    body: JSON.stringify({ name }),
  });
}

export function updateSpeaker(
  id: string,
  name: string,
): Promise<SpeakerProfile> {
  return request<SpeakerProfile>(`/api/speakers/${id}`, {
    method: "PUT",
    body: JSON.stringify({ name }),
  });
}

export function deleteSpeaker(id: string): Promise<void> {
  return request<void>(`/api/speakers/${id}`, { method: "DELETE" });
}

export interface EnrollSpeakerBody {
  meetingId: string;
  speaker: string;
  name: string;
  start: number;
  end: number;
}

export function enrollSpeaker(
  body: EnrollSpeakerBody,
): Promise<{ profile: SpeakerProfile; audioPath: string }> {
  return request<{ profile: SpeakerProfile; audioPath: string }>(
    "/api/speakers/enroll",
    {
      method: "POST",
      body: JSON.stringify(body),
    },
  );
}

export function regenerateSummary(
  id: string,
): Promise<{ status: string }> {
  return request<{ status: string }>(`/api/meetings/${id}/regenerate`, {
    method: "POST",
  });
}
