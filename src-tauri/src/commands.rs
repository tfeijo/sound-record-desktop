use std::sync::Mutex;

use serde::Serialize;
use tauri::State;

use crate::audio::capture::AudioCapture;

/// Recording status returned by get_recording_status
#[derive(Clone, Serialize)]
pub struct RecordingStatus {
    pub is_recording: bool,
    pub duration_secs: u64,
}

/// Shared recording state
pub struct RecordingState {
    is_recording: Mutex<bool>,
}

impl RecordingState {
    pub fn new() -> Self {
        Self {
            is_recording: Mutex::new(false),
        }
    }
}

/// Start a recording session
#[tauri::command]
pub fn start_recording(
    state: State<'_, RecordingState>,
    capture: State<'_, AudioCapture>,
    app: tauri::AppHandle,
    meeting_id: Option<String>,
) -> Result<(), String> {
    let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    if *is_recording {
        return Err("Already recording".to_string());
    }

    let id = meeting_id.unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis().to_string())
            .unwrap_or_else(|_| "unknown".to_string())
    });

    capture.start_recording(app, id)?;
    *is_recording = true;

    log::info!("Recording started");
    Ok(())
}

/// Stop a recording session
#[tauri::command]
pub fn stop_recording(
    state: State<'_, RecordingState>,
    capture: State<'_, AudioCapture>,
    app: tauri::AppHandle,
) -> Result<String, String> {
    let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    if !*is_recording {
        return Err("Not recording".to_string());
    }

    let path = capture.stop_recording(&app)?;
    *is_recording = false;

    log::info!("Recording stopped, file: {}", path);
    Ok(path)
}

/// Get the current recording status
#[tauri::command]
pub fn get_recording_status(state: State<'_, RecordingState>) -> Result<RecordingStatus, String> {
    let is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    Ok(RecordingStatus {
        is_recording: *is_recording,
        duration_secs: 0, // stub: will be wired to actual duration later
    })
}
