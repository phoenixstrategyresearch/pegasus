"""
HTTP API server that the SwiftUI frontend communicates with.
Runs on localhost:5005 and bridges the iOS UI to the agent loop.

Endpoints:
  POST /chat          - send a message, get agent response
  POST /chat/stream   - send a message, get streaming SSE response
  GET  /status        - server + model status
  POST /model/load    - load a GGUF model
  POST /model/unload  - unload current model
  GET  /models        - list available GGUF files
  GET  /tools         - list registered tools
  POST /tools/toggle  - enable/disable a tool
  GET  /memory        - read memory
  GET  /skills        - list skills
  POST /reset         - reset conversation
"""

import json
import logging
import os
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import threading

from . import tools_builtin  # registers all built-in tools
from .agent_runner import AgentRunner
from .llm_server import start_server, stop_server, get_model_info, find_model, MODEL_SEARCH_PATHS
from .tool_registry import registry
from .memory_manager import memory
from .skill_manager import skills
from .cron_manager import cron

logger = logging.getLogger(__name__)

agent = AgentRunner()
_llm_base_url = None

# Give the cron manager access to the agent so 'agent' type jobs
# run the full Hermes loop (tools, memory, skills, everything).
cron.set_agent(agent)


class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        logger.debug(format % args)

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/status":
            self._send_json({
                "agent": "running",
                "model": get_model_info(),
                "llm_url": _llm_base_url,
                "history_length": len(agent.conversation_history),
            })

        elif path == "/models":
            models = []
            for search_path in MODEL_SEARCH_PATHS:
                if not os.path.isdir(search_path):
                    continue
                for f in os.listdir(search_path):
                    if f.endswith(".gguf"):
                        full = os.path.join(search_path, f)
                        models.append({
                            "name": f,
                            "path": full,
                            "size_mb": round(os.path.getsize(full) / 1024 / 1024, 1),
                        })
            self._send_json({"models": models})

        elif path == "/tools":
            self._send_json({"tools": registry.list_tools()})

        elif path == "/memory":
            self._send_json({
                "memory": memory.read_memory(),
                "user": memory.read_user(),
            })

        elif path == "/skills":
            self._send_json({"skills": skills.list_skills()})

        elif path == "/cron":
            self._send_json(cron.list_jobs())

        elif path.startswith("/cron/logs/"):
            job_id = path.split("/")[-1]
            params = parse_qs(urlparse(self.path).query)
            tail = int(params.get("tail", ["20"])[0])
            self._send_json(cron.get_job_logs(job_id, tail))

        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        global _llm_base_url
        path = urlparse(self.path).path

        if path == "/chat":
            body = self._read_body()
            message = body.get("message", "")
            if not message:
                self._send_json({"error": "No message provided"}, 400)
                return
            response = agent.run(message)
            self._send_json({"response": response})

        elif path == "/chat/stream":
            body = self._read_body()
            message = body.get("message", "")
            if not message:
                self._send_json({"error": "No message provided"}, 400)
                return

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            try:
                for event in agent.run_streaming(message):
                    data = json.dumps(event)
                    self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                agent.interrupt()

        elif path == "/model/load":
            body = self._read_body()
            model_path = body.get("model_path")
            n_ctx = body.get("n_ctx", 4096)
            n_gpu_layers = body.get("n_gpu_layers", -1)
            chat_format = body.get("chat_format", "chatml")
            try:
                url = start_server(
                    model_path=model_path,
                    n_ctx=n_ctx,
                    n_gpu_layers=n_gpu_layers,
                    chat_format=chat_format,
                )
                _llm_base_url = url
                agent.client.base_url = f"{url}/v1"
                # Returns immediately - model loads in background.
                # Client should poll /status until model.status == "loaded".
                self._send_json({"status": "loading", "url": url})
            except Exception as e:
                self._send_json({"error": str(e)}, 500)

        elif path == "/model/unload":
            stop_server()
            _llm_base_url = None
            self._send_json({"status": "unloaded"})

        elif path == "/tools/toggle":
            body = self._read_body()
            name = body.get("name")
            enabled = body.get("enabled", True)
            registry.set_enabled(name, enabled)
            self._send_json({"status": "ok", "name": name, "enabled": enabled})

        elif path == "/reset":
            agent.reset()
            self._send_json({"status": "reset"})

        elif path == "/interrupt":
            agent.interrupt()
            self._send_json({"status": "interrupted"})

        elif path == "/cron/create":
            body = self._read_body()
            result = cron.create_job(
                name=body.get("name", ""),
                command=body.get("command", ""),
                interval=body.get("interval", ""),
                job_type=body.get("job_type", "agent"),
            )
            status = 400 if "error" in result else 200
            self._send_json(result, status)

        elif path == "/cron/delete":
            body = self._read_body()
            result = cron.delete_job(body.get("job_id", ""))
            status = 404 if "error" in result else 200
            self._send_json(result, status)

        elif path == "/cron/toggle":
            body = self._read_body()
            result = cron.toggle_job(body.get("job_id", ""), body.get("enabled", True))
            status = 404 if "error" in result else 200
            self._send_json(result, status)

        else:
            self._send_json({"error": "Not found"}, 404)


def run_api_server(host="127.0.0.1", port=5005):
    """Start the API server for the SwiftUI frontend."""
    # Resume any persisted cron jobs
    cron.start()

    server = HTTPServer((host, port), APIHandler)
    logger.info(f"Pegasus API server running at http://{host}:{port}")
    print(f"Pegasus API server running at http://{host}:{port}")
    server.serve_forever()


def start_api_server_background(host="127.0.0.1", port=5005):
    """Start the API server in a background thread."""
    t = threading.Thread(target=run_api_server, args=(host, port), daemon=True)
    t.start()
    return t


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    run_api_server()
