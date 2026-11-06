#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/scripts/run-test.sh" CredentialProcessTests "$@"
