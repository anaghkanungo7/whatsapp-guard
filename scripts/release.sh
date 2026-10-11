#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
"$repo_dir/scripts/build.sh"
mkdir -p "$repo_dir/dist"
ditto -c -k --keepParent "$repo_dir/build/WhatsApp Guard.app" "$repo_dir/dist/WhatsApp-Guard-macOS.zip"
(cd "$repo_dir/dist"; shasum -a 256 WhatsApp-Guard-macOS.zip > SHA256SUMS.txt)
print "Release files are in $repo_dir/dist"
