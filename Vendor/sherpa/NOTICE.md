# sherpa-onnx runtime (vendored, read-only)

- Source: sherpa-onnx v1.13.8 prebuilt darwin arm64 Node binding
  (`sherpa-onnx-darwin-arm64`, shipped with DeepSeek Harness 0.2.1-rc.2,
  npm dependency `sherpa-onnx-node@1.13.8`)
- Original location:
  `/Applications/DeepSeek Harness.app/Contents/Resources/app.asar.unpacked/dsh/node_modules/sherpa-onnx-darwin-arm64/`
- Files: `libsherpa-onnx-c-api.dylib`, `libsherpa-onnx-cxx-api.dylib`,
  `libonnxruntime.dylib`
- Header: `include/c-api.h`, fetched from
  https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h
  (tag `v1.13.8`, verified present)
- License: Apache-2.0 (see `LICENSE`); onnxruntime is MIT (bundled inside
  `libonnxruntime.dylib`).

All three dylibs use `@rpath/...` install names, so the loading executable must
carry an `LC_RPATH` entry pointing at the directory that contains them:

- bundled app: `@loader_path/../Resources/sherpa`
- development builds: absolute `Vendor/sherpa` (injected by Package.swift linker flags)
