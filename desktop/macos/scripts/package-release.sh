#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/scripts/build-app.sh"
app_dir=${BAD_MEETING_APP_DIR:-$project_dir/dist/Bad Meeting.app}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
build_arch=$(uname -m)
archive="$project_dir/dist/Bad-Meeting-$version-macos-$build_arch.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
(cd "$project_dir/dist" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
print -- "$archive"
