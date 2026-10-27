// C shim over the vendored sherpa-onnx C API. See FocusVoiceSherpa.h.
//
// The canonical c-api.h lives in Vendor/sherpa/include (fetched from the
// sherpa-onnx v1.13.8 tag); it is included by relative path so the vendored
// header stays the single source of truth.
#include "../../Vendor/sherpa/include/c-api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FocusVoiceSherpa.h"

struct FVSherpa {
  const SherpaOnnxOfflineRecognizer *recognizer;
  const SherpaOnnxVoiceActivityDetector *vad;
  // Owned copies of the caller paths: cfg.* string fields point into them.
  char *model_path;
  char *tokens_path;
  char *vad_path;
  // Language hint currently applied to the recognizer config.
  char language[16];
  SherpaOnnxOfflineRecognizerConfig cfg;
};

static const int32_t kSampleRate = 16000;
static const int32_t kVadWindow = 512;

static void fv_copy_error(char *err_buf, size_t err_buf_len, const char *msg) {
  if (!err_buf || err_buf_len == 0) return;
  if (!msg) msg = "";
  size_t n = strlen(msg);
  if (n >= err_buf_len) n = err_buf_len - 1;
  memcpy(err_buf, msg, n);
  err_buf[n] = '\0';
}

static char *fv_strdup(const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s);
  char *out = (char *)malloc(n + 1);
  if (out) memcpy(out, s, n + 1);
  return out;
}

static void fv_set_language(FVSherpa *h, const char *language) {
  if (!h || !h->recognizer || !language || !language[0]) return;
  if (strncmp(h->language, language, sizeof(h->language) - 1) == 0) return;
  snprintf(h->language, sizeof(h->language), "%s", language);
  h->cfg.model_config.sense_voice.language = h->language;
  SherpaOnnxOfflineRecognizerSetConfig(h->recognizer, &h->cfg);
}

// Creates a fresh offline stream, decodes it and returns malloc'ed UTF-8.
static char *fv_decode_float(FVSherpa *h, const float *samples, int32_t n) {
  if (!h || !h->recognizer || !samples || n < 0) return NULL;
  const SherpaOnnxOfflineStream *stream =
      SherpaOnnxCreateOfflineStream(h->recognizer);
  if (!stream) return NULL;
  SherpaOnnxAcceptWaveformOffline(stream, kSampleRate, samples, n);
  SherpaOnnxDecodeOfflineStream(h->recognizer, stream);
  const SherpaOnnxOfflineRecognizerResult *result =
      SherpaOnnxGetOfflineStreamResult(stream);
  char *text = NULL;
  if (result) {
    text = fv_strdup(result->text ? result->text : "");
    SherpaOnnxDestroyOfflineRecognizerResult(result);
  }
  SherpaOnnxDestroyOfflineStream(stream);
  return text;
}

const char *fv_sherpa_version(void) { return SherpaOnnxGetVersionStr(); }

FVSherpa *fv_sherpa_create(const char *model_path, const char *tokens_path,
                           const char *vad_model_path, int32_t num_threads,
                           float max_speech_seconds, char *err_buf,
                           size_t err_buf_len) {
  if (!model_path || !tokens_path || !vad_model_path) {
    fv_copy_error(err_buf, err_buf_len, "sherpa: model/tokens/vad path is NULL");
    return NULL;
  }
  FVSherpa *h = (FVSherpa *)calloc(1, sizeof(FVSherpa));
  if (!h) {
    fv_copy_error(err_buf, err_buf_len, "sherpa: out of memory");
    return NULL;
  }
  h->model_path = fv_strdup(model_path);
  h->tokens_path = fv_strdup(tokens_path);
  h->vad_path = fv_strdup(vad_model_path);
  if (!h->model_path || !h->tokens_path || !h->vad_path) {
    fv_sherpa_destroy(h);
    fv_copy_error(err_buf, err_buf_len, "sherpa: out of memory");
    return NULL;
  }
  if (num_threads <= 0) num_threads = 2;
  if (max_speech_seconds <= 0.0f) max_speech_seconds = 20.0f;
  snprintf(h->language, sizeof(h->language), "auto");

  // ---- recognizer (SenseVoice, CPU, ITN on) ----
  memset(&h->cfg, 0, sizeof(h->cfg));
  h->cfg.feat_config.sample_rate = kSampleRate;
  h->cfg.feat_config.feature_dim = 80;
  h->cfg.model_config.sense_voice.model = h->model_path;
  h->cfg.model_config.sense_voice.language = h->language;
  h->cfg.model_config.sense_voice.use_itn = 1;
  h->cfg.model_config.tokens = h->tokens_path;
  h->cfg.model_config.num_threads = num_threads;
  h->cfg.model_config.provider = "cpu";
  h->cfg.model_config.debug = 0;
  h->cfg.decoding_method = "greedy_search";

  h->recognizer = SherpaOnnxCreateOfflineRecognizer(&h->cfg);
  if (!h->recognizer) {
    fv_sherpa_destroy(h);
    fv_copy_error(err_buf, err_buf_len,
                  "sherpa: cannot create offline recognizer "
                  "(model.int8.onnx / tokens.txt missing or unreadable)");
    return NULL;
  }

  // ---- VAD (Silero) ----
  SherpaOnnxVadModelConfig vad_cfg;
  memset(&vad_cfg, 0, sizeof(vad_cfg));
  vad_cfg.silero_vad.model = h->vad_path;
  vad_cfg.silero_vad.threshold = 0.5f;
  vad_cfg.silero_vad.min_silence_duration = 0.5f;
  vad_cfg.silero_vad.min_speech_duration = 0.25f;
  vad_cfg.silero_vad.max_speech_duration = max_speech_seconds;
  vad_cfg.silero_vad.window_size = kVadWindow;
  vad_cfg.sample_rate = kSampleRate;
  vad_cfg.num_threads = num_threads;
  vad_cfg.provider = "cpu";
  vad_cfg.debug = 0;
  h->vad = SherpaOnnxCreateVoiceActivityDetector(&vad_cfg,
                                                 max_speech_seconds + 2.0f);
  if (!h->vad) {
    fv_sherpa_destroy(h);
    fv_copy_error(err_buf, err_buf_len,
                  "sherpa: cannot create Silero VAD "
                  "(silero_vad.onnx missing or unreadable)");
    return NULL;
  }
  return h;
}

