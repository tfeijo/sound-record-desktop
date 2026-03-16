"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { useRecordingStore } from "@/stores/recordingStore";
import type { WebSocketMessage } from "@/lib/types";

const WS_URL = "ws://localhost:9876/ws";
const MAX_RECONNECT_DELAY = 30000;
const BASE_RECONNECT_DELAY = 1000;

export function useWebSocket() {
  const [isConnected, setIsConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectAttemptRef = useRef(0);
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);

  const store = useRecordingStore;

  const handleMessage = useCallback(
    (event: MessageEvent) => {
      try {
        const msg = JSON.parse(event.data as string) as WebSocketMessage;
        const s = store.getState();

        switch (msg.type) {
          case "recording:started":
            s.setState("recording");
            if (
              msg.payload &&
              typeof msg.payload === "object" &&
              "meetingId" in msg.payload
            ) {
              s.setMeetingId(
                (msg.payload as { meetingId: string }).meetingId,
              );
            }
            break;
          case "recording:stopped":
            s.setState("idle");
            s.setAudioLevel(0);
            break;
          case "recording:level":
            if (
              msg.payload &&
              typeof msg.payload === "object" &&
              "level" in msg.payload
            ) {
              s.setAudioLevel(
                (msg.payload as { level: number }).level,
              );
            }
            break;
          case "pipeline:processing":
            s.setState("processing");
            break;
          case "pipeline:done":
            s.setState("done");
            break;
          case "pipeline:error":
            s.setError(
              msg.payload && typeof msg.payload === "object" && "message" in msg.payload
                ? (msg.payload as { message: string }).message
                : "Pipeline error",
            );
            break;
        }
      } catch {
        // ignore malformed messages
      }
    },
    [store],
  );

  const connect = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;

    try {
      const ws = new WebSocket(WS_URL);
      wsRef.current = ws;

      ws.onopen = () => {
        if (!mountedRef.current) return;
        setIsConnected(true);
        reconnectAttemptRef.current = 0;
      };

      ws.onclose = () => {
        if (!mountedRef.current) return;
        setIsConnected(false);
        wsRef.current = null;

        // Exponential backoff reconnect
        const delay = Math.min(
          BASE_RECONNECT_DELAY * Math.pow(2, reconnectAttemptRef.current),
          MAX_RECONNECT_DELAY,
        );
        reconnectAttemptRef.current += 1;
        reconnectTimerRef.current = setTimeout(connect, delay);
      };

      ws.onerror = () => {
        // onclose will fire after onerror, handling reconnect
      };

      ws.onmessage = handleMessage;
    } catch {
      // connection failed, onclose will handle retry
    }
  }, [handleMessage]);

  const send = useCallback((msg: WebSocketMessage) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(msg));
    }
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    connect();

    return () => {
      mountedRef.current = false;
      if (reconnectTimerRef.current) {
        clearTimeout(reconnectTimerRef.current);
      }
      if (wsRef.current) {
        wsRef.current.close();
        wsRef.current = null;
      }
    };
  }, [connect]);

  return { isConnected, send };
}
