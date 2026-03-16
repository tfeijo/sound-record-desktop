export type RecordingState = "idle" | "recording" | "processing" | "done" | "error";

export interface WebSocketMessage {
  type: string;
  payload?: unknown;
}

export interface Meeting {
  id: string;
  title: string;
  startedAt: string;
  endedAt?: string;
  status: RecordingState;
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
