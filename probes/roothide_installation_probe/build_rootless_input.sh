#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PROBE_DIR="$ROOT_DIR/probes/roothide_installation_probe"
OUT_DIR="${1:-$ROOT_DIR/build/roothide-installation-probe}"
IOS_DIR="$OUT_DIR/ios"
PKG_ROOT="$OUT_DIR/rootless-input"
FINAL_DIR="$OUT_DIR/input"

rm -rf "$OUT_DIR"
mkdir -p "$IOS_DIR" "$PKG_ROOT/DEBIAN" "$FINAL_DIR"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"

"$CXX" \
    -std=c++17 \
    -fobjc-arc \
    -dynamiclib \
    -arch arm64 \
    -isysroot "$SDKROOT" \
    -miphoneos-version-min=15.0 \
    -Wall \
    -Wextra \
    -Werror \
    -Werror=unguarded-availability-new \
    -pedantic \
    "$PROBE_DIR/VCAMRootHideProbe.mm" \
    -framework Foundation \
    -framework UIKit \
    -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks \
    -Wl,-rpath,@loader_path/.jbroot/usr/lib \
    -Wl,-install_name,@loader_path/VCAMRootHideProbe.dylib \
    -o "$IOS_DIR/VCAMRootHideProbe.dylib"

TWEAK_DIR="$PKG_ROOT/var/jb/usr/lib/TweakInject"
mkdir -p "$TWEAK_DIR"

cp "$IOS_DIR/VCAMRootHideProbe.dylib" "$TWEAK_DIR/VCAMRootHideProbe.dylib"
cp "$PROBE_DIR/VCAMRootHideProbe.plist" "$TWEAK_DIR/VCAMRootHideProbe.plist"
cp "$PROBE_DIR/control" "$PKG_ROOT/DEBIAN/control"
cp "$PROBE_DIR/postinst" "$PKG_ROOT/DEBIAN/postinst"

chmod 0755 "$PKG_ROOT/DEBIAN/postinst"
chmod 0755 "$TWEAK_DIR/VCAMRootHideProbe.dylib"
chmod 0644 "$TWEAK_DIR/VCAMRootHideProbe.plist"
chmod 0644 "$PKG_ROOT/DEBIAN/control"

INPUT_DEB="$FINAL_DIR/com.vcampro.roothide-install-probe_0.1.0~probe2_iphoneos-arm64.deb"
dpkg-deb -Zzstd --build --root-owner-group "$PKG_ROOT" "$INPUT_DEB"

printf '%s\n' "$INPUT_DEB"
