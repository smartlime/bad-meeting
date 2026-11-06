#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
sdk=${BAD_MEETING_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
[[ -d $sdk ]] || sdk=$(xcrun --show-sdk-path)
"$project_dir/scripts/build-test-module.sh"
cd "$project_dir"
build_arch=$(uname -m)
name=$1
shift
files=("Tests/$name.swift" Tests/TestFixtures.swift)
[[ $name == MeetingTests ]] && files+=(Tests/CalendarTests.swift)
export BAD_MEETING_RESOURCE_BUNDLE="$project_dir/.build/checks/BadMeeting.bundle"
mkdir -p "$BAD_MEETING_RESOURCE_BUNDLE"
cp -R Sources/BadMeeting/MenuBar Sources/BadMeeting/GitHubMark.svg "$BAD_MEETING_RESOURCE_BUNDLE/"
[[ -d Sources/BadMeeting/CalendarBridge ]] && cp -R Sources/BadMeeting/CalendarBridge "$BAD_MEETING_RESOURCE_BUNDLE/"
swiftc -sdk "$sdk" -target "$build_arch-apple-macosx14.2" -module-cache-path "$project_dir/.cache/swiftc" \
  -parse-as-library -I .build/checks -L .build/checks -lBadMeetingKit \
  -Xlinker -rpath -Xlinker "$project_dir/.build/checks" -o ".build/checks/$name" $files
".build/checks/$name" "$@"
