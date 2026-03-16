mod commands;
mod sidecar;
mod tray;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_notification::init())
        .manage(sidecar::SidecarState::new())
        .manage(commands::RecordingState::new())
        .invoke_handler(tauri::generate_handler![
            commands::start_recording,
            commands::stop_recording,
            commands::get_recording_status,
        ])
        .setup(|app| {
            // Initialize logging in dev mode
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Debug)
                        .build(),
                )?;
            }

            // Create system tray
            if let Err(e) = tray::create_tray(app.handle()) {
                log::error!("Failed to create system tray: {}", e);
            }

            // Spawn Go backend sidecar
            match sidecar::spawn_sidecar(app.handle()) {
                Ok(()) => {
                    log::info!("Sidecar spawn initiated");
                }
                Err(e) => {
                    log::error!("Failed to spawn sidecar: {}", e);
                    // In dev mode this is expected if binary not built yet
                    if cfg!(debug_assertions) {
                        log::warn!("Dev mode: backend sidecar not started. Run it manually or build with `make build-go`.");
                    }
                }
            }

            Ok(())
        })
        .on_window_event(|_window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Sidecar cleanup happens via Drop on SidecarState
                // or we could explicitly kill here
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
