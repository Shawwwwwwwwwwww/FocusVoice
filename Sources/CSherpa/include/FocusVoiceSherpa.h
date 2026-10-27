#ifndef FOCUSVOICE_SHERPA_H
#define FOCUSVOICE_SHERPA_H

// Minimal C shim over the sherpa-onnx C API (vendored v1.13.8) so that Swift
// never has to build the large SherpaOnnxOfflineRecognizerConfig struct itself.
//
// Model / language configuration used by this shim mirrors the DeepSeek Harness
// built-in speech input worker (SenseVoiceSmall int8 + Silero VAD, CPU):
//   - senseVoice.language = "auto" (or the per-session hint), use_itn = 1
//   - numThreads = 2, provider = "cpu"
//   - VAD: threshold 0.5, minSpeech 0.25s, minSilence 0.5s, maxSpeech 20s,
//     windowSize 512, sampleRate 16000
//
// All functions are synchronous and NOT thread safe: call them from a single
// serial queue. Text returned by `fv_sherpa_recognize_*` / `fv_sherpa_stream_take_segment`
// is malloc'ed UTF-8 owned by the caller; free it with `fv_sherpa_free_text`.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FVSherpa FVSherpa;

// Returns the vendored sherpa-onnx version string (e.g. "1.13.8").
const char *fv_sherpa_version(void);

// Loads the SenseVoice recognizer (model.int8.onnx + tokens.txt) and the Silero
// VAD model. `num_threads` <= 0 falls back to 2. `max_speech_seconds` <= 0
// falls back to 20.0. Returns NULL on failure and writes a message into
// `err_buf` (when non-NULL and err_buf_len > 0).
FVSherpa *fv_sherpa_create(const char *model_path, const char *tokens_path,
                           const char *vad_model_path, int32_t num_threads,
                           float max_speech_seconds, char *err_buf,
                           size_t err_buf_len);

void fv_sherpa_destroy(FVSherpa *handle);

// One-shot recognition of 16 kHz mono float32 PCM in [-1, 1].
// `language` may be NULL to keep the current session language.
// Returns malloc'ed UTF-8 text (never NULL on success) or NULL on error.
char *fv_sherpa_recognize_float(FVSherpa *handle, const float *samples,
                                int32_t n, const char *language);

// Same as above but takes little-endian 16-bit PCM (what a mic callback gives).
char *fv_sherpa_recognize_pcm16(FVSherpa *handle, const int16_t *samples,
                                int32_t n, const char *language);

void fv_sherpa_free_text(char *text);

// ---- Streaming session (VAD state lives inside the handle) ----------------

// Resets VAD state and applies the language hint ("auto", "zh", "en", ...).
void fv_sherpa_stream_reset(FVSherpa *handle, const char *language);

// Feeds 16 kHz mono float32 PCM. Samples are appended to the VAD's internal
// buffer; completed speech segments become available through
// fv_sherpa_stream_has_segment / fv_sherpa_stream_take_segment.
void fv_sherpa_stream_feed(FVSherpa *handle, const float *samples, int32_t n);

// 1 when a completed speech segment is queued, 0 otherwise.
int32_t fv_sherpa_stream_has_segment(FVSherpa *handle);

// Recognizes and pops the oldest completed segment. Writes the segment start
// index and sample count (in the VAD timeline) through out_start / out_n when
// non-NULL. Returns malloc'ed UTF-8 text or NULL when empty/failed.
char *fv_sherpa_stream_take_segment(FVSherpa *handle, int32_t *out_start,
                                    int32_t *out_n);

// Pops the oldest completed segment WITHOUT decoding it and hands back a
// malloc'ed copy of its samples (free with fv_sherpa_free_samples). The caller
// can prepend audio that precedes segment.start (onset padding) and decode the
// merged buffer itself. Returns 1 on success, 0 when no segment is queued.
int32_t fv_sherpa_stream_take_segment_audio(FVSherpa *handle, int32_t *out_start,
                                            int32_t *out_n, float **out_samples);

void fv_sherpa_free_samples(float *samples);

// Pads the pending sub-window tail with silence, then forces the in-progress
// segment to be emitted (call once before the final drain at end of stream).
void fv_sherpa_stream_flush(FVSherpa *handle);

// Drops queued segments (cancel path); does not reset the VAD state.
void fv_sherpa_stream_clear(FVSherpa *handle);

// 1 while speech is currently in progress according to the VAD.
int32_t fv_sherpa_stream_detected(FVSherpa *handle);

#ifdef __cplusplus
}
#endif

#endif  // FOCUSVOICE_SHERPA_H
