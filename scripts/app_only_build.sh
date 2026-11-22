#!/bin/bash
# Rebuild ONLY the Husk app, reusing every prebuilt binary from an existing
# Husk.ipa (or a Husk.app pulled off a device). The expensive part of ci_build.sh
# -- QEMU, ANGLE, MoltenVK, the Rust pairing lib -- is already inside that IPA,
# so this is xcodebuild only: minutes instead of hours.
#
# Usage:
#   ./scripts/app_only_build.sh <Husk.ipa | Husk.app> [output.ipa]
#
# To get the bundle from a jailbroken device:
#   scp -r mobile@IP:/var/containers/Bundle/Application/<UUID>/Husk.app ./Husk.app
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
OUT="${2:-$HUSK_ROOT/build/Husk.ipa}"
[ -n "$SRC" ] || { echo "usage: $0 <Husk.ipa|Husk.app> [output.ipa]" >&2; exit 1; }
[ -e "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

WORK="$HUSK_ROOT/build/app-only-input"
rm -rf "$WORK"
mkdir -p "$WORK"

if [[ "$SRC" == *.ipa ]]; then
    echo "==> unpacking $SRC"
    unzip -q "$SRC" -d "$WORK/unpacked"
    APP="$WORK/unpacked/Payload/Husk.app"
else
    APP="$WORK/Husk.app"
    cp -R "$SRC" "$APP"
fi
[ -d "$APP" ] || { echo "no Husk.app in $SRC" >&2; exit 1; }

LIB="$HUSK_ROOT/build/ios-arm64/lib"
SYSROOT_LIB="$HUSK_ROOT/build/ios-arm64/sysroot/lib"
GUEST="$HUSK_ROOT/guests/phase0"
BIOS="$HUSK_ROOT/third_party/build/qemu-10.0.12-utm/pc-bios"
mkdir -p "$LIB" "$SYSROOT_LIB" "$GUEST" "$BIOS"

echo "==> staging prebuilt dependencies from $APP"

stage() { # <from> <to>
    [ -f "$1" ] || { echo "missing in source IPA: $1" >&2; exit 1; }
    cp "$1" "$2"
}

stage "$APP/Frameworks/libqemu-aarch64-softmmu.dylib" "$LIB/"
stage "$APP/Frameworks/libANGLE-shared.dylib"        "$SYSROOT_LIB/"
stage "$APP/Frameworks/libhuskps4.dylib"             "$LIB/"

# Rebuild the .xcframework if the IPA only carries the embedded .framework.
if [ -d "$APP/Frameworks/MoltenVK.xcframework" ]; then
    rm -rf "$LIB/MoltenVK.xcframework"
    cp -R "$APP/Frameworks/MoltenVK.xcframework" "$LIB/"
elif [ -d "$APP/Frameworks/MoltenVK.framework" ]; then
    XFW="$LIB/MoltenVK.xcframework"
    rm -rf "$XFW"
    mkdir -p "$XFW/ios-arm64"
    cp -R "$APP/Frameworks/MoltenVK.framework" "$XFW/ios-arm64/"
    cat > "$XFW/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
  <key>AvailableLibraries</key><array><dict>
    <key>LibraryIdentifier</key><string>ios-arm64</string>
    <key>LibraryPath</key><string>MoltenVK.framework</string>
    <key>SupportedPlatform</key><string>ios</string>
    <key>SupportedArchitectures</key><array><string>arm64</string></array>
  </dict></array>
</dict></plist>
PLIST
else
    echo "no MoltenVK in the source IPA (Unreal games will not work)" >&2
fi

stage "$APP/vmlinuz-virt"   "$GUEST/"
stage "$APP/initramfs-virt" "$GUEST/"

# project.yml's preBuild phase expects pc-bios ROMs and the firmware as .bz2.
cp "$APP"/pc-bios/* "$BIOS/" 2>/dev/null || true
if [ -f "$APP/edk2-aarch64-code.fd" ] && [ ! -f "$BIOS/edk2-aarch64-code.fd.bz2" ]; then
    bzip2 -c "$APP/edk2-aarch64-code.fd" > "$BIOS/edk2-aarch64-code.fd.bz2"
fi

# Keep the Java/Android system payloads the release shipped.
if [ -d "$APP/java-runtime" ]; then
    mkdir -p "$HUSK_ROOT/build/java-runtime"
    rsync -a "$APP/java-runtime/" "$HUSK_ROOT/build/java-runtime/"
fi
if [ -d "$APP/android-system" ]; then
    mkdir -p "$HUSK_ROOT/build/android-system"
    rsync -a "$APP/android-system/" "$HUSK_ROOT/build/android-system/"
fi

# StikJIT's .swiftinterface was emitted by Swift 6.4 using module-qualified
# names (`Swift::String`, `StikJIT::DDIPaths`). CI only has Swift 6.2/6.3,
# which cannot parse that: "expected '{' in struct" and "DDIPaths is not a
# member type of enum StikJIT.StikJIT". Downgrade it to the classic spelling:
# drop module qualifiers and lower the declared compiler version.
MODULES="$HUSK_ROOT/src/app/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework/Modules/StikJIT.swiftmodule"
for f in "$MODULES"/*.swiftinterface; do
    [ -f "$f" ] || continue
    sed -i '' -E \
      -e 's#^// swift-compiler-version:.*#// swift-compiler-version: Apple Swift version 6.2.4 effective-5.10 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)#' \
      -e 's/-interface-compiler-version 6\.4/-interface-compiler-version 6.2/' \
      -e 's/[A-Za-z_][A-Za-z0-9_]*::/ /g' \
      "$f"
done

echo "==> building app + IPA"
mkdir -p "$(dirname "$OUT")"
"$HUSK_ROOT/scripts/package_ipa.sh" "$OUT"
"$HUSK_ROOT/scripts/package_ipa.sh" --trollstore "${OUT%.ipa}.tipa"
echo "==> $OUT"
