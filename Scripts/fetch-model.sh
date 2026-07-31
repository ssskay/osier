#!/bin/bash
set -e
# Fetch the default Whisper model (and the standard test clip) for local dev.
# The app downloads models itself on first run; this is only a convenience so a
# fresh clone can run tests offline-ish. Both files are gitignored.
cd "$(dirname "$0")/.."

MODEL="ggml-tiny.en.bin"
if [ ! -f "$MODEL" ]; then
  echo "Downloading ${MODEL} (~75 MB)…"
  curl -L -o "$MODEL" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
else
  echo "${MODEL} already present."
fi

if [ ! -f jfk.wav ] && [ -f libwhisper/whisper.cpp/samples/jfk.wav ]; then
  cp libwhisper/whisper.cpp/samples/jfk.wav .
  echo "Copied jfk.wav from the whisper.cpp submodule."
fi
