#!/bin/bash
# Build FFmpeg as an xcframework, in either `static` or `dynamic` flavour.
#
#   ./Scripts/build_ffmpeg.sh static    → output/FFmpeg.xcframework with .a slices
#   ./Scripts/build_ffmpeg.sh dynamic   → output/FFmpeg.xcframework with .framework slices (dylibs)
#   ./Scripts/build_ffmpeg.sh           → defaults to dynamic
#
# The dynamic flavour is needed for SwiftUI Previews to JIT-resolve FFmpeg
# symbols across platforms — the static .a otherwise has to be force_loaded
# per slice, which can't be expressed cleanly in Package.swift since SPM's
# `.when(platforms:)` doesn't distinguish device from simulator.

set -e

MODE="${1:-dynamic}"
case "$MODE" in
    static|dynamic) ;;
    *) echo "Usage: $0 [static|dynamic]"; exit 1 ;;
esac

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
FFMPEG_SRC="$SCRIPTS_DIR/ffmpeg"
FFMPEG_REPO="https://git.ffmpeg.org/ffmpeg.git"
FFMPEG_TAG="n8.1.1"
PATCHES_DIR="$SCRIPTS_DIR/patches"
BUILD="$SCRIPTS_DIR/build"
OUTPUT="$ROOT/Frameworks"

MIN_IOS="18.0"
MIN_TVOS="18.0"
MIN_MACOS="15.0"
MIN_XROS="1.0"

COMMON_FLAGS="
--disable-everything
--enable-avformat
--enable-avcodec
--enable-avutil
--enable-network
--enable-videotoolbox
--enable-protocol=rtsp,tcp,udp
--enable-demuxer=rtsp
--enable-parser=h264,hevc
--enable-decoder=h264
--disable-programs
--disable-doc
--disable-debug
--disable-symver
--enable-pic
"

# Headers + modulemap for static-mode slices: flat Headers dir, modulemap
# inside it (matches the prior layout consumed by `-headers` in xcodebuild).
prepare_headers_static() {
    SDK=$1
    ARCH=$2

    SRC="$BUILD/$SDK-$ARCH/include"
    DST="$BUILD/$SDK-$ARCH/module"

    mkdir -p "$DST"
    cp -R "$SRC/"* "$DST/"

    cat > "$DST/ffmpeg.h" <<EOF
#ifndef FFMPEG_H
#define FFMPEG_H

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

#endif
EOF

    cat > "$DST/module.modulemap" <<EOF
module FFmpeg [system] {
    umbrella header "ffmpeg.h"

    export *
    module * { export * }
}
EOF
}

