use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::audio_utils::{calculate_rms_level, mix_to_mono, resample};
use super::wav_writer::WavWriter;

/// SystemRecorder captures system audio (what other meeting participants say)
/// using macOS ScreenCaptureKit via raw Objective-C FFI.
///
/// The capture flow:
///   1. Check/request Screen Recording permission via CoreGraphics
///   2. Get shareable content (SCShareableContent)
///   3. Create SCContentFilter excluding own app
///   4. Configure SCStreamConfiguration for audio-only at 16kHz mono
///   5. Create SCStream with an output delegate that receives CMSampleBuffers
///   6. Convert audio samples to i16 and write to WavWriter
pub struct SystemRecorder {
    is_recording: Arc<AtomicBool>,
    wav_path: Mutex<Option<PathBuf>>,
    writer: Arc<Mutex<Option<WavWriter>>>,
    stop_signal: Arc<AtomicBool>,
    thread_handle: Mutex<Option<std::thread::JoinHandle<()>>>,
}

// Safety: same reasoning as MicRecorder — no !Send types stored directly.
// The SCStream and ObjC objects live only on the dedicated recording thread.
unsafe impl Send for SystemRecorder {}
unsafe impl Sync for SystemRecorder {}

impl SystemRecorder {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            is_recording: Arc::new(AtomicBool::new(false)),
            wav_path: Mutex::new(None),
            writer: Arc::new(Mutex::new(None)),
            stop_signal: Arc::new(AtomicBool::new(false)),
            thread_handle: Mutex::new(None),
        })
    }

    /// Start capturing system audio to `path`.
    pub fn start(
        &mut self,
        path: PathBuf,
        level_callback: impl Fn(f32) + Send + 'static,
    ) -> Result<(), String> {
        if self.is_recording.load(Ordering::SeqCst) {
            return Err("System recorder already recording".to_string());
        }

        #[cfg(not(target_os = "macos"))]
        {
            return self.start_fallback(path, level_callback);
        }

        #[cfg(target_os = "macos")]
        {
            // Check Screen Recording permission first
            ensure_screen_capture_permission()?;

            let wav = WavWriter::new(&path)?;
            *self.writer.lock().map_err(|e| e.to_string())? = Some(wav);
            *self.wav_path.lock().map_err(|e| e.to_string())? = Some(path);

            self.is_recording.store(true, Ordering::SeqCst);
            self.stop_signal.store(false, Ordering::SeqCst);

            let writer = self.writer.clone();
            let stop_signal = self.stop_signal.clone();
            let is_recording = self.is_recording.clone();

            let handle = std::thread::spawn(move || {
                if let Err(e) =
                    run_screencapturekit_thread(writer, stop_signal.clone(), level_callback)
                {
                    log::error!("System audio capture thread error: {}", e);
                }
                is_recording.store(false, Ordering::SeqCst);
            });

            *self.thread_handle.lock().map_err(|e| e.to_string())? = Some(handle);

            log::info!("System audio recording started (ScreenCaptureKit)");
            Ok(())
        }
    }

    /// Fallback for non-macOS: write silence (stub).
    #[cfg(not(target_os = "macos"))]
    fn start_fallback(
        &mut self,
        path: PathBuf,
        level_callback: impl Fn(f32) + Send + 'static,
    ) -> Result<(), String> {
        log::warn!("System audio capture not available on this platform. Recording silence.");

        let wav = WavWriter::new(&path)?;
        *self.writer.lock().map_err(|e| e.to_string())? = Some(wav);
        *self.wav_path.lock().map_err(|e| e.to_string())? = Some(path);

        self.is_recording.store(true, Ordering::SeqCst);
        self.stop_signal.store(false, Ordering::SeqCst);

        let writer = self.writer.clone();
        let stop_signal = self.stop_signal.clone();
        let is_recording = self.is_recording.clone();

        let handle = std::thread::spawn(move || {
            let silence = vec![0i16; 800];
            while !stop_signal.load(Ordering::SeqCst) {
                level_callback(0.0);
                if let Ok(mut guard) = writer.lock() {
                    if let Some(ref mut w) = *guard {
                        if let Err(e) = w.write_samples(&silence) {
                            log::error!("System audio stub: failed to write silence: {}", e);
                            break;
                        }
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            is_recording.store(false, Ordering::SeqCst);
        });

        *self.thread_handle.lock().map_err(|e| e.to_string())? = Some(handle);
        Ok(())
    }

    /// Stop recording and return the WAV file path.
    pub fn stop(&mut self) -> Result<PathBuf, String> {
        if !self.is_recording.load(Ordering::SeqCst) {
            // The thread may have already cleared the flag; check if we have a path
            if self.wav_path.lock().map_err(|e| e.to_string())?.is_none() {
                return Err("System recorder not recording".to_string());
            }
        }

        self.stop_signal.store(true, Ordering::SeqCst);
        self.is_recording.store(false, Ordering::SeqCst);

        if let Some(handle) = self.thread_handle.lock().map_err(|e| e.to_string())?.take() {
            let _ = handle.join();
        }

        let writer = self
            .writer
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "No active system WAV writer".to_string())?;

        writer.finalize()?;

        let path = self
            .wav_path
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "No system WAV path set".to_string())?;

        log::info!("System audio recording stopped: {:?}", path);
        Ok(path)
    }
}

