#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
revision="d1be6fde11ac6e0407606b4e42fe72d34add8037"
archive="$PWD/build/r37-whisper-source.tar.gz"
expected="645445da884df6dbd52b30f82d7be7c01d1767c938714e477e786b88d529e9f4"
mkdir -p build
if [[ ! -f "$archive" ]]; then
  curl --fail --location --connect-timeout 15 --max-time 180 "https://github.com/ggml-org/whisper.cpp/archive/$revision.tar.gz" -o "$archive.download"
  mv "$archive.download" "$archive"
fi
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual" == "$expected" ]] || { print -u2 "Speech runtime source SHA-256 mismatch"; exit 1; }
source_dir="$PWD/build/whisper.cpp-$revision"
[[ -d "$source_dir" ]] || tar -xzf "$archive" -C build
cmake_bin="${DESKCAPTURE_CMAKE:-$(command -v cmake || true)}"
if [[ -z "$cmake_bin" && -x "$PWD/build/r37-tools/cmake/data/bin/cmake" ]]; then
  cmake_bin="$PWD/build/r37-tools/cmake/data/bin/cmake"
fi
[[ -x "$cmake_bin" ]] || { print -u2 "CMake is required to build the pinned local speech runtime. Set DESKCAPTURE_CMAKE."; exit 1; }
"$cmake_bin" -S "$source_dir" -B build/whisper-runtime -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_IS_DEV=OFF
"$cmake_bin" --build build/whisper-runtime --config Release --target whisper-cli --parallel 4
mkdir -p build/speech-licenses
cp "$source_dir/LICENSE" build/speech-licenses/whisper.cpp-LICENSE
cp "$source_dir/LICENSE" build/speech-licenses/ggml-LICENSE
tail -60 "$source_dir/examples/miniaudio.h" > build/speech-licenses/miniaudio-NOTICE.txt
tail -45 "$source_dir/examples/stb_vorbis.c" > build/speech-licenses/stb-vorbis-NOTICE.txt
print "Pinned whisper.cpp v1.9.5 ($revision), CPU/Accelerate, macOS deployment target 15.0"
