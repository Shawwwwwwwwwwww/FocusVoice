#!/bin/zsh
# Generates the real Chinese test audio used to validate the SenseVoice engine.
# Output: /tmp/focusvoice-audio/*.wav (16 kHz / mono / 16-bit LE PCM)
set -euo pipefail

OUT="${1:-/tmp/focusvoice-audio}"
mkdir -p "$OUT"

synth() {
  local name="$1"
  local phrase="$2"
  say -v Tingting "$phrase" -o "$OUT/$name.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$name.aiff" "$OUT/$name.wav"
  rm -f "$OUT/$name.aiff"
  local seconds
  seconds=$(afinfo "$OUT/$name.wav" | awk '/estimated duration/ {print $3}')
  echo "$name.wav  ${seconds}s"
}

synth zh_4s "今天下午三点开会，记得带上项目文档"
synth zh_7s "我们需要在本周之前完成语音识别模块的本地化改造，确保离线也能使用"
synth zh_3s "明天上午十点开产品评审会"
synth zh_5s "麻烦你下班之前把设计方案的初稿发到我的邮箱"
synth zh_short "好的谢谢"

print -r -- ""
print -r -- "audio written to $OUT"
