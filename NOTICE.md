# Third-party notices

FocusVoice is MIT licensed. The following components have their own licenses.

| Component | License | Location |
|---|---|---|
| sherpa-onnx 1.13.8 (vendored C API dylibs) | Apache-2.0 | `Vendor/sherpa/LICENSE` |
| ONNX Runtime (vendored dylib) | MIT | https://github.com/microsoft/onnxruntime |
| whisper.cpp (experimental vendor, not used by the current engine) | MIT | `Vendor/whisper/LICENSE` |
| SenseVoiceSmall int8 ONNX model | Upstream model license | Downloaded at runtime, not bundled |
| Silero VAD | MIT | Downloaded at runtime, not bundled |

The app may optionally read sound files already installed by macOS. Those files
are never redistributed in this repository. Bundled sounds are original
synthesized tones (see `Resources/Sounds/README.md`).

Product screenshots and demo GIFs are original FocusVoice assets.
