// whisper-bridge.c
// MeetNotesApp — US-016
//
// Stub implementation of the whisper C bridge.
// TODO: Replace with real whisper.cpp calls once the library is vendored.
//
// This file compiles cleanly but every function is a no-op / returns
// an error sentinel so that the Swift layer can fall back gracefully.

#include "whisper-bridge.h"
#include <stdlib.h>

// MARK: - Stub implementation

struct wb_context {
    int dummy;
};

wb_context *wb_init(const char *model_path) {
    (void)model_path;
    // TODO: Call whisper_init_from_file(model_path) and store the real context.
    return NULL; // Signal "not available" so Swift falls back.
}

void wb_free(wb_context *ctx) {
    if (ctx) {
        free(ctx);
    }
}

int wb_transcribe(wb_context *ctx,
                  const char *audio_path,
                  wb_progress_cb progress_cb,
                  void *user_data) {
    (void)ctx;
    (void)audio_path;
    (void)progress_cb;
    (void)user_data;
    return -1; // Not implemented.
}

const wb_segment *wb_get_segment(wb_context *ctx, int index) {
    (void)ctx;
    (void)index;
    return NULL;
}
