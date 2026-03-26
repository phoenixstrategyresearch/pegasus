#!/bin/bash
set -e

echo "=== Pegasus Setup ==="
echo ""

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$HOME/Documents/models"
DATA_DIR="$HOME/Documents/pegasus_data"
WORKSPACE_DIR="$HOME/Documents/pegasus_workspace"

# Create directories
echo "[1/4] Creating directories..."
mkdir -p "$MODELS_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$WORKSPACE_DIR"
echo "  Models:    $MODELS_DIR"
echo "  Data:      $DATA_DIR"
echo "  Workspace: $WORKSPACE_DIR"

# Install Python dependencies
echo ""
echo "[2/4] Installing Python dependencies..."
cd "$PROJ_ROOT/PythonBackend"
pip3 install -r requirements.txt 2>&1 | tail -5

# Check for llama-cpp-python with Metal
echo ""
echo "[3/4] Checking llama-cpp-python Metal support..."
python3 -c "
from llama_cpp import Llama
print('  llama-cpp-python installed OK')
" 2>/dev/null || {
    echo "  Installing llama-cpp-python with Metal support..."
    CMAKE_ARGS="-DGGML_METAL=on" pip3 install llama-cpp-python[server] --force-reinstall --no-cache-dir 2>&1 | tail -3
}

# Check for models
echo ""
echo "[4/4] Checking for GGUF models..."
FOUND_MODELS=$(find "$MODELS_DIR" -name "*.gguf" 2>/dev/null | head -5)
if [ -z "$FOUND_MODELS" ]; then
    echo "  No .gguf models found in $MODELS_DIR"
    echo ""
    echo "  Download a model, e.g.:"
    echo "    huggingface-cli download unsloth/Qwen3-4B-GGUF Qwen3-4B-Q4_K_M.gguf --local-dir $MODELS_DIR"
    echo ""
    echo "  Or with curl:"
    echo "    curl -L -o $MODELS_DIR/Qwen3-4B-Q4_K_M.gguf \\"
    echo "      'https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf'"
else
    echo "  Found models:"
    echo "$FOUND_MODELS" | while read f; do
        SIZE=$(du -h "$f" | cut -f1)
        echo "    $SIZE  $(basename "$f")"
    done
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To start the backend:"
echo "  cd $PROJ_ROOT/PythonBackend && python3 main.py"
echo ""
echo "Then open Pegasus.xcodeproj in Xcode and run on your device."
