#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
APP="${COURSEWATCH_OUTPUT_DIR:-$ROOT/../dist}/课讯.app"
TOOLCHAIN="$ROOT/.toolchain/usr"
if [[ ! -e "$TOOLCHAIN/lib/swift/macosx" ]]; then
  mkdir -p "$TOOLCHAIN/lib/swift" "$TOOLCHAIN/include/swift"
  for file in /Library/Developer/CommandLineTools/usr/lib/swift/*; do
    ln -s "$file" "$TOOLCHAIN/lib/swift/${file:t}" 2>/dev/null || true
  done
  cp /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap "$TOOLCHAIN/include/swift/module.modulemap"
  ln -s /Library/Developer/CommandLineTools/usr/include/swift/bridging "$TOOLCHAIN/include/swift/bridging" 2>/dev/null || true
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/swiftc -resource-dir "$TOOLCHAIN/lib/swift" -framework SwiftUI -framework AppKit \
  "$ROOT/make_icon.swift" -o "$ROOT/.toolchain/make-icon"
"$ROOT/.toolchain/make-icon" "$ROOT"
/usr/bin/iconutil -c icns "$ROOT/AppIcon.iconset" -o "$ROOT/AppIcon.icns"
ARCHS="${COURSEWATCH_ARCHS:-$(uname -m)}"
if [[ "$ARCHS" == "universal" ]]; then ARCHS="arm64 x86_64"; fi
mkdir -p "$ROOT/.toolchain/bin"
typeset -a BUILT
for arch in ${(z)ARCHS}; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
  binary="$ROOT/.toolchain/bin/CourseWatch-$arch"
  /usr/bin/swiftc -swift-version 5 -Onone -target "$arch-apple-macosx13.0" \
    -resource-dir "$TOOLCHAIN/lib/swift" \
    -framework SwiftUI -framework WebKit -framework EventKit -framework UserNotifications \
    "$ROOT/Models.swift" "$ROOT/Store.swift" "$ROOT/PortalEngine.swift" "$ROOT/ExternalEngine.swift" \
    "$ROOT/CalendarService.swift" "$ROOT/Scheduler.swift" \
    "$ROOT/CredentialsVault.swift" "$ROOT/App.swift" \
    -o "$binary"
  BUILT+=("$binary")
done
if (( ${#BUILT} == 1 )); then
  cp "$BUILT[1]" "$APP/Contents/MacOS/CourseWatch"
else
  /usr/bin/lipo -create "${BUILT[@]}" -output "$APP/Contents/MacOS/CourseWatch"
fi
chmod 755 "$APP/Contents/MacOS/CourseWatch"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Crawler.js" "$APP/Contents/Resources/Crawler.js"
cp "$ROOT/ClassCrawler.js" "$APP/Contents/Resources/ClassCrawler.js"
cp "$ROOT/GradescopeCrawler.js" "$APP/Contents/Resources/GradescopeCrawler.js"
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --deep --sign - "$APP"
echo "$APP"
