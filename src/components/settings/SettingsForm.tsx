"use client";

import { useCallback, useEffect, useState } from "react";
import { useSettingsStore } from "@/stores/settingsStore";
import { getSettings, updateSettings } from "@/lib/api";

const WHISPER_MODELS = [
  { value: "tiny", label: "Tiny (fastest, lowest quality)" },
  { value: "base", label: "Base (recommended)" },
  { value: "small", label: "Small" },
  { value: "medium", label: "Medium" },
  { value: "large-v2", label: "Large v2 (slowest, highest quality)" },
];

const LANGUAGES = [
  { value: "", label: "Auto-detect" },
  { value: "en", label: "English" },
  { value: "pt", label: "Portuguese" },
  { value: "es", label: "Spanish" },
  { value: "fr", label: "French" },
  { value: "de", label: "German" },
  { value: "ja", label: "Japanese" },
  { value: "zh", label: "Chinese" },
  { value: "ko", label: "Korean" },
];

export function SettingsForm() {
  const settings = useSettingsStore((s) => s.settings);
  const loading = useSettingsStore((s) => s.loading);
  const error = useSettingsStore((s) => s.error);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  const fetchSettings = useCallback(async () => {
    useSettingsStore.getState().setLoading(true);
    try {
      const data = await getSettings();
      useSettingsStore.getState().setSettings(data);
    } catch (err) {
      useSettingsStore.getState().setError(
        err instanceof Error ? err.message : "Failed to load settings",
      );
    } finally {
      useSettingsStore.getState().setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchSettings();
  }, [fetchSettings]);

  const handleChange = (key: string, value: string) => {
    useSettingsStore.getState().updateSetting(key, value);
    setSaved(false);
  };

  const handleSave = async () => {
    setSaving(true);
    setSaved(false);
    useSettingsStore.getState().setError(null);
    try {
      await updateSettings(settings);
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (err) {
      useSettingsStore.getState().setError(
        err instanceof Error ? err.message : "Failed to save settings",
      );
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <div className="py-8 text-center text-sm text-neutral-500">
        Loading settings...
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {error && (
        <div className="rounded-lg border border-red-800/50 bg-red-950/30 p-3">
          <p className="text-sm text-red-400">{error}</p>
        </div>
      )}

      {/* User Name */}
      <div>
        <label htmlFor="user_name" className="mb-1 block text-sm font-medium text-neutral-300">
          Your Name
        </label>
        <p className="mb-2 text-xs text-neutral-500">
          Used to label your speech in transcripts
        </p>
        <input
          id="user_name"
          type="text"
          value={settings.user_name ?? ""}
          onChange={(e) => handleChange("user_name", e.target.value)}
          placeholder="User"
          className="w-full rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-neutral-200 placeholder-neutral-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500/50"
        />
      </div>

      {/* Obsidian Vault Path */}
      <div>
        <label htmlFor="obsidian_vault_path" className="mb-1 block text-sm font-medium text-neutral-300">
          Obsidian Vault Path
        </label>
        <p className="mb-2 text-xs text-neutral-500">
          Full path to your Obsidian vault directory. Meeting reports will be saved to a Meetings/ subfolder.
        </p>
        <div className="flex gap-2">
          <input
            id="obsidian_vault_path"
            type="text"
            value={settings.obsidian_vault_path ?? ""}
            onChange={(e) => handleChange("obsidian_vault_path", e.target.value)}
            placeholder="/Users/you/Documents/MyVault"
            className="flex-1 rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-neutral-200 placeholder-neutral-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500/50"
          />
          <button
            type="button"
            onClick={async () => {
              try {
                const { open } = await import("@tauri-apps/plugin-dialog");
                const selected = await open({ directory: true, multiple: false, title: "Select Obsidian Vault" });
                if (selected) {
                  handleChange("obsidian_vault_path", selected as string);
                }
              } catch {
                // Not running in Tauri (browser dev mode) — ignore
              }
            }}
            className="rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-neutral-400 transition-colors hover:bg-neutral-700 hover:text-neutral-200"
          >
            Browse…
          </button>
        </div>
      </div>

      {/* Whisper Model Size */}
      <div>
        <label htmlFor="whisper_model_size" className="mb-1 block text-sm font-medium text-neutral-300">
          Whisper Model Size
        </label>
        <p className="mb-2 text-xs text-neutral-500">
          Larger models are more accurate but slower and use more memory
        </p>
        <select
          id="whisper_model_size"
          value={settings.whisper_model_size ?? "base"}
          onChange={(e) => handleChange("whisper_model_size", e.target.value)}
          className="w-full rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-neutral-200 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500/50"
        >
          {WHISPER_MODELS.map((m) => (
            <option key={m.value} value={m.value}>
              {m.label}
            </option>
          ))}
        </select>
      </div>

      {/* Language */}
      <div>
        <label htmlFor="language" className="mb-1 block text-sm font-medium text-neutral-300">
          Language
        </label>
        <p className="mb-2 text-xs text-neutral-500">
          Set the expected language for better transcription accuracy, or auto-detect
        </p>
        <select
          id="language"
          value={settings.language ?? ""}
          onChange={(e) => handleChange("language", e.target.value)}
          className="w-full rounded-lg border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-neutral-200 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500/50"
        >
          {LANGUAGES.map((l) => (
            <option key={l.value} value={l.value}>
              {l.label}
            </option>
          ))}
        </select>
      </div>

      {/* Auto-record */}
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-neutral-300">
            Auto-record on Google Meet
          </p>
          <p className="text-xs text-neutral-500">
            Automatically start recording when a Google Meet is detected
          </p>
        </div>
        <button
          role="switch"
          aria-label="Auto-record on Google Meet"
          aria-checked={settings.auto_record === "true"}
          onClick={() =>
            handleChange(
              "auto_record",
              settings.auto_record === "true" ? "false" : "true",
            )
          }
          className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500/50 ${
            settings.auto_record === "true"
              ? "bg-blue-600"
              : "bg-neutral-700"
          }`}
        >
          <span
            className={`inline-block h-4 w-4 rounded-full bg-white transition-transform ${
              settings.auto_record === "true"
                ? "translate-x-6"
                : "translate-x-1"
            }`}
          />
        </button>
      </div>

      {/* Save button */}
      <div className="flex items-center gap-3 pt-2">
        <button
          onClick={handleSave}
          disabled={saving}
          className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-blue-500 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {saving ? "Saving..." : "Save Settings"}
        </button>
        {saved && (
          <span role="status" className="text-sm text-emerald-400">Settings saved</span>
        )}
      </div>
    </div>
  );
}
