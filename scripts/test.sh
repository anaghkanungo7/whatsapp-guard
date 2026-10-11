#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
app_binary="$repo_dir/build/WhatsApp Guard.app/Contents/MacOS/WhatsAppGuard"
if [[ ! -x "$app_binary" ]]; then
  print -u2 'Build the app first with ./scripts/build.sh.'
  exit 1
fi
"$app_binary" --self-test
zsh -n "$repo_dir/scripts/build.sh" "$repo_dir/scripts/install.sh" "$repo_dir/scripts/release.sh"
plutil -lint "$repo_dir/Info.plist"