// ─── macOS ScreenCaptureKit implementation ────────────────────────────────────

#[cfg(target_os = "macos")]
use std::ffi::{c_char, c_long, c_void};

#[cfg(target_os = "macos")]
#[link(name = "ScreenCaptureKit", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
#[link(name = "CoreMedia", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

#[cfg(target_os = "macos")]
#[link(name = "objc", kind = "dylib")]
extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn objc_msgSend();
    fn objc_allocateClassPair(
        superclass: *mut c_void,
        name: *const c_char,
        extra_bytes: usize,
    ) -> *mut c_void;
    fn objc_registerClassPair(cls: *mut c_void);
    fn class_addMethod(
        cls: *mut c_void,
        sel: *mut c_void,
        imp: *const c_void,
        types: *const c_char,
    ) -> bool;
    fn class_addIvar(
        cls: *mut c_void,
        name: *const c_char,
        size: usize,
        alignment: u8,
        types: *const c_char,
    ) -> bool;
    fn object_getInstanceVariable(
        obj: *mut c_void,
        name: *const c_char,
        out_value: *mut *mut c_void,
    ) -> *mut c_void;
    fn object_setInstanceVariable(
        obj: *mut c_void,
        name: *const c_char,
        value: *mut c_void,
    ) -> *mut c_void;
}

#[cfg(target_os = "macos")]
#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    fn CMSampleBufferGetDataBuffer(sbuf: *mut c_void) -> *mut c_void;
    fn CMBlockBufferGetDataLength(block: *mut c_void) -> usize;
    fn CMBlockBufferCopyDataBytes(
        block: *mut c_void,
        offset: usize,
        length: usize,
        dest: *mut c_void,
    ) -> i32;
    fn CMSampleBufferGetFormatDescription(sbuf: *mut c_void) -> *mut c_void;
}

#[cfg(target_os = "macos")]
#[link(name = "CoreAudio", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
extern "C" {
    fn CMAudioFormatDescriptionGetStreamBasicDescription(
        desc: *mut c_void,
    ) -> *const AudioStreamBasicDescription;
}

/// CoreAudio AudioStreamBasicDescription
#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct AudioStreamBasicDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[cfg(target_os = "macos")]
const K_AUDIO_FORMAT_LINEAR_PCM: u32 = 0x6C70636D; // 'lpcm'
#[cfg(target_os = "macos")]
const K_AUDIO_FORMAT_FLAG_IS_FLOAT: u32 = 1 << 0;
#[cfg(target_os = "macos")]
const K_AUDIO_FORMAT_FLAG_IS_BIG_ENDIAN: u32 = 1 << 1;
#[cfg(target_os = "macos")]
const K_AUDIO_FORMAT_FLAG_IS_SIGNED_INTEGER: u32 = 1 << 2;

/// Ensure Screen Recording permission is granted.
#[cfg(target_os = "macos")]
fn ensure_screen_capture_permission() -> Result<(), String> {
    unsafe {
        if CGPreflightScreenCaptureAccess() {
            log::info!("Screen Recording permission already granted");
            return Ok(());
        }

        log::info!("Requesting Screen Recording permission...");
        let granted = CGRequestScreenCaptureAccess();
        if granted {
            log::info!("Screen Recording permission granted");
            Ok(())
        } else {
            // On macOS, CGRequestScreenCaptureAccess returns false but opens System Settings.
            // The user needs to grant permission and restart the app.
            // We return an error so the capture falls back gracefully.
            Err(
                "Screen Recording permission not granted. \
                 Please enable in System Settings > Privacy & Security > Screen Recording, \
                 then restart the app."
                    .to_string(),
            )
        }
    }
}

/// Shared context for the SCStreamOutput delegate callback.
#[cfg(target_os = "macos")]
struct CaptureContext {
    writer: Arc<Mutex<Option<WavWriter>>>,
    stop_signal: Arc<AtomicBool>,
    level_callback: Box<dyn Fn(f32) + Send>,
    callback_count: u64,
}

