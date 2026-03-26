#!/bin/bash
set -e

MODELS_DIR="$HOME/Documents/models"
mkdir -p "$MODELS_DIR"

MODEL_NAME="${1:-Qwen3-4B-Q4_K_M.gguf}"
MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/$MODEL_NAME"

echo "Downloading $MODEL_NAME to $MODELS_DIR..."
echo "URL: $MODEL_URL"
echo ""

if command -v huggingface-cli &>/dev/null; then
    echo "Using huggingface-cli..."
    huggingface-cli download unsloth/Qwen3-4B-GGUF "$MODEL_NAME" --local-dir "$MODELS_DIR"
else
    echo "Using curl..."
    curl -L --progress-bar -o "$MODELS_DIR/$MODEL_NAME" "$MODEL_URL"
fi

echo ""
echo "Done! Model saved to: $MODELS_DIR/$MODEL_NAME"
SIZE=$(du -h "$MODELS_DIR/$MODEL_NAME" | cut -f1)
echo "Size: $SIZE"
