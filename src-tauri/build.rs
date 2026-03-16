fn main() {
    tauri_build::build();

    // Link macOS frameworks needed for ScreenCaptureKit system audio capture
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=framework=ScreenCaptureKit");
        println!("cargo:rustc-link-lib=framework=CoreMedia");
        println!("cargo:rustc-link-lib=framework=CoreGraphics");
        println!("cargo:rustc-link-lib=framework=CoreAudio");
    }
}