/// Convert raw audio bytes from CMSampleBuffer to i16 samples based on ASBD.
#[cfg(target_os = "macos")]
fn convert_audio_bytes_to_i16(bytes: &[u8], asbd: &AudioStreamBasicDescription) -> Vec<i16> {
    let is_float = (asbd.format_flags & K_AUDIO_FORMAT_FLAG_IS_FLOAT) != 0;
    let _is_signed = (asbd.format_flags & K_AUDIO_FORMAT_FLAG_IS_SIGNED_INTEGER) != 0;
    let bits = asbd.bits_per_channel;

    // I6: Check for big-endian format flag and warn
    if (asbd.format_flags & K_AUDIO_FORMAT_FLAG_IS_BIG_ENDIAN) != 0 {
        log::warn!(
            "Big-endian audio format detected (flags=0x{:x}). \
             Decoding may produce incorrect results on little-endian host.",
            asbd.format_flags
        );
    }

    if is_float && bits == 32 {
        // Float32 samples
        bytes
            .chunks_exact(4)
            .map(|chunk| {
                let f = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                (f.clamp(-1.0, 1.0) * 32767.0) as i16
            })
            .collect()
    } else if is_float && bits == 64 {
        // Float64 samples
        bytes
            .chunks_exact(8)
            .map(|chunk| {
                let f = f64::from_le_bytes([
                    chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6],
                    chunk[7],
                ]);
                (f.clamp(-1.0, 1.0) * 32767.0) as i16
            })
            .collect()
    } else if bits == 16 {
        // Int16 samples
        bytes
            .chunks_exact(2)
            .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
            .collect()
    } else if bits == 32 && !is_float {
        // Int32 samples — scale down to i16
        bytes
            .chunks_exact(4)
            .map(|chunk| {
                let i = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                (i >> 16) as i16
            })
            .collect()
    } else {
        log::warn!(
            "Unsupported audio format: bits={}, float={}, flags=0x{:x}. Treating as f32.",
            bits,
            is_float,
            asbd.format_flags
        );
        bytes
            .chunks_exact(4)
            .map(|chunk| {
                let f = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                (f.clamp(-1.0, 1.0) * 32767.0) as i16
            })
            .collect()
    }
}

/// I3: Register the delegate class only once, reusing across start/stop cycles.
#[cfg(target_os = "macos")]
fn get_delegate_class() -> *mut c_void {
    use std::sync::Once;

    static REGISTER_ONCE: Once = Once::new();
    static mut DELEGATE_CLS: *mut c_void = std::ptr::null_mut();

    unsafe {
        REGISTER_ONCE.call_once(|| {
            let nsobject_cls = objc_getClass(b"NSObject\0".as_ptr() as *const c_char);
            let cls = objc_allocateClassPair(
                nsobject_cls,
                b"MeetNotesSCStreamOutputDelegate\0".as_ptr() as *const c_char,
                0,
            );
            assert!(!cls.is_null(), "Failed to allocate delegate class");

            // Add ivar to store our CaptureContext pointer
            class_addIvar(
                cls,
                b"_captureCtx\0".as_ptr() as *const c_char,
                std::mem::size_of::<*mut c_void>(),
                3, // log2(sizeof(pointer)) alignment
                b"^v\0".as_ptr() as *const c_char,
            );

            // Add the stream:didOutputSampleBuffer:ofType: method
            let sel_did_output = sel_registerName(
                b"stream:didOutputSampleBuffer:ofType:\0".as_ptr() as *const c_char,
            );
            class_addMethod(
                cls,
                sel_did_output,
                stream_output_handler as *const c_void,
                b"v@:@@q\0".as_ptr() as *const c_char,
            );

            objc_registerClassPair(cls);
            DELEGATE_CLS = cls;
        });
        DELEGATE_CLS
    }
}

/// The SCStreamOutput delegate callback: `stream:didOutputSampleBuffer:ofType:`
/// This is called by ScreenCaptureKit on its internal dispatch queue.
#[cfg(target_os = "macos")]
extern "C" fn stream_output_handler(
    this: *mut c_void,
    _sel: *mut c_void,
    _stream: *mut c_void,
    sample_buffer: *mut c_void,
    output_type: c_long,
) {
    // SCStreamOutputType.audio == 1
    if output_type != 1 {
        return;
    }

    unsafe {
        // Retrieve our context pointer from the ivar
        let mut ctx_ptr: *mut c_void = std::ptr::null_mut();
        object_getInstanceVariable(
            this,
            b"_captureCtx\0".as_ptr() as *const c_char,
            &mut ctx_ptr,
        );
        if ctx_ptr.is_null() {
            return;
        }
        let ctx = &mut *(ctx_ptr as *mut CaptureContext);

        if ctx.stop_signal.load(Ordering::SeqCst) {
            return;
        }

        // Get audio format description
        let format_desc = CMSampleBufferGetFormatDescription(sample_buffer);
        if format_desc.is_null() {
            return;
        }

        let asbd_ptr = CMAudioFormatDescriptionGetStreamBasicDescription(format_desc);
        if asbd_ptr.is_null() {
            return;
        }
        let asbd = *asbd_ptr;

        // Log first few callbacks for debugging
        ctx.callback_count += 1;
        if ctx.callback_count <= 3 || ctx.callback_count % 500 == 0 {
            log::info!(
                "[system_audio] callback #{}: format_id=0x{:x}, rate={}, ch={}, bits={}, flags=0x{:x}",
                ctx.callback_count,
                asbd.format_id,
                asbd.sample_rate,
                asbd.channels_per_frame,
                asbd.bits_per_channel,
                asbd.format_flags,
            );
        }

        // Get the audio data from CMBlockBuffer
        let block_buf = CMSampleBufferGetDataBuffer(sample_buffer);
        if block_buf.is_null() {
            return;
        }

        let data_len = CMBlockBufferGetDataLength(block_buf);
        if data_len == 0 {
            return;
        }

        let mut audio_bytes = vec![0u8; data_len];
        let status = CMBlockBufferCopyDataBytes(
            block_buf,
            0,
            data_len,
            audio_bytes.as_mut_ptr() as *mut c_void,
        );
        if status != 0 {
            log::error!("CMBlockBufferCopyDataBytes failed with status {}", status);
            return;
        }

        // Only process Linear PCM
        if asbd.format_id != K_AUDIO_FORMAT_LINEAR_PCM {
            log::warn!(
                "Non-PCM audio format 0x{:x}, skipping buffer",
                asbd.format_id
            );
            return;
        }

        // Convert to i16 samples
        let i16_samples = convert_audio_bytes_to_i16(&audio_bytes, &asbd);

        // Mix to mono if needed
        let mono = mix_to_mono(&i16_samples, asbd.channels_per_frame);

        // Calculate level
        let level = calculate_rms_level(&mono);
        (ctx.level_callback)(level);

        // Resample to 16kHz
        let source_rate = asbd.sample_rate as u32;
        let resampled = resample(&mono, source_rate, 16000);

        // Write to WAV
        if let Ok(mut guard) = ctx.writer.lock() {
            if let Some(ref mut w) = *guard {
                if let Err(e) = w.write_samples(&resampled) {
                    log::error!("System audio: failed to write samples: {}", e);
                }
            }
        }
    }
}

