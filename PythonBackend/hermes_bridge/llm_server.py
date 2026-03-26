"""
Local LLM server using llama-cpp-python with Metal acceleration.
Exposes an OpenAI-compatible API on localhost:8080 that Hermes Agent
connects to as a "custom endpoint".
"""

import os
import sys
import json
import threading
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

# Default model search paths (iOS app sandbox)
MODEL_SEARCH_PATHS = [
    os.path.expanduser("~/Documents/models"),
    os.path.join(os.path.dirname(__file__), "..", "models"),
]

_server_thread = None
_uvicorn_server = None
_load_status = "not_loaded"  # "not_loaded" | "loading" | "loaded" | "error"
_load_error = None
_status_lock = threading.Lock()


def find_model(model_name=None):
    """Find a GGUF model file in known locations."""
    for search_path in MODEL_SEARCH_PATHS:
        if not os.path.isdir(search_path):
            continue
        for f in os.listdir(search_path):
            if not f.endswith(".gguf"):
                continue
            if model_name is None or model_name in f:
                return os.path.join(search_path, f)
    return None


def start_server(
    model_path=None,
    host="127.0.0.1",
    port=8080,
    n_ctx=4096,
    n_gpu_layers=-1,
    chat_format="chatml",
):
    """
    Start loading the model and LLM server in the background.
    Returns immediately with the URL. Poll get_model_info() for status.
    """
    global _server_thread, _uvicorn_server, _load_status, _load_error

    # Stop any existing server first
    stop_server()

    if model_path is None:
        model_path = find_model()
    if model_path is None:
        raise FileNotFoundError(
            f"No .gguf model found. Place a model in one of: {MODEL_SEARCH_PATHS}"
        )

    if not os.path.isfile(model_path):
        raise FileNotFoundError(f"Model file not found: {model_path}")

    try:
        from llama_cpp.server.app import create_app
        from llama_cpp.server.settings import ModelSettings, ServerSettings
        import uvicorn
    except ImportError:
        logger.error(
            "llama-cpp-python not installed. "
            "Install with: pip install 'llama-cpp-python[server]' --prefer-binary"
        )
        raise

    with _status_lock:
        _load_status = "loading"
        _load_error = None

    url = f"http://{host}:{port}"

    def _load_and_serve():
        global _server_thread, _uvicorn_server, _load_status, _load_error
        try:
            logger.info(f"Loading model: {model_path}")
            model_settings = ModelSettings(
                model=model_path,
                n_ctx=n_ctx,
                n_gpu_layers=n_gpu_layers,
                chat_format=chat_format,
            )
            server_settings = ServerSettings(host=host, port=port)
            app = create_app(
                server_settings=server_settings,
                model_settings=[model_settings],
            )

            with _status_lock:
                _load_status = "loaded"
            logger.info(f"Model loaded, starting server at {url}")

            config = uvicorn.Config(app, host=host, port=port, log_level="warning")
            _uvicorn_server = uvicorn.Server(config)
            _uvicorn_server.run()
        except Exception as e:
            logger.exception("Failed to load model or start server")
            with _status_lock:
                _load_status = "error"
                _load_error = str(e)

    _server_thread = threading.Thread(target=_load_and_serve, daemon=True)
    _server_thread.start()
    logger.info(f"Model loading started in background")
    return url


def stop_server():
    """Stop the local LLM server."""
    global _server_thread, _uvicorn_server, _load_status, _load_error
    if _uvicorn_server is not None:
        _uvicorn_server.should_exit = True
        if _server_thread is not None:
            _server_thread.join(timeout=5)
    _uvicorn_server = None
    _server_thread = None
    with _status_lock:
        _load_status = "not_loaded"
        _load_error = None


def get_model_info():
    """Return info about the currently loaded model."""
    with _status_lock:
        info = {"status": _load_status}
        if _load_error:
            info["error"] = _load_error
        return info
