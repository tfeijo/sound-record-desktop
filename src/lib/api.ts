import type {
  RecordingStartResponse,
  RecordingStopResponse,
  RecordingStatusResponse,
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

export function stopRecording(): Promise<RecordingStopResponse> {
  return request<RecordingStopResponse>("/api/recording/stop", {
    method: "POST",
  });
}

export function getRecordingStatus(): Promise<RecordingStatusResponse> {
  return request<RecordingStatusResponse>("/api/recording/status");
}
