#!/bin/bash
set -e

# Cross-compile lxml for iOS arm64
# Links against system libxml2 + libxslt from iOS SDK

PEGASUS_ROOT="/Users/cruzflores/Desktop/pegasus"
PYTHON_FW="$PEGASUS_ROOT/Pegasus/Python.xcframework/ios-arm64"
PYTHON_INCLUDE="$PYTHON_FW/include/python3.13"
PYTHON_LIB="$PYTHON_FW/lib/libpython3.13.dylib"
DYNLOAD="$PYTHON_FW/lib-arm64/python3.13/lib-dynload"
SITE_PACKAGES="$PYTHON_FW/lib-arm64/python3.13/site-packages"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
AR=$(xcrun --sdk iphoneos -f ar)

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -I$PYTHON_INCLUDE -I$SDK/usr/include/libxml2 -fPIC"
LDFLAGS="-arch arm64 -isysroot $SDK -L$PYTHON_FW/lib -lpython3.13 -lxml2 -lxslt -lexslt -lz"

WORKDIR="$PEGASUS_ROOT/build_ios_deps/work"
mkdir -p "$WORKDIR" "$SITE_PACKAGES"

echo "=== Downloading lxml ==="
cd "$WORKDIR"
pip3 download --no-binary :all: --no-deps lxml -d . 2>/dev/null || python3 -m pip download --no-binary :all: --no-deps lxml -d .

LXML_TAR=$(ls lxml-*.tar.gz 2>/dev/null | head -1)
if [ -z "$LXML_TAR" ]; then
    echo "Failed to download lxml source"
    exit 1
fi

echo "=== Extracting $LXML_TAR ==="
tar xzf "$LXML_TAR"
LXML_DIR=$(ls -d lxml-*/ | head -1)
cd "$LXML_DIR"

echo "=== Building lxml C extensions ==="

# Build etree
echo "  Building lxml.etree..."
$CC $CFLAGS -c src/lxml/etree.c -o etree.o 2>&1 | tail -5 || true

# If the C source isn't pre-generated, we need Cython. Try the .pyx approach via setup.py
if [ ! -f src/lxml/etree.c ]; then
    echo "  C sources not found, trying setup.py cross-compile..."

    # Create a cross-compile setup.cfg
    cat > setup.cfg <<SETUPEOF
[build_ext]
include-dirs=$SDK/usr/include/libxml2:$PYTHON_INCLUDE
library-dirs=$SDK/usr/lib
SETUPEOF

    CC="$CC" \
    CFLAGS="$CFLAGS" \
    LDFLAGS="$LDFLAGS" \
    _PYTHON_HOST_PLATFORM="iphoneos-arm64" \
    ARCHFLAGS="-arch arm64" \
    python3 setup.py build_ext \
        --include-dirs="$SDK/usr/include/libxml2:$PYTHON_INCLUDE" \
        --library-dirs="$SDK/usr/lib" 2>&1 | tail -20

    # Find and copy the built .so files
    find build -name "*.so" -exec cp {} "$DYNLOAD/" \;
    echo "  Copied .so files to dynload"
else
    # C sources exist — compile directly
    for src in src/lxml/etree.c src/lxml/objectify.c; do
        if [ -f "$src" ]; then
            base=$(basename "$src" .c)
            echo "  Compiling $base..."
            $CC $CFLAGS -c "$src" -o "${base}.o"
            $CC -shared -arch arm64 -isysroot "$SDK" "${base}.o" $LDFLAGS -o "${base}.cpython-313-iphoneos.so"
            cp "${base}.cpython-313-iphoneos.so" "$DYNLOAD/"
        fi
    done
fi

# Copy pure Python parts of lxml
echo "=== Copying lxml Python files ==="
mkdir -p "$SITE_PACKAGES/lxml"
cp -r src/lxml/*.py "$SITE_PACKAGES/lxml/" 2>/dev/null || true
# Also copy any .pxi files needed
cp -r src/lxml/*.pxi "$SITE_PACKAGES/lxml/" 2>/dev/null || true
cp -r src/lxml/includes "$SITE_PACKAGES/lxml/" 2>/dev/null || true
cp -r src/lxml/isoschematron "$SITE_PACKAGES/lxml/isoschematron" 2>/dev/null || true

# Create __init__.py if missing
if [ ! -f "$SITE_PACKAGES/lxml/__init__.py" ]; then
    touch "$SITE_PACKAGES/lxml/__init__.py"
fi

echo "=== Done ==="
echo "Extensions in $DYNLOAD:"
ls -la "$DYNLOAD/"*lxml* "$DYNLOAD/"*etree* "$DYNLOAD/"*objectify* 2>/dev/null || echo "(checking site-packages)"
echo "Python files in $SITE_PACKAGES/lxml:"
ls "$SITE_PACKAGES/lxml/" 2>/dev/null

echo ""
echo "=== Build complete ==="
