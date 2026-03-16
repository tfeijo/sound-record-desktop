"use client";

import { useCallback, useEffect, useState } from "react";
import {
  listSpeakers,
  createSpeaker,
  updateSpeaker,
  deleteSpeaker,
} from "@/lib/api";
import type { SpeakerProfile } from "@/lib/types";

export function SpeakerManager() {
  const [speakers, setSpeakers] = useState<SpeakerProfile[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editName, setEditName] = useState("");

  const fetchSpeakers = useCallback(async () => {
    try {
      const data = await listSpeakers();
      setSpeakers(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load speakers");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchSpeakers();
  }, [fetchSpeakers]);

  const handleAdd = async () => {
    const trimmed = newName.trim();
    if (!trimmed) return;

    setError(null);
    try {
      const profile = await createSpeaker(trimmed);
      setSpeakers((prev) => [...prev, profile]);
      setNewName("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to add speaker");
    }
  };

  const handleUpdate = async (id: string) => {
    const trimmed = editName.trim();
    if (!trimmed) {
      setEditingId(null);
      return;
    }

    setError(null);
    try {
      const updated = await updateSpeaker(id, trimmed);
      setSpeakers((prev) =>
        prev.map((s) => (s.id === id ? updated : s)),
      );
      setEditingId(null);
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Failed to update speaker",
      );
    }
  };

  const handleDelete = async (id: string, name: string) => {
    if (!window.confirm(`Delete speaker profile "${name}"?`)) return;

    setError(null);
    try {
      await deleteSpeaker(id);
      setSpeakers((prev) => prev.filter((s) => s.id !== id));
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Failed to delete speaker",
      );
    }
  };

  const startEditing = (profile: SpeakerProfile) => {
    setEditingId(profile.id);
    setEditName(profile.name);
  };

  if (loading) {
    return (
      <div className="py-4 text-center text-sm text-neutral-500">
        Loading speaker profiles...
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {error && (
        <div className="rounded-lg border border-red-800/50 bg-red-950/30 p-3">
          <p className="text-sm text-red-400">{error}</p>
        </div>
      )}

      {/* Add new speaker */}
      <div className="flex gap-2">
        <input
          type="text"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") handleAdd();
          }}
          placeholder="Add speaker name..."
          className="flex-1 rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-neutral-200 placeholder-neutral-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500/50"
          aria-label="New speaker name"
        />
        <button
          onClick={handleAdd}
          disabled={!newName.trim()}
          className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-blue-500 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Add
        </button>
      </div>

      {/* Speaker list */}
      {speakers.length === 0 ? (
        <p className="py-4 text-center text-sm text-neutral-500">
          No speaker profiles yet. Assign names to speakers in transcripts or
          add them manually above.
        </p>
      ) : (
        <ul className="divide-y divide-neutral-800 rounded-lg border border-neutral-800">
          {speakers.map((profile) => (
            <li
              key={profile.id}
              className="flex items-center justify-between px-4 py-3"
            >
              {editingId === profile.id ? (
                <input
                  type="text"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") handleUpdate(profile.id);
                    if (e.key === "Escape") setEditingId(null);
                  }}
                  onBlur={() => handleUpdate(profile.id)}
                  autoFocus
                  className="flex-1 rounded border border-neutral-600 bg-neutral-800 px-2 py-1 text-sm text-neutral-200 outline-none focus:border-blue-500"
                  aria-label={`Edit name for ${profile.name}`}
                />
              ) : (
                <div className="flex flex-col">
                  <span className="text-sm font-medium text-neutral-200">
                    {profile.name}
                  </span>
                  {profile.embeddingPath && (
                    <span className="text-xs text-neutral-500">
                      Voice enrolled
                    </span>
                  )}
                </div>
              )}

              <div className="flex items-center gap-2">
                {editingId !== profile.id && (
                  <button
                    onClick={() => startEditing(profile)}
                    className="rounded px-2 py-1 text-xs text-neutral-400 transition-colors hover:bg-neutral-800 hover:text-neutral-200"
                    aria-label={`Edit ${profile.name}`}
                  >
                    Edit
                  </button>
                )}
                <button
                  onClick={() => handleDelete(profile.id, profile.name)}
                  className="rounded px-2 py-1 text-xs text-red-400 transition-colors hover:bg-red-950/50 hover:text-red-300"
                  aria-label={`Delete ${profile.name}`}
                >
                  Delete
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
