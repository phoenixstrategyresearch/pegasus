#!/usr/bin/env python3
"""
Pegasus — main entry point.
Starts the LLM server and the agent API server.

Usage:
  python main.py                        # auto-detect model, start everything
  python main.py --model path/to.gguf   # use specific model
  python main.py --api-only             # skip LLM server (use external endpoint)
  python main.py --llm-url http://...   # point agent at existing LLM server
"""

import argparse
import logging
import time
import sys
import os

# Add parent to path so hermes_bridge is importable
sys.path.insert(0, os.path.dirname(__file__))

from hermes_bridge.llm_server import start_server, find_model
from hermes_bridge.api_server import run_api_server, agent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("pegasus")


def main():
    parser = argparse.ArgumentParser(description="Pegasus Agent")
    parser.add_argument("--model", type=str, help="Path to GGUF model file")
    parser.add_argument("--api-only", action="store_true", help="Skip LLM server")
    parser.add_argument("--llm-url", type=str, help="External LLM server URL")
    parser.add_argument("--llm-port", type=int, default=8080, help="LLM server port")
    parser.add_argument("--api-port", type=int, default=5005, help="Agent API port")
    parser.add_argument("--n-ctx", type=int, default=4096, help="Context window size")
    parser.add_argument("--n-gpu-layers", type=int, default=-1, help="GPU layers (-1=all)")
    parser.add_argument("--chat-format", type=str, default="chatml", help="Chat template")
    args = parser.parse_args()

    llm_url = args.llm_url

    if not args.api_only and not llm_url:
        model_path = args.model or find_model()
        if model_path is None:
            logger.error(
                "No GGUF model found. Either:\n"
                "  1. Place a .gguf file in ~/Documents/models/\n"
                "  2. Use --model path/to/model.gguf\n"
                "  3. Use --llm-url http://... to point at an external server\n"
                "  4. Use --api-only to skip the LLM server"
            )
            sys.exit(1)

        logger.info(f"Starting LLM server with model: {model_path}")
        llm_url = start_server(
            model_path=model_path,
            port=args.llm_port,
            n_ctx=args.n_ctx,
            n_gpu_layers=args.n_gpu_layers,
            chat_format=args.chat_format,
        )
        # Give the server a moment to bind
        time.sleep(1)

    if llm_url:
        agent.client.base_url = f"{llm_url}/v1"
        logger.info(f"Agent connected to LLM at {llm_url}")
    else:
        logger.warning("No LLM configured — agent will fail on chat requests")

    logger.info(f"Starting agent API server on port {args.api_port}")
    run_api_server(port=args.api_port)


if __name__ == "__main__":
    main()
