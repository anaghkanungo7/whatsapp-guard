#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
build_dir="$repo_dir/build"
app_dir="$build_dir/WhatsApp Guard.app"
architectures=(${=GUARD_ARCHS:-arm64 x86_64})
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$build_dir/objects"
cp "$repo_dir/Info.plist" "$app_dir/Contents/Info.plist"
for guard_arch in "${architectures[@]}"; do
  if [[ "$guard_arch" != arm64 && "$guard_arch" != x86_64 ]]; then
    print -u2 "Unsupported architecture: $guard_arch"
    exit 1
  fi
  (cd "$repo_dir"; xcrun swiftc -swift-version 5 -O -module-cache-path "$build_dir/module-cache" \
    -target "$guard_arch-apple-macosx13.0" Sources/Guard.swift \
    -o "$build_dir/objects/WhatsAppGuard-$guard_arch")
done
executables=()
for guard_arch in "${architectures[@]}"; do executables+=("$build_dir/objects/WhatsAppGuard-$guard_arch"); done
if (( ${#executables[@]} > 1 )); then
  xcrun lipo -create "${executables[@]}" -output "$app_dir/Contents/MacOS/WhatsAppGuard"
else
  cp "${executables[1]}" "$app_dir/Contents/MacOS/WhatsAppGuard"
fi
(cd "$repo_dir"; CLANG_MODULE_CACHE_PATH="$build_dir/module-cache" \
  xcrun swift -module-cache-path "$build_dir/module-cache" scripts/MakeIcon.swift "$app_dir/Contents/Resources/AppIcon.icns")
codesign --force --sign - --identifier local.codex.whatsapp-guard "$app_dir"
codesign --verify --strict "$app_dir"
"$repo_dir/scripts/test.sh"
print "Built $app_dir"
