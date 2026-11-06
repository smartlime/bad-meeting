#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
sdk=${BAD_MEETING_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
[[ -d $sdk ]] || sdk=$(xcrun --show-sdk-path)
cd "$project_dir"
build_arch=$(uname -m)
mkdir -p .cache/swiftc
module_cache=$(cd .cache/swiftc && pwd -P)
mkdir -p .build/checks .cache/swiftc
sources=(Sources/BadMeeting/*.swift)
sources=(${sources:#*BadMeetingApp.swift})
cat > .build/checks/Resources.swift <<'SWIFT'
import Foundation
extension Bundle {
    static let module = Bundle(path: ProcessInfo.processInfo.environment["BAD_MEETING_RESOURCE_BUNDLE"]!)!
}
SWIFT
fingerprint=$(cat $sources .build/checks/Resources.swift | shasum -a 256 | cut -d ' ' -f 1)
if [[ ! -f .build/checks/fingerprint || $(cat .build/checks/fingerprint) != $fingerprint ]]; then
  swiftc -j 1 -sdk "$sdk" -target "$build_arch-apple-macosx14.2" -module-cache-path "$module_cache" \
    -emit-library -emit-module -enable-testing -module-name BadMeetingKit -parse-as-library \
    -emit-module-path .build/checks/BadMeetingKit.swiftmodule -o .build/checks/libBadMeetingKit.dylib \
    $sources .build/checks/Resources.swift
  print -r -- "$fingerprint" > .build/checks/fingerprint
fi
