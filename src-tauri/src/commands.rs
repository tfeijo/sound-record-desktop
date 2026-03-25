use std::sync::Mutex;
use std::time::Instant;

use serde::Serialize;
use tauri::State;

use crate::audio::capture::AudioCapture;
use crate::backend_client::BackendClient;

/// Recording status returned by get_recording_status
#[derive(Clone, Serialize)]
pub struct RecordingStatus {
    pub is_recording: bool,
    pub duration_secs: u64,
}

/// Result of starting a recording, returned to the frontend.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartRecordingResult {
    pub meeting_id: String,
    pub mic_path: String,
    pub system_path: String,
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

/// Start a recording session.
/// Orchestrates: generate ID -> start audio capture -> notify Go backend with paths.
#[tauri::command]
pub async fn start_recording(
    state: State<'_, RecordingState>,
    capture: State<'_, AudioCapture>,
    backend: State<'_, BackendClient>,
    app: tauri::AppHandle,
) -> Result<StartRecordingResult, String> {
    {
        let is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
        if *is_recording {
            return Err("Already recording".to_string());
        }
    }

    let meeting_id = uuid::Uuid::new_v4().to_string();

    // 1. Start audio capture (gets file paths)
    let audio_result = capture.start_recording(app.clone(), meeting_id.clone())?;

    // 2. Notify Go backend — creates meeting in DB + starts streaming transcription
    let backend_result = backend
        .start_recording(crate::backend_client::StartRecordingRequest {
            meeting_id: meeting_id.clone(),
            mic_path: audio_result.mic_path.clone(),
            system_path: audio_result.system_path.clone(),
        })
        .await;

    if let Err(e) = &backend_result {
        log::error!("Go backend start_recording failed: {}. Audio capture continues.", e);
        // Non-fatal: audio still records, transcription will be attempted at stop
    }

    // 3. Update recording state
    {
        let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
        *is_recording = true;
    }
    if let Ok(mut started) = state.started_at.lock() {
        *started = Some(Instant::now());
    }

    log::info!(
        "Recording started: meeting={}, mic={}, system={}",
        meeting_id,
        audio_result.mic_path,
        audio_result.system_path
    );

    Ok(StartRecordingResult {
        meeting_id,
        mic_path: audio_result.mic_path,
        system_path: audio_result.system_path,
    })
}

/// Stop a recording session.
/// Orchestrates: stop audio capture -> notify Go backend with paths + duration.
#[tauri::command]
pub async fn stop_recording(
    state: State<'_, RecordingState>,
    capture: State<'_, AudioCapture>,
    backend: State<'_, BackendClient>,
    app: tauri::AppHandle,
) -> Result<StopRecordingResult, String> {
    {
        let is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
        if !*is_recording {
            return Err("Not recording".to_string());
        }
    }

    // Calculate duration
    let duration_secs = state
        .started_at
        .lock()
        .ok()
        .and_then(|mut s| s.take())
        .map(|t| t.elapsed().as_secs())
        .unwrap_or(0);

    // 1. Stop audio capture
    let result = capture.stop_recording(&app)?;

    // 2. Update recording state
    {
        let mut is_recording = state.is_recording.lock().map_err(|e| e.to_string())?;
        *is_recording = false;
    }

    // 3. Notify Go backend — finalizes streaming + starts post-processing pipeline
    let backend_result = backend
        .stop_recording(crate::backend_client::StopRecordingRequest {
            mic_path: result.mic_path.clone(),
            system_path: result.system_path.clone(),
            duration: duration_secs,
        })
        .await;

    if let Err(e) = &backend_result {
        log::error!("Go backend stop_recording failed: {}", e);
    }

    log::info!(
        "Recording stopped: mic={}, system={}",
        result.mic_path,
        result.system_path
    );

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
