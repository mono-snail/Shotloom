#!/bin/bash
# Opens a previously saved local recipe. Does not capture or deliver automatically.
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo 'Usage: deskcapture-workflow.sh SAVED-RECIPE-UUID' >&2
    exit 64
fi
/usr/bin/open "deskcapture://workflow?id=${1}"
