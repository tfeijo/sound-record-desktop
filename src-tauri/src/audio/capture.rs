use std::fs;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use super::mic_audio::MicRecorder;
use super::system_audio::SystemRecorder;

#[derive(Clone, Serialize)]
struct LevelPayload {
    level: f32,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordingStartedPayload {
    meeting_id: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordingStoppedPayload {
    meeting_id: String,
    mic_path: String,
    system_path: String,
}

/// Result returned from stop_recording containing file paths.
pub struct StopResult {
    pub mic_path: String,
    pub system_path: String,
}

impl std::fmt::Display for StopResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "mic: {}, system: {}", self.mic_path, self.system_path)
    }
}

/// Manages audio capture for a recording session.
/// Orchestrates both microphone and system audio recorders.
pub struct AudioCapture {
    mic_recorder: Mutex<MicRecorder>,
    system_recorder: Mutex<SystemRecorder>,
    meeting_id: Mutex<Option<String>>,
}

impl AudioCapture {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            mic_recorder: Mutex::new(MicRecorder::new()?),
            system_recorder: Mutex::new(SystemRecorder::new()?),
            meeting_id: Mutex::new(None),
        })
    }

    /// Start recording both microphone and system audio for a given meeting.
    pub fn start_recording(&self, app_handle: AppHandle, meeting_id: String) -> Result<(), String> {
        let recordings_dir = recordings_directory()?;
        fs::create_dir_all(&recordings_dir)
            .map_err(|e| format!("Failed to create recordings directory: {e}"))?;

        let mic_path = recordings_dir.join(format!("meeting_{}_mic.wav", meeting_id));
        let system_path = recordings_dir.join(format!("meeting_{}_system.wav", meeting_id));

        // Store meeting_id
        {
            let mut mid = self.meeting_id.lock().map_err(|e| e.to_string())?;
            *mid = Some(meeting_id.clone());
        }

        // Use atomics to hold latest levels from each source so we can combine them.
        // We store f32 bits as u32 for atomic access.
        let mic_level = std::sync::Arc::new(AtomicU32::new(0));
        let system_level = std::sync::Arc::new(AtomicU32::new(0));

        // Mic level callback
        let mic_level_w = mic_level.clone();
        let app_for_mic = app_handle.clone();
        let system_level_r1 = system_level.clone();
        let mic_callback = move |level: f32| {
            mic_level_w.store(level.to_bits(), Ordering::Relaxed);
            let sys = f32::from_bits(system_level_r1.load(Ordering::Relaxed));
            let combined = level.max(sys);
            let _ = app_for_mic.emit("recording:level", LevelPayload { level: combined });
        };

        // System level callback
        let system_level_w = system_level.clone();
        let app_for_sys = app_handle.clone();
        let mic_level_r1 = mic_level.clone();
        let system_callback = move |level: f32| {
            system_level_w.store(level.to_bits(), Ordering::Relaxed);
            let mic = f32::from_bits(mic_level_r1.load(Ordering::Relaxed));
            let combined = level.max(mic);
            let _ = app_for_sys.emit("recording:level", LevelPayload { level: combined });
        };

        // Start mic recorder
        {
            let mut recorder = self.mic_recorder.lock().map_err(|e| e.to_string())?;
            recorder.start(mic_path, mic_callback)?;
        }

        // Start system recorder
        {
            let mut recorder = self.system_recorder.lock().map_err(|e| e.to_string())?;
            if let Err(e) = recorder.start(system_path, system_callback) {
                // If system audio fails to start, log but don't fail the whole recording.
                // Mic-only is still useful.
                log::warn!("System audio recorder failed to start: {}. Continuing with mic only.", e);
            }
        }

        let _ = app_handle.emit(
            "recording:started",
            RecordingStartedPayload {
                meeting_id: meeting_id.clone(),
            },
        );

        log::info!("AudioCapture: recording started for meeting {}", meeting_id);
        Ok(())
    }

    /// Stop the current recording and return file paths for both mic and system audio.
    pub fn stop_recording(&self, app_handle: &AppHandle) -> Result<StopResult, String> {
        // Stop mic
        let mic_path = {
            let mut recorder = self.mic_recorder.lock().map_err(|e| e.to_string())?;
            recorder.stop()?
        };

        // Stop system (best-effort)
        let system_path = {
            let mut recorder = self.system_recorder.lock().map_err(|e| e.to_string())?;
            match recorder.stop() {
                Ok(p) => p.to_string_lossy().to_string(),
                Err(e) => {
                    log::warn!("System audio stop failed: {}. Mic file is still valid.", e);
                    String::new()
                }
            }
        };

        let mic_path_str = mic_path.to_string_lossy().to_string();

        let meeting_id = self
            .meeting_id
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .unwrap_or_default();

        let _ = app_handle.emit(
            "recording:stopped",
            RecordingStoppedPayload {
                meeting_id: meeting_id.clone(),
                mic_path: mic_path_str.clone(),
                system_path: system_path.clone(),
            },
        );

        log::info!(
            "AudioCapture: recording stopped for meeting {}, mic: {}, system: {}",
            meeting_id,
            mic_path_str,
            system_path
        );

        Ok(StopResult {
            mic_path: mic_path_str,
            system_path,
        })
    }
}

/// Get the recordings directory path.
fn recordings_directory() -> Result<std::path::PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "Cannot determine home directory".to_string())?;
    Ok(home
        .join("Library")
        .join("Application Support")
        .join("MeetNotes")
        .join("recordings"))
}
