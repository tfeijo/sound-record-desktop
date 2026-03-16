use std::sync::Mutex;

use serde::Serialize;
use tauri::State;

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

/// Start a recording session (stub)
#[tauri::command]
pub fn start_recording(
    state: State<'_, RecordingState>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    if *is_recording {
        return Err("Already recording".to_string());
    }
    *is_recording = true;

    log::info!("Recording started");
    let _ = tauri::Emitter::emit(&app, "recording-started", ());
    Ok(())
}

/// Stop a recording session (stub)
#[tauri::command]
pub fn stop_recording(
    state: State<'_, RecordingState>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    if !*is_recording {
        return Err("Not recording".to_string());
    }
    *is_recording = false;

    log::info!("Recording stopped");
    let _ = tauri::Emitter::emit(&app, "recording-stopped", ());
    Ok(())
}

/// Get the current recording status (stub)
#[tauri::command]
pub fn get_recording_status(state: State<'_, RecordingState>) -> Result<RecordingStatus, String> {
    let is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    Ok(RecordingStatus {
        is_recording: *is_recording,
        duration_secs: 0, // stub: will be wired to actual duration later
    })
}
