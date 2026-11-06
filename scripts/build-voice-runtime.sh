#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/voice-runtime/objects
fetch() {
  local file="$1" source_url="$2" expected_sha="$3"
  if [[ ! -f "$file" ]]; then
    curl --fail --location --connect-timeout 15 --max-time 180 "$source_url" -o "$file.download"
    mv "$file.download" "$file"
  fi
  [[ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" == "$expected_sha" ]] || { print -u2 "Voice dependency checksum mismatch: $file"; exit 1; }
}
fetch build/r39-rnnoise-0.2.tar.gz https://github.com/xiph/rnnoise/archive/refs/tags/v0.2.tar.gz e4a17eb1493b7551f9f7781d2acc67b8847d6ed7c4b64db0fd62c017021ae1ec
fetch build/r39-rnnoise-data.tar.gz https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz 4ac81c5c0884ec4bd5907026aaae16209b7b76cd9d7f71af582094a2f98f4b43
fetch build/r39-ebur128.tar.gz https://github.com/jiixyj/libebur128/archive/refs/tags/v1.2.6.tar.gz baa7fc293a3d4651e244d8022ad03ab797ca3c2ad8442c43199afe8059faa613
[[ -d build/rnnoise-0.2 ]] || tar -xzf build/r39-rnnoise-0.2.tar.gz -C build
[[ -d build/libebur128-1.2.6 ]] || tar -xzf build/r39-ebur128.tar.gz -C build
tar -xzf build/r39-rnnoise-data.tar.gz -C build/rnnoise-0.2 src/rnnoise_data.c src/rnnoise_data.h
for unit in denoise rnn pitch kiss_fft celt_lpc nnet nnet_default parse_lpcnet_weights rnnoise_data rnnoise_tables; do
  xcrun clang -O3 -std=c99 -mmacosx-version-min=15.0 -DRNNOISE_BUILD -Iscripts/voice-compat -Ibuild/rnnoise-0.2/include -Ibuild/rnnoise-0.2/src -c "build/rnnoise-0.2/src/$unit.c" -o "build/voice-runtime/objects/$unit.o"
done
xcrun clang -O3 -std=c99 -mmacosx-version-min=15.0 -Ibuild/libebur128-1.2.6/ebur128 -c build/libebur128-1.2.6/ebur128/ebur128.c -o build/voice-runtime/objects/ebur128.o
xcrun clang++ -O3 -std=c++17 -mmacosx-version-min=15.0 -Ibuild/rnnoise-0.2/include -Ibuild/libebur128-1.2.6/ebur128 scripts/VoiceRuntime.cpp build/voice-runtime/objects/*.o -o build/voice-runtime/desk-voice
cp build/rnnoise-0.2/COPYING build/voice-runtime/RNNoise-COPYING.txt
cp build/libebur128-1.2.6/COPYING build/voice-runtime/libebur128-COPYING.txt
: > build/voice-runtime/RNNoise-SOURCE-NOTICES.txt
for notice_source in build/rnnoise-0.2/src/*.c build/rnnoise-0.2/src/*.h build/rnnoise-0.2/include/*.h; do
  print "Source: $notice_source" >> build/voice-runtime/RNNoise-SOURCE-NOTICES.txt
  head -80 "$notice_source" >> build/voice-runtime/RNNoise-SOURCE-NOTICES.txt
done
