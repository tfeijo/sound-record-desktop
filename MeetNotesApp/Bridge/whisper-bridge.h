// whisper-bridge.h
// MeetNotesApp — US-016
//
// Simplified C bridge header for whisper.cpp integration.
// When whisper.cpp is vendored (Xcode project), this header wraps the
// whisper.h API into a minimal surface that Swift can call via a bridging header.
//
// For now this file serves as the architectural placeholder; the actual
// implementation lives in whisper-bridge.c (stubbed) and will be replaced
// with real whisper.cpp calls once the C library is linked.

#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Types

/// Opaque context handle returned by wb_init.
typedef struct wb_context wb_context;

/// A single transcription segment produced by whisper.
typedef struct {
    int64_t start_ms;
    int64_t end_ms;
    const char *text;       // null-terminated, owned by the context
    const char *speaker;    // may be NULL if diarization is off
    float confidence;
} wb_segment;

/// Progress callback: (progress 0.0–1.0, user_data).
typedef void (*wb_progress_cb)(float progress, void *user_data);

// MARK: - Lifecycle

/// Initialise a whisper context from a GGML model file.
/// Returns NULL on failure.
wb_context *wb_init(const char *model_path);

/// Free all resources associated with a context.
void wb_free(wb_context *ctx);

// MARK: - Transcription

/// Run full transcription on a 16-kHz mono WAV file.
/// `progress_cb` and `user_data` may be NULL.
/// Returns the number of segments (>= 0), or -1 on error.
int wb_transcribe(wb_context *ctx,
                  const char *audio_path,
                  wb_progress_cb progress_cb,
                  void *user_data);

/// Retrieve a segment after a successful wb_transcribe call.
/// Index must be in [0, segment_count). Returns NULL on out-of-bounds.
const wb_segment *wb_get_segment(wb_context *ctx, int index);

#ifdef __cplusplus
}
#endif

#endif /* WHISPER_BRIDGE_H */
