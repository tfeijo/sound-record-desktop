import { create } from "zustand";

interface SettingsStore {
  settings: Record<string, string>;
  loading: boolean;
  error: string | null;

  setSettings: (settings: Record<string, string>) => void;
  setLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  updateSetting: (key: string, value: string) => void;
}

export const useSettingsStore = create<SettingsStore>((set) => ({
  settings: {},
  loading: false,
  error: null,

  setSettings: (settings) => set({ settings, error: null }),
  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error, loading: false }),
  updateSetting: (key, value) =>
    set((state) => ({
      settings: { ...state.settings, [key]: value },
    })),
}));
