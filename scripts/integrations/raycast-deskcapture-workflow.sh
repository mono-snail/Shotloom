#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Open DeskCapture Workflow
# @raycast.mode silent
# @raycast.packageName DeskCapture
# @raycast.argument1 { "type": "text", "placeholder": "Saved workflow UUID" }
# @raycast.description Open a saved local recipe for review and execution in DeskCapture.
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo 'Provide the UUID from a saved DeskCapture workflow link.' >&2
    exit 64
fi
/usr/bin/open "deskcapture://workflow?id=${1}"
