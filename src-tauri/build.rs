fn main() {
    tauri_build::build();

    // Note: macOS framework linking (ScreenCaptureKit, CoreMedia, CoreGraphics,
    // CoreAudio) is handled via #[link] attributes in system_audio.rs.
    // No additional cargo:rustc-link-lib directives needed here.
}
