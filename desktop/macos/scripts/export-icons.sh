#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
source_dir=$project_dir/Resources/IconSources
menu_dir=$project_dir/Sources/BadMeeting/MenuBar
iconset_dir=$project_dir/.build/AppIcon.iconset
mkdir -p "$menu_dir" "$iconset_dir"
rsvg-convert "$source_dir/Dock.svg" -o "$project_dir/Resources/AppIcon.png"
cp "$project_dir/Resources/AppIcon.png" "$project_dir/Resources/AppIcon-Dock.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$project_dir/Resources/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$project_dir/Resources/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
python3 - "$iconset_dir" "$project_dir/Resources/AppIcon.icns" <<'PYICON'
from pathlib import Path
import struct
import sys
source = Path(sys.argv[1])
formats = [('icp4', '16x16'), ('icp5', '32x32'), ('ic07', '128x128'),
           ('ic08', '256x256'), ('ic09', '512x512'), ('ic10', '512x512@2x'),
           ('ic11', '16x16@2x'), ('ic12', '32x32@2x'),
           ('ic13', '128x128@2x'), ('ic14', '256x256@2x')]
chunks = []
for kind, size in formats:
    data = (source / f'icon_{size}.png').read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
Path(sys.argv[2]).write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
PYICON
if [[ ${1:-} == --app-only ]]; then
  exit 0
fi
for scale in 1 2; do
  suffix=''
  [[ $scale == 2 ]] && suffix='@2x'
  dimension=$((18 * scale))
  rsvg-convert -w "$dimension" -h "$dimension" "$source_dir/MenuIdle.svg" -o "$menu_dir/Cassette${suffix}.png"
  rsvg-convert -w "$dimension" -h "$dimension" "$source_dir/RecordingBadge.svg" -o "$menu_dir/RecordingBadge${suffix}.png"
done