# Build a FFmpeg.framework bundle for one slice: dylib + Headers + Modules
# + Info.plist. The dylib is produced by relinking the combined static
# archive with `-force_load`, then baking `-lz/-liconv/-lbz2` and the AV*
# system frameworks as load commands so the consumer doesn't redeclare them.
prepare_framework_dynamic() {
    SDK=$1
    ARCH=$2
    TARGET=$3
    MIN=$4

    SRC="$BUILD/$SDK-$ARCH/include"
    STATIC_LIB="$BUILD/libs/libffmpeg-$SDK-$ARCH.a"
    FW="$BUILD/frameworks/$SDK-$ARCH/FFmpeg.framework"

    if [ ! -f "$STATIC_LIB" ]; then
        echo "  ! missing $STATIC_LIB — skipping framework"
        return
    fi

    rm -rf "$FW"
    mkdir -p "$FW/Headers" "$FW/Modules"

    cp -R "$SRC/"* "$FW/Headers/"
    rm -f "$FW/Headers/module.modulemap"

    # Rewrite cross-library FFmpeg includes to framework-style paths.
    # Inside a .framework, only `<FrameworkName/...>` resolves through
    # the framework search path; bare `<libavutil/...>` or quoted
    # `"libavutil/..."` would need the framework's Headers dir on the
    # consumer's `-I`, which Xcode doesn't add for binary framework
    # targets. FFmpeg headers internally use both forms — handle both.
    find "$FW/Headers" -name "*.h" -type f -exec sed -i '' -E \
        -e 's@#include[[:space:]]*"(libav[a-z]+|libsw[a-z]+|libpostproc)/([^"]+)"@#include <FFmpeg/\1/\2>@g' \
        -e 's@#include[[:space:]]*<(libav[a-z]+|libsw[a-z]+|libpostproc)/([^>]+)>@#include <FFmpeg/\1/\2>@g' \
        {} +

    cat > "$FW/Headers/ffmpeg.h" <<EOF
#ifndef FFMPEG_H
#define FFMPEG_H

#include <FFmpeg/libavcodec/avcodec.h>
#include <FFmpeg/libavformat/avformat.h>
#include <FFmpeg/libavutil/avutil.h>

#endif
EOF

    cat > "$FW/Modules/module.modulemap" <<EOF
framework module FFmpeg [system] {
    umbrella header "ffmpeg.h"

    export *
    module * { export * }
}
EOF

    SDK_PATH=$(xcrun --sdk $SDK --show-sdk-path)
    CC=$(xcrun --sdk $SDK --find clang)

    # macOS uses the deep (versioned) bundle layout; everything else is flat.
    if [ "$SDK" = "macosx" ]; then
        INSTALL_NAME="@rpath/FFmpeg.framework/Versions/A/FFmpeg"
    else
        INSTALL_NAME="@rpath/FFmpeg.framework/FFmpeg"
    fi

    "$CC" -dynamiclib \
        -arch "$ARCH" \
        -mtargetos="$TARGET" \
        -isysroot "$SDK_PATH" \
        -fvisibility=default \
        -Wl,-force_load,"$STATIC_LIB" \
        -lz -liconv -lbz2 \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework VideoToolbox \
        -framework AudioToolbox \
        -framework CoreFoundation \
        -framework Security \
        -Wl,-install_name,"$INSTALL_NAME" \
        -o "$FW/FFmpeg"

    xcrun --sdk "$SDK" strip -x "$FW/FFmpeg"

    cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FFmpeg</string>
    <key>CFBundleIdentifier</key>
    <string>org.ffmpeg.FFmpeg</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FFmpeg</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>$MIN</string>
</dict>
</plist>
EOF

    # Convert flat layout to macOS versioned bundle. Code-signing on
    # macOS rejects shallow frameworks (Info.plist must live in
    # Versions/Current/Resources/, with symlinks at the bundle root).
    if [ "$SDK" = "macosx" ]; then
        VA="$FW/Versions/A"
        mkdir -p "$VA/Resources"
        mv "$FW/FFmpeg" "$VA/FFmpeg"
        mv "$FW/Headers" "$VA/Headers"
        mv "$FW/Modules" "$VA/Modules"
        mv "$FW/Info.plist" "$VA/Resources/Info.plist"
        (cd "$FW/Versions" && ln -s A Current)
        (cd "$FW" && ln -s Versions/Current/FFmpeg FFmpeg)
        (cd "$FW" && ln -s Versions/Current/Headers Headers)
        (cd "$FW" && ln -s Versions/Current/Modules Modules)
        (cd "$FW" && ln -s Versions/Current/Resources Resources)
    fi
}

build_ffmpeg() {
    SDK=$1
    TARGET=$2
    ARCH=$3
    PLATFORM=$SDK

    PREFIX="$BUILD/$PLATFORM-$ARCH"
    SDK_PATH=$(xcrun --sdk $SDK --show-sdk-path)
    CC="$(xcrun --sdk $SDK --find clang)"

    echo "-> Build $PLATFORM $ARCH"

    cd "$FFMPEG_SRC"
    make clean || true

    ./configure \
        --prefix="$PREFIX" \
        --arch="$ARCH" \
        --target-os=darwin \
        --cc="$CC" \
        --sysroot="$SDK_PATH" \
        --enable-cross-compile \
        --extra-cflags="-arch $ARCH -mtargetos=${TARGET} -isysroot $SDK_PATH -ffile-prefix-map=$FFMPEG_SRC=ffmpeg -ffile-prefix-map=$PREFIX=/ffmpeg-build -ffile-prefix-map=$SDK_PATH=/sdk" \
        --extra-ldflags="-arch $ARCH -mtargetos=${TARGET} -isysroot $SDK_PATH" \
        $COMMON_FLAGS

    # Strip user-specific absolute paths from FFMPEG_CONFIGURATION, which is
    # otherwise baked into the binary (exposed via avutil_configuration()).
    sed -i '' \
        -e "s|$PREFIX|/ffmpeg-build|g" \
        -e "s|$SDK_PATH|/sdk|g" \
        -e "s|$FFMPEG_SRC|ffmpeg|g" \
        config.h

    make -j$(sysctl -n hw.ncpu)
    make install
}

