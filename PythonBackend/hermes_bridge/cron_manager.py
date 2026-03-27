"""
Cron manager - lightweight in-process job scheduler.
Jobs are persisted to a JSON file and executed on schedule via a background thread.

Supports two job types:
  - "shell": run a shell command in the sandbox
  - "agent": send a prompt through the full Hermes agent loop (tools, memory, etc.)
"""

import json
import logging
import os
import threading
import time
import uuid
from datetime import datetime

logger = logging.getLogger(__name__)

SANDBOX_ROOT = os.path.expanduser("~/Documents/pegasus_workspace")
CRON_FILE = os.path.join(SANDBOX_ROOT, ".pegasus_cron.json")
LOG_DIR = os.path.join(SANDBOX_ROOT, ".cron_logs")


def _parse_interval(interval_str: str) -> int:
    """Parse an interval string like '5m', '2h', '30s', '1d' into seconds."""
    s = interval_str.strip().lower()
    if s.endswith("s"):
        return int(s[:-1])
    if s.endswith("m"):
        return int(s[:-1]) * 60
    if s.endswith("h"):
        return int(s[:-1]) * 3600
    if s.endswith("d"):
        return int(s[:-1]) * 86400
    return int(s)


class CronManager:
    def __init__(self):
        self._jobs: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._running = False
        self._thread: threading.Thread | None = None
        self._agent_fn = None  # set via set_agent() to avoid circular imports
        self._load()

    def set_agent(self, agent_runner):
        """Provide the AgentRunner so cron jobs can run full agent prompts."""
        self._agent_fn = agent_runner

    def _load(self):
        if os.path.isfile(CRON_FILE):
            try:
                with open(CRON_FILE, "r", encoding="utf-8") as f:
                    self._jobs = json.load(f)
            except (json.JSONDecodeError, IOError):
                self._jobs = {}

    def _save(self):
        os.makedirs(os.path.dirname(CRON_FILE), exist_ok=True)
        with open(CRON_FILE, "w", encoding="utf-8") as f:
            json.dump(self._jobs, f, indent=2)

    def create_job(self, name: str, command: str, interval: str, job_type: str = "agent") -> dict:
        """
        Create a new cron job.

        Args:
            name: Human-readable job name.
            command: Shell command (type=shell) or agent prompt (type=agent).
            interval: Schedule interval, e.g. '30s', '5m', '2h', '1d'.
            job_type: 'agent' runs the full Hermes agent loop, 'shell' runs a command.
        """
        if job_type not in ("agent", "shell"):
            return {"error": "job_type must be 'agent' or 'shell'"}

        try:
            interval_secs = _parse_interval(interval)
        except (ValueError, IndexError):
            return {"error": f"Invalid interval: {interval}. Use e.g. '30s', '5m', '2h', '1d'."}

        if interval_secs < 10:
            return {"error": "Minimum interval is 10 seconds."}

        job_id = uuid.uuid4().hex[:8]
        with self._lock:
            self._jobs[job_id] = {
                "id": job_id,
                "name": name,
                "command": command,
                "interval": interval,
                "interval_secs": interval_secs,
                "job_type": job_type,
                "enabled": True,
                "created_at": datetime.now().isoformat(),
                "last_run": None,
                "last_result": None,
                "run_count": 0,
            }
            self._save()

        self._ensure_running()
        return {"status": "created", "job": self._jobs[job_id]}

    def delete_job(self, job_id: str) -> dict:
        with self._lock:
            job = self._jobs.pop(job_id, None)
            if job is None:
                return {"error": f"No job with id '{job_id}'"}
            self._save()
        return {"status": "deleted", "name": job["name"]}

    def list_jobs(self) -> dict:
        with self._lock:
            jobs = []
            for j in self._jobs.values():
                jobs.append({
                    "id": j["id"],
                    "name": j["name"],
                    "command": j["command"],
                    "interval": j["interval"],
                    "job_type": j.get("job_type", "shell"),
                    "enabled": j["enabled"],
                    "created_at": j["created_at"],
                    "last_run": j["last_run"],
                    "last_result": j["last_result"],
                    "run_count": j["run_count"],
                })
            return {"jobs": jobs}

    def toggle_job(self, job_id: str, enabled: bool) -> dict:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return {"error": f"No job with id '{job_id}'"}
            job["enabled"] = enabled
            self._save()
        if enabled:
            self._ensure_running()
        return {"status": "ok", "id": job_id, "enabled": enabled}

    def _ensure_running(self):
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()
        logger.info("Cron scheduler started")

    def _run_loop(self):
        # Track next run times in memory (not persisted)
        next_runs: dict[str, float] = {}
        action_file = os.path.join(os.environ.get("TMPDIR", "/tmp"), "pegasus_cron_action.json")

        while self._running:
            now = time.time()

            # Check for UI actions (toggle/delete via file-based IPC)
            self._process_action_file(action_file)

            with self._lock:
                jobs_snapshot = [
                    dict(j) for j in self._jobs.values() if j["enabled"]
                ]

            for job in jobs_snapshot:
                jid = job["id"]
                if jid not in next_runs:
                    # First tick after start/create: schedule from now
                    next_runs[jid] = now + job["interval_secs"]
                    continue
                if now >= next_runs[jid]:
                    self._execute_job(job)
                    next_runs[jid] = now + job["interval_secs"]

            # Clean up next_runs for deleted jobs
            with self._lock:
                active_ids = set(self._jobs.keys())
            for jid in list(next_runs.keys()):
                if jid not in active_ids:
                    del next_runs[jid]

            time.sleep(5)

    def _process_action_file(self, action_file: str):
        """Check for and process UI action requests (toggle/delete) via file-based IPC."""
        if not os.path.isfile(action_file):
            return
        try:
            with open(action_file, "r", encoding="utf-8") as f:
                payload = json.load(f)
            os.remove(action_file)
            action = payload.get("action", "")
            job_id = payload.get("job_id", "")
            if action == "toggle":
                with self._lock:
                    job = self._jobs.get(job_id)
                    if job:
                        job["enabled"] = not job["enabled"]
                        self._save()
                        logger.info(f"Cron [{job['name']}] toggled to {'enabled' if job['enabled'] else 'disabled'}")
            elif action == "delete":
                result = self.delete_job(job_id)
                logger.info(f"Cron action delete: {result}")
            elif action == "enable":
                self.toggle_job(job_id, True)
            elif action == "disable":
                self.toggle_job(job_id, False)
            else:
                logger.warning(f"Unknown cron action: {action}")
        except Exception as e:
            logger.warning(f"Failed to process cron action file: {e}")
            try:
                os.remove(action_file)
            except OSError:
                pass

    def _execute_job(self, job: dict):
        job_id = job["id"]
        job_type = job.get("job_type", "shell")
        command = job["command"]
        logger.info(f"Cron [{job['name']}] ({job_type}): {command[:100]}")

        if job_type == "agent" and self._agent_fn is not None:
            output = self._run_agent_job(command)
        else:
            output = self._run_shell_job(command)

        # Save log to file
        self._save_log(job, output)

        with self._lock:
            if job_id in self._jobs:
                self._jobs[job_id]["last_run"] = datetime.now().isoformat()
                self._jobs[job_id]["last_result"] = output
                self._jobs[job_id]["run_count"] = self._jobs[job_id].get("run_count", 0) + 1
                self._save()

    def _run_agent_job(self, prompt: str) -> dict:
        """Run a prompt through the full Hermes agent loop.

        Creates a fresh AgentRunner each time so it always uses:
        - The latest system prompt (picks up memory/skill changes)
        - The latest tool registry (picks up new/toggled tools)
        - A clean conversation history (no cross-contamination with user chat)
        """
        try:
            from .agent_runner import AgentRunner

            main = self._agent_fn
            runner = AgentRunner(
                model=main.model if main else "local-model",
                max_iterations=main.max_iterations if main else 5,
            )
            response = runner.run(prompt)
            return {"type": "agent", "response": response[:10000]}
        except Exception as e:
            logger.exception("Cron agent job failed")
            return {"type": "agent", "error": str(e)}

    def _run_shell_job(self, command: str) -> dict:
        """Run a shell command via the emulated shell (works on iOS)."""
        try:
            from .tools_builtin import shell_exec
            result = shell_exec(command)
            if isinstance(result, dict):
                return {
                    "type": "shell",
                    "stdout": result.get("output", "")[:5000],
                    "stderr": result.get("error", "")[:2000],
                    "returncode": 0 if "error" not in result else 1,
                }
            return {"type": "shell", "stdout": str(result)[:5000], "returncode": 0}
        except Exception as e:
            return {"type": "shell", "error": str(e)}

    def _save_log(self, job: dict, output: dict):
        """Append run output to a per-job log file."""
        os.makedirs(LOG_DIR, exist_ok=True)
        log_path = os.path.join(LOG_DIR, f"{job['id']}.log")
        entry = {
            "timestamp": datetime.now().isoformat(),
            "name": job["name"],
            "output": output,
        }
        with open(log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def get_job_logs(self, job_id: str, tail: int = 10) -> dict:
        """Read the last N log entries for a job."""
        log_path = os.path.join(LOG_DIR, f"{job_id}.log")
        if not os.path.isfile(log_path):
            return {"job_id": job_id, "logs": []}
        with open(log_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        entries = []
        for line in lines[-tail:]:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return {"job_id": job_id, "logs": entries}

    def start(self):
        """Start the scheduler if there are enabled jobs."""
        with self._lock:
            has_enabled = any(j["enabled"] for j in self._jobs.values())
        if has_enabled:
            self._ensure_running()

    def stop(self):
        self._running = False


cron = CronManager()
