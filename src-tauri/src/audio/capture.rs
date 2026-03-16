use std::fs;
use std::sync::Mutex;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use super::mic_audio::MicRecorder;

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
    path: String,
}

/// Manages audio capture for a recording session.
pub struct AudioCapture {
    recorder: Mutex<MicRecorder>,
    meeting_id: Mutex<Option<String>>,
}

impl AudioCapture {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            recorder: Mutex::new(MicRecorder::new()?),
            meeting_id: Mutex::new(None),
        })
    }

    /// Start recording microphone audio for a given meeting.
    pub fn start_recording(&self, app_handle: AppHandle, meeting_id: String) -> Result<(), String> {
        let recordings_dir = recordings_directory()?;
        fs::create_dir_all(&recordings_dir)
            .map_err(|e| format!("Failed to create recordings directory: {e}"))?;

        let file_name = format!("meeting_{}_mic.wav", meeting_id);
        let file_path = recordings_dir.join(file_name);

        // Store meeting_id
        {
            let mut mid = self.meeting_id.lock().map_err(|e| e.to_string())?;
            *mid = Some(meeting_id.clone());
        }

        // Set up level event emission
        let app_for_levels = app_handle.clone();
        let level_callback = move |level: f32| {
            let _ = app_for_levels.emit("recording:level", LevelPayload { level });
        };

        // Start the mic recorder
        {
            let mut recorder = self.recorder.lock().map_err(|e| e.to_string())?;
            recorder.start(file_path, level_callback)?;
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

    /// Stop the current recording and return the WAV file path.
    pub fn stop_recording(&self, app_handle: &AppHandle) -> Result<String, String> {
        let path = {
            let mut recorder = self.recorder.lock().map_err(|e| e.to_string())?;
            recorder.stop()?
        };

        let path_str = path.to_string_lossy().to_string();

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
                path: path_str.clone(),
            },
        );

        log::info!(
            "AudioCapture: recording stopped for meeting {}, file: {}",
            meeting_id,
            path_str
        );

        Ok(path_str)
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
