#!/bin/bash
set -e

# Pegasus — Python embedding setup script
# Downloads Python.xcframework and installs pure-Python dependencies

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_VERSION="3.13"
SUPPORT_VERSION="3.13-b6"  # Check https://github.com/beeware/Python-Apple-support/releases for latest

echo "=== Pegasus Python Embedding Setup ==="

# 1. Download Python.xcframework if not present
if [ ! -d "$SCRIPT_DIR/Pegasus/Python.xcframework" ]; then
    echo ""
    echo ">>> Downloading Python.xcframework (Python $PYTHON_VERSION)..."
    DOWNLOAD_URL="https://github.com/beeware/Python-Apple-support/releases/download/$SUPPORT_VERSION/Python-$SUPPORT_VERSION-iOS.tar.gz"

    TMPDIR=$(mktemp -d)
    curl -L "$DOWNLOAD_URL" -o "$TMPDIR/python-ios.tar.gz"

    echo ">>> Extracting..."
    tar xzf "$TMPDIR/python-ios.tar.gz" -C "$TMPDIR"

    # Copy the xcframework
    cp -R "$TMPDIR/Python.xcframework" "$SCRIPT_DIR/Pegasus/Python.xcframework"

    # Copy the standard library
    if [ -d "$TMPDIR/python-stdlib" ]; then
        cp -R "$TMPDIR/python-stdlib" "$SCRIPT_DIR/Pegasus/python-stdlib"
    fi

    rm -rf "$TMPDIR"
    echo ">>> Python.xcframework installed"
else
    echo ">>> Python.xcframework already present, skipping download"
fi

# 2. Install pure-Python dependencies
echo ""
echo ">>> Installing Python packages (openai, pyyaml)..."
mkdir -p "$SCRIPT_DIR/app_packages"

pip3 install --target "$SCRIPT_DIR/app_packages" \
    openai \
    pyyaml \
    --quiet --upgrade

# Remove unnecessary files to save space
find "$SCRIPT_DIR/app_packages" -name "*.pyc" -delete
find "$SCRIPT_DIR/app_packages" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR/app_packages" -name "*.dist-info" -type d -exec rm -rf {} + 2>/dev/null || true

echo ">>> Packages installed to app_packages/"

# 3. Summary
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Files added:"
[ -d "$SCRIPT_DIR/Pegasus/Python.xcframework" ] && echo "  ✓ Pegasus/Python.xcframework"
[ -d "$SCRIPT_DIR/Pegasus/python-stdlib" ] && echo "  ✓ Pegasus/python-stdlib"
[ -d "$SCRIPT_DIR/app_packages" ] && echo "  ✓ app_packages/ (openai, pyyaml, dependencies)"
echo ""
echo "Next steps:"
echo "  1. Run 'xcodegen generate' to regenerate the Xcode project"
echo "  2. Open Pegasus.xcodeproj in Xcode"
echo "  3. Build and run on your iPhone"
echo ""
echo "The app will now run the full Hermes agent on-device with tools:"
echo "  • web_fetch — fetch URLs"
echo "  • file_read/write/list — filesystem operations"
echo "  • memory_read/write — persistent memory"
echo "  • skills — reusable workflows"
echo "  • python_exec — Python code execution"
echo "  (shell_exec is disabled on iOS)"
