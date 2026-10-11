#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
built_app="$repo_dir/build/WhatsApp Guard.app"
installed_app="/Applications/WhatsApp Guard.app"
if [[ ! -d "$built_app" ]]; then "$repo_dir/scripts/build.sh"; fi
if pgrep -x WhatsAppGuard >/dev/null; then
  print -u2 'Quit the existing WhatsApp Guard through its shield menu, then run this installer again.'
  exit 1
fi
if [[ ! -w /Applications ]]; then
  print -u2 'Move build/WhatsApp Guard.app into /Applications using Finder, then open it.'
  exit 1
fi
ditto "$built_app" "$installed_app"
codesign --verify --strict "$installed_app"
open "$installed_app"
print 'Installed. Choose a passcode on first launch, then enable Launch at login from the shield menu.'
