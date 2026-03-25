use std::time::Duration;

use serde::{Deserialize, Serialize};

/// Default port used by the MeetNotes Go backend
pub const BACKEND_PORT: u16 = 9876;

/// HTTP client for communicating with the Go backend.
pub struct BackendClient {
    client: reqwest::Client,
    base_url: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartRecordingRequest {
    pub meeting_id: String,
    pub mic_path: String,
    pub system_path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartRecordingResponse {
    pub meeting_id: String,
    pub status: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StopRecordingRequest {
    pub mic_path: String,
    pub system_path: String,
    pub duration: u64,
}

#[derive(Deserialize)]
pub struct StopRecordingResponse {
    pub status: String,
}

impl BackendClient {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .expect("Failed to create HTTP client");

        Self {
            client,
            base_url: format!("http://localhost:{}", BACKEND_PORT),
        }
    }

    pub async fn start_recording(
        &self,
        req: StartRecordingRequest,
    ) -> Result<StartRecordingResponse, String> {
        let url = format!("{}/api/recording/start", self.base_url);
        let resp = self
            .client
            .post(&url)
            .json(&req)
            .send()
            .await
            .map_err(|e| format!("Backend start_recording request failed: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!(
                "Backend start_recording failed ({}): {}",
                status, body
            ));
        }

        resp.json::<StartRecordingResponse>()
            .await
            .map_err(|e| format!("Failed to parse start_recording response: {}", e))
    }

    pub async fn stop_recording(
        &self,
        req: StopRecordingRequest,
    ) -> Result<StopRecordingResponse, String> {
        let url = format!("{}/api/recording/stop", self.base_url);
        let resp = self
            .client
            .post(&url)
            .json(&req)
            .send()
            .await
            .map_err(|e| format!("Backend stop_recording request failed: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!(
                "Backend stop_recording failed ({}): {}",
                status, body
            ));
        }

        resp.json::<StopRecordingResponse>()
            .await
            .map_err(|e| format!("Failed to parse stop_recording response: {}", e))
    }
}
