#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/proofs/gate1_device_runner"
OUT="$ROOT/build/gate1-remediation-c"
PKGROOT="$OUT/root"
VERSION="0.2.1"
PACKAGE_FILE="com.vcampro.gate1proofrunner_${VERSION}_iphoneos-arm64.deb"
BUILD_SHA="${VCAM_GATE1_BUILD_SHA:-unknown}"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
rm -rf "$OUT"
mkdir -p "$OUT/bin" \
  "$PKGROOT/DEBIAN" \
  "$PKGROOT/var/jb/usr/lib/TweakInject" \
  "$PKGROOT/var/jb/usr/libexec" \
  "$PKGROOT/var/jb/Applications/VCAMProGate1.app" \
  "$PKGROOT/var/jb/Library/LaunchDaemons"

COMMON=(
  -std=c++17
  -arch arm64
  -isysroot "$SDKROOT"
  -miphoneos-version-min=15.0
  -Wall
  -Wextra
  -Werror
  -Werror=unguarded-availability-new
  -I"$SOURCE/core"
  -I"$SOURCE/remediation"
)

"$CXX" "${COMMON[@]}" -fobjc-arc -dynamiclib \
  -Wl,-install_name,/var/jb/usr/lib/TweakInject/VCAMProGate1Witness.dylib \
  "$SOURCE/witness/VCAMProGate1Witness.mm" \
  "$SOURCE/remediation/WitnessProtocol.cpp" \
  -framework Foundation -framework OSLog \
  -o "$OUT/bin/VCAMProGate1Witness.dylib"

"$CXX" "${COMMON[@]}" -fobjc-arc -I"$SOURCE/helper" \
  "-DVCAM_GATE1_BUILD_SHA=\"$BUILD_SHA\"" \
  "$SOURCE/core/Gate1ProofRunner.cpp" \
  "$SOURCE/remediation/WitnessProtocol.cpp" \
  "$SOURCE/helper/IOSGate1Platform.mm" \
  "$SOURCE/coordinator/main.mm" \
  -framework Foundation \
  -o "$OUT/bin/vcampro-gate1-coordinator"

"$CXX" "${COMMON[@]}" -fobjc-arc -I"$SOURCE/handoff" \
  "$SOURCE/handoff/VCAMProGate1Handoff.mm" \
  -framework Foundation \
  -o "$OUT/bin/vcampro-gate1-handoff"

"$CXX" "${COMMON[@]}" -fobjc-arc -I"$SOURCE/handoff" \
  "$SOURCE/viewer/main.mm" \
  -framework Foundation -framework UIKit \
  -o "$OUT/bin/VCAMProGate1"

ldid -S "$OUT/bin/VCAMProGate1Witness.dylib"
ldid -S "$OUT/bin/vcampro-gate1-coordinator"
ldid -S "$OUT/bin/vcampro-gate1-handoff"
ldid -S "$OUT/bin/VCAMProGate1"

cp "$OUT/bin/VCAMProGate1Witness.dylib" \
  "$PKGROOT/var/jb/usr/lib/TweakInject/VCAMProGate1Witness.dylib"
cp "$SOURCE/witness/VCAMProGate1Witness.plist" \
  "$PKGROOT/var/jb/usr/lib/TweakInject/VCAMProGate1Witness.plist"
cp "$OUT/bin/vcampro-gate1-coordinator" \
  "$PKGROOT/var/jb/usr/libexec/vcampro-gate1-coordinator"
cp "$OUT/bin/vcampro-gate1-handoff" \
  "$PKGROOT/var/jb/usr/libexec/vcampro-gate1-handoff"
cp "$SOURCE/handoff/com.vcampro.gate1.handoff.plist" \
  "$PKGROOT/var/jb/Library/LaunchDaemons/com.vcampro.gate1.handoff.plist"
cp "$OUT/bin/VCAMProGate1" \
  "$PKGROOT/var/jb/Applications/VCAMProGate1.app/VCAMProGate1"
cp "$SOURCE/viewer/Info.plist" \
  "$PKGROOT/var/jb/Applications/VCAMProGate1.app/Info.plist"

cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: com.vcampro.gate1proofrunner
Name: VCAM PRO Gate 1
Version: $VERSION
Architecture: iphoneos-arm64
Description: One-shot VCAM PRO Gate 1 device-proof tooling.
Maintainer: VCAM PRO
Author: VCAM PRO
Section: Development
Depends: firmware (>= 15.0), mobilesubstrate
EOF

cp "$SOURCE/package/postinst" "$PKGROOT/DEBIAN/postinst"
cp "$SOURCE/package/prerm" "$PKGROOT/DEBIAN/prerm"
cp "$SOURCE/package/postrm" "$PKGROOT/DEBIAN/postrm"

chmod 0755 \
  "$PKGROOT/DEBIAN/postinst" \
  "$PKGROOT/DEBIAN/prerm" \
  "$PKGROOT/DEBIAN/postrm" \
  "$PKGROOT/var/jb/usr/libexec/vcampro-gate1-coordinator" \
  "$PKGROOT/var/jb/usr/libexec/vcampro-gate1-handoff" \
  "$PKGROOT/var/jb/Applications/VCAMProGate1.app/VCAMProGate1"
chmod 0644 \
  "$PKGROOT/DEBIAN/control" \
  "$PKGROOT/var/jb/usr/lib/TweakInject/VCAMProGate1Witness.dylib" \
  "$PKGROOT/var/jb/usr/lib/TweakInject/VCAMProGate1Witness.plist" \
  "$PKGROOT/var/jb/Library/LaunchDaemons/com.vcampro.gate1.handoff.plist" \
  "$PKGROOT/var/jb/Applications/VCAMProGate1.app/Info.plist"

dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT/$PACKAGE_FILE"
echo "$OUT/$PACKAGE_FILE"
