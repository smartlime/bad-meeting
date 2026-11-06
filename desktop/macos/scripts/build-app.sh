#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${BAD_MEETING_CONFIGURATION:-release}
signing_identity=${BAD_MEETING_SIGNING_IDENTITY:--}
sdk=${BAD_MEETING_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
if [[ ! -d $sdk ]]; then
  sdk=$(xcrun --show-sdk-path)
fi

export SDKROOT=$sdk
export CLANG_MODULE_CACHE_PATH=$project_dir/.cache/clang
export SWIFTPM_MODULECACHE_OVERRIDE=$project_dir/.cache/swift
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

cd "$project_dir"
swift build --disable-sandbox --disable-build-manifest-caching \
  --sdk "$sdk" --scratch-path "$project_dir/.build" \
  -debug-info-format none -c "$configuration"
bin_dir=$(swift build --disable-sandbox --disable-build-manifest-caching \
  --sdk "$sdk" --scratch-path "$project_dir/.build" \
  -c "$configuration" --show-bin-path)

app_dir=${BAD_MEETING_APP_DIR:-$project_dir/dist/Bad Meeting.app}
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/BadMeeting" "$app_dir/Contents/MacOS/BadMeeting"
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Resources"
for resource_bundle in "$bin_dir"/*.bundle(N); do
  cp -R "$resource_bundle" "$app_dir/Contents/Resources/"
done
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
print -- "$app_dir"
