use std::sync::Mutex;
use std::time::Instant;

use serde::Serialize;
use tauri::State;

use crate::audio::capture::AudioCapture;

/// Recording status returned by get_recording_status
#[derive(Clone, Serialize)]
pub struct RecordingStatus {
    pub is_recording: bool,
    pub duration_secs: u64,
}

/// Result of stopping a recording, returned to the frontend.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StopRecordingResult {
    pub mic_path: String,
    pub system_path: String,
    pub duration_secs: u64,
}

/// Shared recording state
pub struct RecordingState {
    is_recording: Mutex<bool>,
    started_at: Mutex<Option<Instant>>,
}

impl RecordingState {
    pub fn new() -> Self {
        Self {
            is_recording: Mutex::new(false),
            started_at: Mutex::new(None),
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

    // Track when recording started for duration calculation
    if let Ok(mut started) = state.started_at.lock() {
        *started = Some(Instant::now());
    }

    log::info!("Recording started");
    Ok(())
}

/// Stop a recording session and return file paths + duration.
#[tauri::command]
pub fn stop_recording(
    state: State<'_, RecordingState>,
    capture: State<'_, AudioCapture>,
    app: tauri::AppHandle,
) -> Result<StopRecordingResult, String> {
    let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    if !*is_recording {
        return Err("Not recording".to_string());
    }

    // Calculate duration
    let duration_secs = state
        .started_at
        .lock()
        .ok()
        .and_then(|mut s| s.take())
        .map(|t| t.elapsed().as_secs())
        .unwrap_or(0);

    let result = capture.stop_recording(&app)?;
    *is_recording = false;

    log::info!("Recording stopped, result: {}", result);

    Ok(StopRecordingResult {
        mic_path: result.mic_path,
        system_path: result.system_path,
        duration_secs,
    })
}

/// Get the current recording status
#[tauri::command]
pub fn get_recording_status(state: State<'_, RecordingState>) -> Result<RecordingStatus, String> {
    let is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
    let duration_secs = state
        .started_at
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|t| t.elapsed().as_secs()))
        .unwrap_or(0);
    Ok(RecordingStatus {
        is_recording: *is_recording,
        duration_secs,
    })
}