void fv_sherpa_destroy(FVSherpa *h) {
  if (!h) return;
  if (h->recognizer) SherpaOnnxDestroyOfflineRecognizer(h->recognizer);
  if (h->vad) SherpaOnnxDestroyVoiceActivityDetector(h->vad);
  free(h->model_path);
  free(h->tokens_path);
  free(h->vad_path);
  free(h);
}

char *fv_sherpa_recognize_float(FVSherpa *handle, const float *samples,
                                int32_t n, const char *language) {
  if (!handle) return NULL;
  fv_set_language(handle, language);
  return fv_decode_float(handle, samples, n);
}

char *fv_sherpa_recognize_pcm16(FVSherpa *handle, const int16_t *samples,
                                int32_t n, const char *language) {
  if (!handle || !samples || n <= 0) return NULL;
  float *floats = (float *)malloc((size_t)n * sizeof(float));
  if (!floats) return NULL;
  for (int32_t i = 0; i < n; ++i) floats[i] = (float)samples[i] / 32768.0f;
  fv_set_language(handle, language);
  char *text = fv_decode_float(handle, floats, n);
  free(floats);
  return text;
}

void fv_sherpa_free_text(char *text) { free(text); }

void fv_sherpa_free_samples(float *samples) { free(samples); }

void fv_sherpa_stream_reset(FVSherpa *handle, const char *language) {
  if (!handle || !handle->vad) return;
  fv_set_language(handle, language);
  SherpaOnnxVoiceActivityDetectorReset(handle->vad);
}

void fv_sherpa_stream_feed(FVSherpa *handle, const float *samples, int32_t n) {
  if (!handle || !handle->vad || !samples || n <= 0) return;
  SherpaOnnxVoiceActivityDetectorAcceptWaveform(handle->vad, samples, n);
}

int32_t fv_sherpa_stream_has_segment(FVSherpa *handle) {
  if (!handle || !handle->vad) return 0;
  return SherpaOnnxVoiceActivityDetectorEmpty(handle->vad) ? 0 : 1;
}

int32_t fv_sherpa_stream_take_segment_audio(FVSherpa *handle, int32_t *out_start,
                                           int32_t *out_n, float **out_samples) {
  if (!handle || !handle->vad) return 0;
  if (SherpaOnnxVoiceActivityDetectorEmpty(handle->vad)) return 0;
  const SherpaOnnxSpeechSegment *segment =
      SherpaOnnxVoiceActivityDetectorFront(handle->vad);
  if (!segment) return 0;
  if (out_start) *out_start = segment->start;
  if (out_n) *out_n = segment->n;
  if (out_samples) {
    float *copy = NULL;
    if (segment->n > 0) {
      copy = (float *)malloc((size_t)segment->n * sizeof(float));
      if (copy) memcpy(copy, segment->samples, (size_t)segment->n * sizeof(float));
    }
    *out_samples = copy;
  }
  SherpaOnnxDestroySpeechSegment(segment);
  SherpaOnnxVoiceActivityDetectorPop(handle->vad);
  return 1;
}

char *fv_sherpa_stream_take_segment(FVSherpa *handle, int32_t *out_start,
                                    int32_t *out_n) {
  if (!handle || !handle->vad) return NULL;
  if (SherpaOnnxVoiceActivityDetectorEmpty(handle->vad)) return NULL;
  const SherpaOnnxSpeechSegment *segment =
      SherpaOnnxVoiceActivityDetectorFront(handle->vad);
  if (!segment) return NULL;
  if (out_start) *out_start = segment->start;
  if (out_n) *out_n = segment->n;
  char *text = fv_decode_float(handle, segment->samples, segment->n);
  SherpaOnnxDestroySpeechSegment(segment);
  SherpaOnnxVoiceActivityDetectorPop(handle->vad);
  return text;
}

void fv_sherpa_stream_flush(FVSherpa *handle) {
  if (!handle || !handle->vad) return;
  // Push the pending sub-window tail (at most 511 samples) into the VAD so the
  // final Flush() covers every audio sample that was fed.
  float zeros[512];
  memset(zeros, 0, sizeof(zeros));
  SherpaOnnxVoiceActivityDetectorAcceptWaveform(handle->vad, zeros, kVadWindow);
  SherpaOnnxVoiceActivityDetectorFlush(handle->vad);
}

void fv_sherpa_stream_clear(FVSherpa *handle) {
  if (!handle || !handle->vad) return;
  SherpaOnnxVoiceActivityDetectorClear(handle->vad);
}

int32_t fv_sherpa_stream_detected(FVSherpa *handle) {
  if (!handle || !handle->vad) return 0;
  return SherpaOnnxVoiceActivityDetectorDetected(handle->vad) ? 1 : 0;
}
