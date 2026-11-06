#!/bin/zsh
# UI-only review. No captures, device sessions, release bundles or user preferences.
set -euo pipefail
cd "${0:A:h:h}"
swift build > build/ui-layout-build.log 2>&1
task_products=$(swift build --show-bin-path)
task_arch=$(uname -m)
task_objects="$PWD/.build/out/Intermediates.noindex/DeskCapture.build/Debug/DeskCapture-p.build/Objects-normal/$task_arch"
if [[ ! -f "$task_objects/DeskCapture.swiftmodule" ]]; then
  print -u2 'This preview linker expects the Xcode SwiftPM object layout; see docs/UI布局统一检查.md.'
  exit 1
fi
objects=("$task_objects"/*.o)
objects=(${objects:#*/main.o})
objects=(${objects:#*/WorkflowAppIntents.o})
# The object-directory module is current; Products/Debug may retain an older interface.
swiftc -Onone -swift-version 5 -D UI_REVIEW_MODULE -parse-as-library \
  -I "$task_objects" -I "$task_products" -F "$task_products" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$task_products" \
  scripts/UILayoutPreview.swift "${objects[@]}" -o build/UILayoutReview > build/ui-layout-review-link.log 2>&1
task_preview_home=$(mktemp -d /tmp/deskcapture-ui-XXXXXX)
print -r -- "$task_preview_home" > build/ui-layout-preview-home.txt
CFFIXED_USER_HOME="$task_preview_home" DESKCAPTURE_DIAGNOSTIC_DIR="$task_preview_home/review" \
  build/UILayoutReview "${@}" > build/ui-layout-review-run.log 2>&1
print -r -- "UI preview artifacts: $task_preview_home/review"
