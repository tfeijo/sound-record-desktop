use std::sync::Mutex;
use std::time::Duration;

use tauri::{Emitter, Manager};
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;

/// Default port used by the MeetNotes backend
const DEFAULT_PORT: u16 = 9876;

/// Maximum time to wait for the backend health check (in seconds)
const HEALTH_CHECK_TIMEOUT_SECS: u64 = 30;

/// Interval between health check polls (in milliseconds)
const HEALTH_CHECK_INTERVAL_MS: u64 = 500;

/// State to hold the sidecar child process
pub struct SidecarState {
    child: Mutex<Option<CommandChild>>,
}

impl SidecarState {
    pub fn new() -> Self {
        Self {
            child: Mutex::new(None),
        }
    }

    /// Store the sidecar child process
    pub fn set_child(&self, child: CommandChild) {
        let mut guard = self.child.lock().expect("sidecar state lock poisoned");
        *guard = Some(child);
    }

    /// Kill the sidecar process if running
    pub fn kill(&self) {
        let mut guard = self.child.lock().expect("sidecar state lock poisoned");
        if let Some(child) = guard.take() {
            log::info!("Killing sidecar process (pid: {})", child.pid());
            let _ = child.kill();
        }
    }
}

/// Spawn the Go backend as a sidecar process.
///
/// In dev mode, if the binary is not found, we log a warning and skip
/// (assuming the backend is started manually).
pub fn spawn_sidecar(app: &tauri::AppHandle) -> Result<(), String> {
    let sidecar_command = app.shell().sidecar("meetnotes-backend").map_err(|e| {
        format!("Failed to create sidecar command: {}", e)
    })?;

    let (mut rx, child) = sidecar_command.spawn().map_err(|e| {
        if cfg!(debug_assertions) {
            log::warn!(
                "Sidecar binary not found (dev mode). Assuming backend is started manually: {}",
                e
            );
            return format!("Sidecar spawn skipped (dev mode): {}", e);
        }
        format!("Failed to spawn sidecar: {}", e)
    })?;

    // Store the child process in state for cleanup later
    let state = app.state::<SidecarState>();
    state.set_child(child);

    // Spawn async task to monitor sidecar stdout/stderr
    let app_handle = app.clone();
    tauri::async_runtime::spawn(async move {
        use tauri_plugin_shell::process::CommandEvent;

        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(line) => {
                    let line_str = String::from_utf8_lossy(&line);
                    log::info!("[sidecar stdout] {}", line_str.trim_end());
                }
                CommandEvent::Stderr(line) => {
                    let line_str = String::from_utf8_lossy(&line);
                    log::warn!("[sidecar stderr] {}", line_str.trim_end());
                }
                CommandEvent::Error(err) => {
                    log::error!("[sidecar error] {}", err);
                }
                CommandEvent::Terminated(payload) => {
                    log::error!(
                        "[sidecar terminated] code: {:?}, signal: {:?}",
                        payload.code,
                        payload.signal
                    );
                    if let Some(window) = app_handle.get_webview_window("main") {
                        let _ = window.emit("sidecar-terminated", payload.code);
                    }
                }
                _ => {}
            }
        }
    });

    // Spawn async task to poll the health endpoint
    let app_handle_health = app.clone();
    tauri::async_runtime::spawn(async move {
        match poll_health_check().await {
            Ok(()) => {
                log::info!("Go backend is ready (health check passed)");
                if let Some(window) = app_handle_health.get_webview_window("main") {
                    let _ = window.emit("backend-ready", ());
                }
            }
            Err(e) => {
                log::error!("Go backend health check failed: {}", e);
                if let Some(window) = app_handle_health.get_webview_window("main") {
                    let _ = window.emit("backend-health-failed", e);
                }
            }
        }
    });

    log::info!("MeetNotes backend sidecar started");
    Ok(())
}

/// Poll the Go backend health endpoint until it responds 200 or timeout
async fn poll_health_check() -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let url = format!("http://localhost:{}/health", DEFAULT_PORT);
    let max_attempts = (HEALTH_CHECK_TIMEOUT_SECS * 1000) / HEALTH_CHECK_INTERVAL_MS;

    for attempt in 1..=max_attempts {
        match client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                log::info!("Health check passed on attempt {}", attempt);
                return Ok(());
            }
            Ok(resp) => {
                log::debug!(
                    "Health check attempt {}: status {}",
                    attempt,
                    resp.status()
                );
            }
            Err(e) => {
                log::debug!("Health check attempt {}: {}", attempt, e);
            }
        }
        tokio::time::sleep(Duration::from_millis(HEALTH_CHECK_INTERVAL_MS)).await;
    }

    Err(format!(
        "Backend health check timed out after {} seconds",
        HEALTH_CHECK_TIMEOUT_SECS
    ))
}
