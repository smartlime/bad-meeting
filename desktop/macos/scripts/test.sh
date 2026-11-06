#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
for test in MeetingTests ProviderTests ProviderNetworkTests TranscriptionTests RecordingLifecycleTests SpeechKitTests MeetingLinkTests CredentialProcessTests; do
  "$project_dir/scripts/run-test.sh" "$test"
done
