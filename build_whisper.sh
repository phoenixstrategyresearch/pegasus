#!/bin/bash
# Build whisper.cpp as an xcframework for iOS arm64.
# Similar process to how llama.xcframework was built.
#
# Prerequisites:
#   - Xcode with iOS SDK
#   - git
#
# Usage:
#   chmod +x build_whisper.sh
#   ./build_whisper.sh
#
# Output: whisper.xcframework ready to drop into Pegasus/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/build_ios_deps/work"
WHISPER_DIR="$WORK_DIR/whisper.cpp"
BUILD_DIR="$WORK_DIR/whisper-build-ios"
OUTPUT_DIR="$SCRIPT_DIR/Pegasus"

echo "=== Building whisper.cpp for iOS arm64 ==="

# Clone or update whisper.cpp
if [ -d "$WHISPER_DIR" ]; then
    echo "Updating whisper.cpp..."
    cd "$WHISPER_DIR" && git pull
else
    echo "Cloning whisper.cpp..."
    mkdir -p "$WORK_DIR"
    git clone https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
fi

cd "$WHISPER_DIR"

# Build for iOS arm64
echo "Building for iOS arm64..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
ARCH="arm64"
MIN_IOS="17.0"

cmake -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
    -DCMAKE_OSX_SYSROOT=$SDK \
    -DCMAKE_BUILD_TYPE=Release \
    -DWHISPER_METAL=ON \
    -DWHISPER_COREML=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON \
    .

cmake --build "$BUILD_DIR" --config Release -j$(sysctl -n hw.logicalcpu)

echo "Build complete!"

# Create xcframework
echo "Creating xcframework..."

# Find built libraries
WHISPER_LIB="$BUILD_DIR/src/libwhisper.a"
GGML_LIB="$BUILD_DIR/ggml/src/libggml.a"
GGML_BASE="$BUILD_DIR/ggml/src/libggml-base.a"
GGML_METAL="$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a"

# Combine into a single fat static library
COMBINED_DIR="$BUILD_DIR/combined"
mkdir -p "$COMBINED_DIR"

# Extract and recombine all .a files
cd "$COMBINED_DIR"
for lib in "$WHISPER_LIB" "$GGML_LIB" "$GGML_BASE" "$GGML_METAL"; do
    if [ -f "$lib" ]; then
        echo "  Adding: $(basename $lib)"
        ar x "$lib"
    fi
done
ar rcs libwhisper_combined.a *.o
rm -f *.o
cd "$WHISPER_DIR"

# Create the framework structure
FW_DIR="$BUILD_DIR/whisper.framework"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR/Headers"

cp "$COMBINED_DIR/libwhisper_combined.a" "$FW_DIR/whisper"
cp "$WHISPER_DIR/include/whisper.h" "$FW_DIR/Headers/"

# Copy ggml headers if present
for h in ggml.h ggml-alloc.h ggml-backend.h; do
    if [ -f "$WHISPER_DIR/ggml/include/$h" ]; then
        cp "$WHISPER_DIR/ggml/include/$h" "$FW_DIR/Headers/"
    fi
done

# Create module map
cat > "$FW_DIR/Headers/module.modulemap" <<'MODULEMAP'
framework module whisper {
    header "whisper.h"
    export *
}
MODULEMAP

cat > "$FW_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
</dict>
</plist>
PLIST

# Create xcframework
XCF_OUTPUT="$OUTPUT_DIR/whisper.xcframework"
rm -rf "$XCF_OUTPUT"
xcodebuild -create-xcframework \
    -framework "$FW_DIR" \
    -output "$XCF_OUTPUT"

echo ""
echo "=== Done! ==="
echo "Output: $XCF_OUTPUT"
echo ""
echo "Next steps:"
echo "1. Download a whisper model (e.g. ggml-small.bin) from:"
echo "   https://huggingface.co/ggerganov/whisper.cpp/tree/main"
echo "2. Place it in Documents/models/ on the device"
echo "3. Rebuild the Xcode project with xcodegen"