fetch_ffmpeg_source() {
    if [ ! -d "$FFMPEG_SRC/.git" ]; then
        echo "-> Clone $FFMPEG_REPO @ $FFMPEG_TAG"
        rm -rf "$FFMPEG_SRC"
        git clone --depth 1 --branch "$FFMPEG_TAG" "$FFMPEG_REPO" "$FFMPEG_SRC"
    else
        echo "-> Checkout $FFMPEG_TAG in $FFMPEG_SRC"
        cd "$FFMPEG_SRC"
        git fetch --depth 1 origin tag "$FFMPEG_TAG" || git fetch origin tag "$FFMPEG_TAG"
        git checkout -f "$FFMPEG_TAG"
        cd "$ROOT"
    fi
}

# Apply local patches on top of the checked-out tag. `git checkout -f` above
# resets the worktree to the tag's clean state, so each run reapplies them.
apply_patches() {
    [ -d "$PATCHES_DIR" ] || return 0
    shopt -s nullglob
    local patches=("$PATCHES_DIR"/*.patch)
    shopt -u nullglob
    [ ${#patches[@]} -gt 0 ] || return 0

    cd "$FFMPEG_SRC"
    for patch in "${patches[@]}"; do
        echo "-> Apply $(basename "$patch")"
        git apply --whitespace=nowarn "$patch"
    done
    cd "$ROOT"
}

fetch_ffmpeg_source
apply_patches

# SDK | mtargetos value | ARCH | min OS version
PLATEFORMES=(
  "xros|xros${MIN_XROS}|arm64|${MIN_XROS}"
  "xrsimulator|xros${MIN_XROS}-simulator|arm64|${MIN_XROS}"
  "iphoneos|ios${MIN_IOS}|arm64|${MIN_IOS}"
  "iphonesimulator|ios${MIN_IOS}-simulator|arm64|${MIN_IOS}"
  "macosx|macosx${MIN_MACOS}|arm64|${MIN_MACOS}"
  "appletvos|tvos${MIN_TVOS}|arm64|${MIN_TVOS}"
  "appletvsimulator|tvos${MIN_TVOS}-simulator|arm64|${MIN_TVOS}"
)

for PLATFORME in "${PLATEFORMES[@]}"; do
    IFS="|" read -r SDK TARGET ARCH MIN <<< "$PLATFORME"
    build_ffmpeg "$SDK" "$TARGET" "$ARCH"
done

echo "√ FFmpeg compilé pour toutes les plateformes"

mkdir -p "$BUILD/libs"

for PLATFORME in "${PLATEFORMES[@]}"; do
    IFS="|" read -r SDK TARGET ARCH MIN <<< "$PLATFORME"
    PREFIX="$BUILD/$SDK-$ARCH"
    if [ -d "$PREFIX/lib" ]; then
        libtool -static $(find "$PREFIX/lib" -name "*.a") -o "$BUILD/libs/libffmpeg-$SDK-$ARCH.a"
    fi
done

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/FFmpeg.xcframework"

ARGS=()
for PLATFORME in "${PLATEFORMES[@]}"; do
    IFS="|" read -r SDK TARGET ARCH MIN <<< "$PLATFORME"
    if [ "$MODE" = "static" ]; then
        prepare_headers_static "$SDK" "$ARCH"
        ARGS+=("-library" "$BUILD/libs/libffmpeg-$SDK-$ARCH.a" "-headers" "$BUILD/$SDK-$ARCH/module")
    else
        prepare_framework_dynamic "$SDK" "$ARCH" "$TARGET" "$MIN"
        ARGS+=("-framework" "$BUILD/frameworks/$SDK-$ARCH/FFmpeg.framework")
    fi
done

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUTPUT/FFmpeg.xcframework"

echo "√ $MODE FFmpeg.xcframework → $OUTPUT/FFmpeg.xcframework"
