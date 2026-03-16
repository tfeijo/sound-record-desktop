use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    Emitter, Manager, Runtime,
};

/// Create the system tray with menu items
pub fn create_tray<R: Runtime>(app: &tauri::AppHandle<R>) -> Result<(), Box<dyn std::error::Error>> {
    let start_recording = MenuItemBuilder::with_id("start_recording", "Start Recording")
        .build(app)?;
    let stop_recording = MenuItemBuilder::with_id("stop_recording", "Stop Recording")
        .enabled(false)
        .build(app)?;
    let show_window = MenuItemBuilder::with_id("show_window", "Show Window")
        .build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit")
        .build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&start_recording)
        .item(&stop_recording)
        .separator()
        .item(&show_window)
        .separator()
        .item(&quit)
        .build()?;

    let _tray = TrayIconBuilder::new()
        .icon(app.default_window_icon().cloned().expect("no app icon found"))
        .menu(&menu)
        .on_menu_event(move |app_handle, event| {
            let id = event.id().as_ref();
            match id {
                "start_recording" => {
                    log::info!("Tray: start_recording clicked");
                    let _ = app_handle.emit("tray-start-recording", ());
                }
                "stop_recording" => {
                    log::info!("Tray: stop_recording clicked");
                    let _ = app_handle.emit("tray-stop-recording", ());
                }
                "show_window" => {
                    log::info!("Tray: show_window clicked");
                    if let Some(window) = app_handle.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                "quit" => {
                    log::info!("Tray: quit clicked");
                    std::process::exit(0);
                }
                _ => {
                    log::warn!("Tray: unknown menu item clicked: {}", id);
                }
            }
        })
        .build(app)?;

    Ok(())
}