/// Run the ScreenCaptureKit capture on a dedicated thread.
/// This sets up the Objective-C objects, starts the stream, and blocks until stop.
#[cfg(target_os = "macos")]
fn run_screencapturekit_thread(
    writer: Arc<Mutex<Option<WavWriter>>>,
    stop_signal: Arc<AtomicBool>,
    level_callback: impl Fn(f32) + Send + 'static,
) -> Result<(), String> {
    unsafe {
        // ── Helper: send ObjC messages ──────────────────────────────────────
        let msg_send_void: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const c_void);
        let msg_send_void0: extern "C" fn(*mut c_void, *mut c_void) =
            std::mem::transmute(objc_msgSend as *const c_void);
        let msg_send_bool: extern "C" fn(*mut c_void, *mut c_void, bool) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const c_void);
        let msg_send_i64: extern "C" fn(*mut c_void, *mut c_void, i64) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const c_void);
        let msg_send_u64: extern "C" fn(*mut c_void, *mut c_void, u64) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const c_void);
        let msg_send_obj: extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> *mut c_void =
            std::mem::transmute(objc_msgSend as *const c_void);
        let msg_send_long: extern "C" fn(*mut c_void, *mut c_void) -> c_long =
            std::mem::transmute(objc_msgSend as *const c_void);

        // ── Step 1: Get SCShareableContent synchronously ────────────────────
        // SCShareableContent.getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:
        // We use a semaphore to make this synchronous.

        let content_cls = objc_getClass(b"SCShareableContent\0".as_ptr() as *const c_char);
        if content_cls.is_null() {
            return Err("SCShareableContent class not found. macOS 12.3+ required.".to_string());
        }

        // Create dispatch semaphore
        #[link(name = "System", kind = "dylib")]
        extern "C" {
            fn dispatch_semaphore_create(value: c_long) -> *mut c_void;
            fn dispatch_semaphore_signal(sema: *mut c_void) -> c_long;
            fn dispatch_semaphore_wait(sema: *mut c_void, timeout: u64) -> c_long;
            fn dispatch_get_global_queue(identifier: c_long, flags: usize) -> *mut c_void;
        }
        const DISPATCH_TIME_FOREVER: u64 = !0;

        let semaphore = dispatch_semaphore_create(0);

        // We need a shared mutable location for the completion handler result
        let content_result: Arc<Mutex<Option<*mut c_void>>> = Arc::new(Mutex::new(None));
        let error_result: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        // Build an Objective-C block for the completion handler
        // Signature: ^void(SCShareableContent *content, NSError *error)
        //
        // SIGBUS FIX: All captured state is stored in a heap-allocated context
        // struct, and the block only holds a raw pointer to it. Raw pointers are
        // Copy, so _Block_copy's memcpy is safe. flags=0 means no
        // BLOCK_HAS_COPY_DISPOSE, so the runtime won't call missing helpers.

        struct CompletionBlockContext {
            content_result: Arc<Mutex<Option<*mut c_void>>>,
            error_result: Arc<Mutex<Option<String>>>,
            semaphore: *mut c_void,
        }

        #[repr(C)]
        struct CompletionBlock {
            isa: *const c_void,
            flags: i32,
            reserved: i32,
            invoke: extern "C" fn(*mut CompletionBlock, *mut c_void, *mut c_void),
            descriptor: *const BlockDescriptor,
            // Raw pointer to heap context — safe to memcpy
            context: *mut CompletionBlockContext,
        }

        #[repr(C)]
        struct BlockDescriptor {
            reserved: u64,
            size: u64,
        }

        extern "C" fn completion_invoke(
            block: *mut CompletionBlock,
            content: *mut c_void,
            error: *mut c_void,
        ) {
            unsafe {
                let block = &*block;
                let ctx = &*block.context;
                if !error.is_null() {
                    let sel_desc = sel_registerName(
                        b"localizedDescription\0".as_ptr() as *const c_char,
                    );
                    let msg: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
                        std::mem::transmute(objc_msgSend as *const c_void);
                    let desc_ns = msg(error, sel_desc);
                    let err_str = nsstring_to_rust(desc_ns);
                    if let Some(mut guard) = ctx.error_result.lock().ok() {
                        *guard = Some(err_str);
                    }
                } else if !content.is_null() {
                    // Retain the content object so it doesn't get deallocated
                    let sel_retain =
                        sel_registerName(b"retain\0".as_ptr() as *const c_char);
                    let msg: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
                        std::mem::transmute(objc_msgSend as *const c_void);
                    msg(content, sel_retain);
                    if let Some(mut guard) = ctx.content_result.lock().ok() {
                        *guard = Some(content);
                    }
                }
                dispatch_semaphore_signal(ctx.semaphore);
            }
        }

        extern "C" {
            static _NSConcreteStackBlock: *const c_void;
        }

        let completion_ctx = Box::into_raw(Box::new(CompletionBlockContext {
            content_result: content_result.clone(),
            error_result: error_result.clone(),
            semaphore,
        }));

        let descriptor = BlockDescriptor {
            reserved: 0,
            size: std::mem::size_of::<CompletionBlock>() as u64,
        };

        let block = CompletionBlock {
            isa: &_NSConcreteStackBlock as *const _ as *const c_void,
            flags: 0,
            reserved: 0,
            invoke: completion_invoke,
            descriptor: &descriptor,
            context: completion_ctx,
        };

        // Call SCShareableContent.getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:
        let sel_get = sel_registerName(
            b"getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:\0"
                .as_ptr() as *const c_char,
        );
        let msg_get: extern "C" fn(
            *mut c_void,
            *mut c_void,
            bool,
            bool,
            *const CompletionBlock,
        ) = std::mem::transmute(objc_msgSend as *const c_void);
        msg_get(content_cls, sel_get, true, true, &block);

        // Wait for completion
        let wait_result = dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Block has been invoked; reclaim the heap context
        let _ = Box::from_raw(completion_ctx);

        if wait_result != 0 {
            return Err("Timed out waiting for SCShareableContent".to_string());
        }

        // Check for errors
        if let Some(err) = error_result.lock().map_err(|e| e.to_string())?.take() {
            return Err(format!("SCShareableContent error: {}", err));
        }

        let content = content_result
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "SCShareableContent returned null".to_string())?;

        // ── Step 2: Get the main display ────────────────────────────────────
        let sel_displays = sel_registerName(b"displays\0".as_ptr() as *const c_char);
        let displays = msg_send_void(content, sel_displays);
        if displays.is_null() {
            return Err("No displays found in shareable content".to_string());
        }

        let sel_count = sel_registerName(b"count\0".as_ptr() as *const c_char);
        let display_count = msg_send_long(displays, sel_count);
        if display_count == 0 {
            return Err("No displays available for capture".to_string());
        }

        let sel_first = sel_registerName(b"firstObject\0".as_ptr() as *const c_char);
        let display = msg_send_void(displays, sel_first);
        if display.is_null() {
            return Err("Failed to get first display".to_string());
        }

        log::info!(
            "ScreenCaptureKit: found {} display(s), using first",
            display_count
        );

        // ── Step 3: Get our app to exclude ──────────────────────────────────
        let sel_apps = sel_registerName(b"applications\0".as_ptr() as *const c_char);
        let apps = msg_send_void(content, sel_apps);

        // Get current process ID
        let process_info_cls = objc_getClass(b"NSProcessInfo\0".as_ptr() as *const c_char);
        let sel_process_info = sel_registerName(b"processInfo\0".as_ptr() as *const c_char);
        let process_info = msg_send_void(process_info_cls, sel_process_info);
        let sel_pid = sel_registerName(b"processIdentifier\0".as_ptr() as *const c_char);
        let our_pid: i32 = std::mem::transmute::<
            _,
            extern "C" fn(*mut c_void, *mut c_void) -> i32,
        >(objc_msgSend as *const c_void)(process_info, sel_pid);

        log::info!("Our PID: {}", our_pid);

        // Build NSArray of apps to exclude (just our own app)
        let ns_mutable_array_cls =
            objc_getClass(b"NSMutableArray\0".as_ptr() as *const c_char);
        let sel_new = sel_registerName(b"new\0".as_ptr() as *const c_char);
        let excluded_apps = msg_send_void(ns_mutable_array_cls, sel_new);
        let sel_add_object = sel_registerName(b"addObject:\0".as_ptr() as *const c_char);

        // Iterate apps to find ours
        let app_count = msg_send_long(apps, sel_count);
        let sel_object_at = sel_registerName(b"objectAtIndex:\0".as_ptr() as *const c_char);
        let sel_process_id = sel_registerName(b"processID\0".as_ptr() as *const c_char);

        for i in 0..app_count {
            let app = msg_send_i64(apps, sel_object_at, i as i64);
            let app_pid: i32 = std::mem::transmute::<
                _,
                extern "C" fn(*mut c_void, *mut c_void) -> i32,
            >(objc_msgSend as *const c_void)(app, sel_process_id);
            if app_pid == our_pid {
                msg_send_obj(excluded_apps, sel_add_object, app);
                log::info!(
                    "Excluding our app (PID {}) from system audio capture",
                    our_pid
                );
                break;
            }
        }

        // ── Step 4: Create SCContentFilter ──────────────────────────────────
        // initWithDisplay:excludingApplications:exceptingWindows:
        let filter_cls = objc_getClass(b"SCContentFilter\0".as_ptr() as *const c_char);
        let sel_alloc = sel_registerName(b"alloc\0".as_ptr() as *const c_char);
        let filter_alloc = msg_send_void(filter_cls, sel_alloc);

        // Create empty NSArray for excepting windows
        let ns_array_cls = objc_getClass(b"NSArray\0".as_ptr() as *const c_char);
        let empty_array = msg_send_void(ns_array_cls, sel_new);

        let sel_init_filter = sel_registerName(
            b"initWithDisplay:excludingApplications:exceptingWindows:\0".as_ptr() as *const c_char,
        );
        let msg_init_filter: extern "C" fn(
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
        ) -> *mut c_void = std::mem::transmute(objc_msgSend as *const c_void);
        let filter = msg_init_filter(
            filter_alloc,
            sel_init_filter,
            display,
            excluded_apps,
            empty_array,
        );
        if filter.is_null() {
            return Err("Failed to create SCContentFilter".to_string());
        }

        // ── Step 5: Create SCStreamConfiguration ────────────────────────────
        let config_cls =
            objc_getClass(b"SCStreamConfiguration\0".as_ptr() as *const c_char);
        let config = msg_send_void(config_cls, sel_new);
        if config.is_null() {
            return Err("Failed to create SCStreamConfiguration".to_string());
        }

        // Disable video capture (we only want audio)
        let sel_set_captures_audio =
            sel_registerName(b"setCapturesAudio:\0".as_ptr() as *const c_char);
        msg_send_bool(config, sel_set_captures_audio, true);

        let sel_set_excludes_current_process_audio = sel_registerName(
            b"setExcludesCurrentProcessAudio:\0".as_ptr() as *const c_char,
        );
        msg_send_bool(config, sel_set_excludes_current_process_audio, true);

        // Set audio sample rate to 48000 (ScreenCaptureKit's native rate)
        // We'll resample to 16kHz ourselves for best quality
        let sel_set_sample_rate =
            sel_registerName(b"setSampleRate:\0".as_ptr() as *const c_char);
        msg_send_i64(config, sel_set_sample_rate, 48000);

        // Set channel count to 2 (stereo is typical for system audio, we mix to mono)
        let sel_set_channel_count =
            sel_registerName(b"setChannelCount:\0".as_ptr() as *const c_char);
        msg_send_i64(config, sel_set_channel_count, 2);

        // Minimize video overhead: set minimal resolution and frame rate
        let sel_set_width = sel_registerName(b"setWidth:\0".as_ptr() as *const c_char);
        let sel_set_height = sel_registerName(b"setHeight:\0".as_ptr() as *const c_char);
        msg_send_u64(config, sel_set_width, 2u64);
        msg_send_u64(config, sel_set_height, 2u64);

        // Set minimum frame interval to maximum (lowest framerate)
        // CMTime(10, 1) = 0.1 fps
        let sel_set_min_frame_interval = sel_registerName(
            b"setMinimumFrameInterval:\0".as_ptr() as *const c_char,
        );
        #[repr(C)]
        #[derive(Clone, Copy)]
        struct CMTime {
            value: i64,
            timescale: i32,
            flags: u32,
            epoch: i64,
        }
        let slow_interval = CMTime {
            value: 10,
            timescale: 1,
            flags: 1, // kCMTimeFlags_Valid
            epoch: 0,
        };
        let msg_set_cmtime: extern "C" fn(*mut c_void, *mut c_void, CMTime) =
            std::mem::transmute(objc_msgSend as *const c_void);
        msg_set_cmtime(config, sel_set_min_frame_interval, slow_interval);

        // Try to disable video via showsCursor and related
        let sel_set_shows_cursor =
            sel_registerName(b"setShowsCursor:\0".as_ptr() as *const c_char);
        msg_send_bool(config, sel_set_shows_cursor, false);

        // ── Step 6: Create SCStreamOutput delegate ──────────────────────────
        // I3: Reuse a single ObjC class registered via Once
        let delegate_cls = get_delegate_class();

        // Instantiate the delegate
        let delegate = msg_send_void(delegate_cls, sel_alloc);
        let sel_init = sel_registerName(b"init\0".as_ptr() as *const c_char);
        let delegate = msg_send_void(delegate, sel_init);
        if delegate.is_null() {
            return Err("Failed to create delegate instance".to_string());
        }

        // Create the CaptureContext on the heap and store pointer in ivar
        let ctx = Box::new(CaptureContext {
            writer,
            stop_signal: stop_signal.clone(),
            level_callback: Box::new(level_callback),
            callback_count: 0,
        });
        let ctx_ptr = Box::into_raw(ctx);
        object_setInstanceVariable(
            delegate,
            b"_captureCtx\0".as_ptr() as *const c_char,
            ctx_ptr as *mut c_void,
        );

        // ── Step 7: Create and start SCStream ───────────────────────────────
        let stream_cls = objc_getClass(b"SCStream\0".as_ptr() as *const c_char);
        let stream_alloc = msg_send_void(stream_cls, sel_alloc);

        let sel_init_stream = sel_registerName(
            b"initWithFilter:configuration:delegate:\0".as_ptr() as *const c_char,
        );
        let msg_init_stream: extern "C" fn(
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
        ) -> *mut c_void = std::mem::transmute(objc_msgSend as *const c_void);
        let stream = msg_init_stream(
            stream_alloc,
            sel_init_stream,
            filter,
            config,
            std::ptr::null_mut(), // no SCStreamDelegate for errors (we log in output)
        );
        if stream.is_null() {
            // Clean up context
            let _ = Box::from_raw(ctx_ptr);
            return Err("Failed to create SCStream".to_string());
        }

        // Add our output delegate with a dispatch queue
        let queue = dispatch_get_global_queue(0, 0); // QOS_CLASS_DEFAULT
        let sel_add_output = sel_registerName(
            b"addStreamOutput:type:sampleHandlerQueue:error:\0".as_ptr() as *const c_char,
        );
        let msg_add_output: extern "C" fn(
            *mut c_void,
            *mut c_void,
            *mut c_void,
            c_long,
            *mut c_void,
            *mut *mut c_void,
        ) -> bool = std::mem::transmute(objc_msgSend as *const c_void);

        let mut add_error: *mut c_void = std::ptr::null_mut();
        let added = msg_add_output(
            stream,
            sel_add_output,
            delegate,
            1, // SCStreamOutputType.audio
            queue,
            &mut add_error,
        );
        if !added && !add_error.is_null() {
            let err_str = nsstring_to_rust(msg_send_void(
                add_error,
                sel_registerName(b"localizedDescription\0".as_ptr() as *const c_char),
            ));
            let _ = Box::from_raw(ctx_ptr);
            return Err(format!("Failed to add stream output: {}", err_str));
        }

        // Start capture using completion handler
        // SIGBUS FIX: Same raw-pointer-to-heap-context pattern as CompletionBlock.
        let start_sema = dispatch_semaphore_create(0);
        let start_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        struct StartBlockContext {
            error_result: Arc<Mutex<Option<String>>>,
            semaphore: *mut c_void,
        }

        #[repr(C)]
        struct StartBlock {
            isa: *const c_void,
            flags: i32,
            reserved: i32,
            invoke: extern "C" fn(*mut StartBlock, *mut c_void),
            descriptor: *const BlockDescriptor,
            context: *mut StartBlockContext,
        }

        extern "C" fn start_invoke(block: *mut StartBlock, error: *mut c_void) {
            unsafe {
                let block = &*block;
                let ctx = &*block.context;
                if !error.is_null() {
                    let sel_desc = sel_registerName(
                        b"localizedDescription\0".as_ptr() as *const c_char,
                    );
                    let msg: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
                        std::mem::transmute(objc_msgSend as *const c_void);
                    let desc = msg(error, sel_desc);
                    let err_str = nsstring_to_rust(desc);
                    if let Some(mut guard) = ctx.error_result.lock().ok() {
                        *guard = Some(err_str);
                    }
                }
                dispatch_semaphore_signal(ctx.semaphore);
            }
        }

        let start_block_ctx = Box::into_raw(Box::new(StartBlockContext {
            error_result: start_error.clone(),
            semaphore: start_sema,
        }));

        let start_descriptor = BlockDescriptor {
            reserved: 0,
            size: std::mem::size_of::<StartBlock>() as u64,
        };

        let start_block = StartBlock {
            isa: &_NSConcreteStackBlock as *const _ as *const c_void,
            flags: 0,
            reserved: 0,
            invoke: start_invoke,
            descriptor: &start_descriptor,
            context: start_block_ctx,
        };

        let sel_start = sel_registerName(
            b"startCaptureWithCompletionHandler:\0".as_ptr() as *const c_char,
        );
        let msg_start: extern "C" fn(*mut c_void, *mut c_void, *const StartBlock) =
            std::mem::transmute(objc_msgSend as *const c_void);
        msg_start(stream, sel_start, &start_block);

        dispatch_semaphore_wait(start_sema, DISPATCH_TIME_FOREVER);
        let _ = Box::from_raw(start_block_ctx);

        if let Some(err) = start_error.lock().map_err(|e| e.to_string())?.take() {
            let _ = Box::from_raw(ctx_ptr);
            return Err(format!("Failed to start SCStream: {}", err));
        }

        log::info!("ScreenCaptureKit stream started successfully");

        // ── Step 8: Block until stop signal ─────────────────────────────────
        while !stop_signal.load(Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }

        // ── Step 9: Stop the stream ─────────────────────────────────────────
        let stop_sema = dispatch_semaphore_create(0);
        let stop_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        struct StopBlockContext {
            error_result: Arc<Mutex<Option<String>>>,
            semaphore: *mut c_void,
        }

        #[repr(C)]
        struct StopBlock {
            isa: *const c_void,
            flags: i32,
            reserved: i32,
            invoke: extern "C" fn(*mut StopBlock, *mut c_void),
            descriptor: *const BlockDescriptor,
            context: *mut StopBlockContext,
        }

        extern "C" fn stop_invoke(block: *mut StopBlock, error: *mut c_void) {
            unsafe {
                let block = &*block;
                let ctx = &*block.context;
                if !error.is_null() {
                    let sel_desc = sel_registerName(
                        b"localizedDescription\0".as_ptr() as *const c_char,
                    );
                    let msg: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
                        std::mem::transmute(objc_msgSend as *const c_void);
                    let desc = msg(error, sel_desc);
                    let err_str = nsstring_to_rust(desc);
                    if let Some(mut guard) = ctx.error_result.lock().ok() {
                        *guard = Some(err_str);
                    }
                }
                dispatch_semaphore_signal(ctx.semaphore);
            }
        }

        let stop_block_ctx = Box::into_raw(Box::new(StopBlockContext {
            error_result: stop_error.clone(),
            semaphore: stop_sema,
        }));

        let stop_descriptor = BlockDescriptor {
            reserved: 0,
            size: std::mem::size_of::<StopBlock>() as u64,
        };

        let stop_block = StopBlock {
            isa: &_NSConcreteStackBlock as *const _ as *const c_void,
            flags: 0,
            reserved: 0,
            invoke: stop_invoke,
            descriptor: &stop_descriptor,
            context: stop_block_ctx,
        };

        let sel_stop = sel_registerName(
            b"stopCaptureWithCompletionHandler:\0".as_ptr() as *const c_char,
        );
        let msg_stop: extern "C" fn(*mut c_void, *mut c_void, *const StopBlock) =
            std::mem::transmute(objc_msgSend as *const c_void);
        msg_stop(stream, sel_stop, &stop_block);

        dispatch_semaphore_wait(stop_sema, DISPATCH_TIME_FOREVER);
        let _ = Box::from_raw(stop_block_ctx);

        if let Some(err) = stop_error.lock().map_err(|e| e.to_string())?.take() {
            log::warn!("Error stopping SCStream (non-fatal): {}", err);
        }

        log::info!("ScreenCaptureKit stream stopped");

        // C2 FIX: Remove the stream output before freeing the context.
        // This ensures no in-flight GCD callbacks can reference ctx_ptr after we free it.
        let sel_remove_output = sel_registerName(
            b"removeStreamOutput:type:\0".as_ptr() as *const c_char,
        );
        let msg_remove_output: extern "C" fn(*mut c_void, *mut c_void, *mut c_void, c_long) =
            std::mem::transmute(objc_msgSend as *const c_void);
        msg_remove_output(stream, sel_remove_output, delegate, 1); // SCStreamOutputType.audio

        // Barrier: dispatch_sync on the same global queue to drain any in-flight callbacks.
        // After this returns, no more callbacks can be running that reference ctx_ptr.
        extern "C" {
            fn dispatch_sync_f(
                queue: *mut c_void,
                context: *mut c_void,
                work: extern "C" fn(*mut c_void),
            );
        }
        extern "C" fn noop_barrier(_ctx: *mut c_void) {}
        dispatch_sync_f(queue, std::ptr::null_mut(), noop_barrier);

        // Now safe to free the CaptureContext
        // Clear the ivar first to prevent any stale access
        object_setInstanceVariable(
            delegate,
            b"_captureCtx\0".as_ptr() as *const c_char,
            std::ptr::null_mut(),
        );
        let _ = Box::from_raw(ctx_ptr);

        // I2 FIX: Release all ObjC objects to prevent leaks
        let sel_release = sel_registerName(b"release\0".as_ptr() as *const c_char);
        msg_send_void0(stream, sel_release);
        msg_send_void0(filter, sel_release);
        msg_send_void0(config, sel_release);
        msg_send_void0(delegate, sel_release);
        msg_send_void0(excluded_apps, sel_release);
        msg_send_void0(empty_array, sel_release);
        msg_send_void0(content, sel_release);

        Ok(())
    }
}

/// Convert an NSString to a Rust String.
#[cfg(target_os = "macos")]
unsafe fn nsstring_to_rust(nsstr: *mut c_void) -> String {
    if nsstr.is_null() {
        return String::from("(null)");
    }
    let sel_utf8 = sel_registerName(b"UTF8String\0".as_ptr() as *const c_char);
    let msg: extern "C" fn(*mut c_void, *mut c_void) -> *const c_char =
        std::mem::transmute(objc_msgSend as *const c_void);
    let cstr = msg(nsstr, sel_utf8);
    if cstr.is_null() {
        return String::from("(null)");
    }
    std::ffi::CStr::from_ptr(cstr)
        .to_string_lossy()
        .into_owned()
}
