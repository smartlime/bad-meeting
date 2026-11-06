#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/scripts/run-test.sh" ToolbarLayoutTests --build-only
export BAD_MEETING_RESOURCE_BUNDLE="$project_dir/.build/checks/BadMeeting.bundle"
binary="$project_dir/.build/checks/ToolbarLayoutTests"
xcrun vtool -set-build-version macos 14.2 14.2 -replace -output "$binary-compat" "$binary"
codesign --force --sign - "$binary-compat"
if [[ ${1:-} != --build-only ]]; then
  "$binary"
  "$binary-compat" --legacy-sdk
fi
