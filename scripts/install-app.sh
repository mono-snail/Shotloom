#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="$PWD/build/DeskCapture.app"
destination_app="${1:-$HOME/Applications/DeskCapture.app}"
# These checks run on the final candidate, without launching or terminating apps.
python3 scripts/audit-app-compatibility.py "$source_app" --output build/install-compatibility-audit.json
python3 scripts/safe-app-install.py "$source_app" "$destination_app"
