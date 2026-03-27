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
import re
import threading
import time
import uuid
from datetime import datetime, timedelta

logger = logging.getLogger(__name__)
print("[CRON] cron_manager.py loaded (v2 — time-of-day support)")

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


def _parse_time(time_str: str) -> tuple[int, int]:
    """Parse a time string like '9:45', '09:45', '9:45am', '2:30pm' into (hour, minute).

    Returns (hour, minute) in 24-hour format.
    """
    s = time_str.strip().lower()
    m = re.match(r'^(\d{1,2}):(\d{2})\s*(am|pm)?$', s)
    if not m:
        raise ValueError(f"Invalid time format: {time_str}. Use e.g. '9:45', '09:45', '2:30pm'.")
    hour, minute = int(m.group(1)), int(m.group(2))
    ampm = m.group(3)
    if ampm == "pm" and hour != 12:
        hour += 12
    elif ampm == "am" and hour == 12:
        hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ValueError(f"Invalid time: {hour}:{minute:02d}")
    return (hour, minute)


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

    def create_job(self, name: str, command: str, interval: str = "", run_at: str = "",
                   repeat: str = "once", job_type: str = "agent") -> dict:
        """
        Create a new cron job.

        Args:
            name: Human-readable job name.
            command: Shell command (type=shell) or agent prompt (type=agent).
            interval: Schedule interval, e.g. '30s', '5m', '2h', '1d'. Mutually exclusive with run_at.
            run_at: Time of day to run, e.g. '9:45', '09:45', '2:30pm'. Mutually exclusive with interval.
            repeat: For run_at jobs: 'once' (fire once then disable) or 'daily'. Ignored for interval jobs.
            job_type: 'agent' runs the full Hermes agent loop, 'shell' runs a command.
        """
        print("[CRON] create_job called: name=" + str(name) + " interval=" + str(interval) + " run_at=" + str(run_at) + " repeat=" + str(repeat) + " job_type=" + str(job_type))
        if job_type not in ("agent", "shell"):
            return {"error": "job_type must be 'agent' or 'shell'"}

        if run_at and interval:
            return {"error": "Provide either 'interval' or 'run_at', not both."}
        if not run_at and not interval:
            return {"error": "Provide either 'interval' (e.g. '5m') or 'run_at' (e.g. '9:45am')."}

        schedule_type = "time" if run_at else "interval"
        interval_secs = None
        run_at_hour = None
        run_at_minute = None

        if schedule_type == "interval":
            try:
                interval_secs = _parse_interval(interval)
            except (ValueError, IndexError):
                return {"error": f"Invalid interval: {interval}. Use e.g. '30s', '5m', '2h', '1d'."}
            if interval_secs < 10:
                return {"error": "Minimum interval is 10 seconds."}
        else:
            try:
                run_at_hour, run_at_minute = _parse_time(run_at)
            except ValueError as e:
                return {"error": str(e)}
            if repeat not in ("once", "daily"):
                return {"error": "repeat must be 'once' or 'daily'."}

        job_id = uuid.uuid4().hex[:8]
        with self._lock:
            self._jobs[job_id] = {
                "id": job_id,
                "name": name,
                "command": command,
                "schedule_type": schedule_type,
                "interval": interval or None,
                "interval_secs": interval_secs,
                "run_at": run_at or None,
                "run_at_hour": run_at_hour,
                "run_at_minute": run_at_minute,
                "repeat": repeat if schedule_type == "time" else None,
                "job_type": job_type,
                "enabled": True,
                "created_at": datetime.now().isoformat(),
                "last_run": None,
                "last_result": None,
                "run_count": 0,
            }
            self._save()

        self._ensure_running()
        sched = f"run_at={run_at}" if run_at else f"interval={interval}"
        print(f"[CRON] Created job '{name}' ({sched}, type={job_type}, repeat={repeat if schedule_type == 'time' else 'n/a'})")
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
                schedule_type = j.get("schedule_type", "interval")
                entry = {
                    "id": j["id"],
                    "name": j["name"],
                    "command": j["command"],
                    "schedule_type": schedule_type,
                    "job_type": j.get("job_type", "shell"),
                    "enabled": j["enabled"],
                    "created_at": j["created_at"],
                    "last_run": j["last_run"],
                    "last_result": j["last_result"],
                    "run_count": j["run_count"],
                }
                if schedule_type == "time":
                    entry["run_at"] = j.get("run_at")
                    entry["repeat"] = j.get("repeat", "once")
                else:
                    entry["interval"] = j.get("interval")
                jobs.append(entry)
            return {"jobs": jobs}

    def update_job(self, job_id: str, **kwargs) -> dict:
        """Update fields on an existing job. Supports: name, command, interval, run_at, repeat, job_type, enabled."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return {"error": f"No job with id '{job_id}'"}

            for key in ("name", "command", "job_type", "enabled"):
                if key in kwargs and kwargs[key] is not None:
                    job[key] = kwargs[key]

            if "interval" in kwargs and kwargs["interval"]:
                try:
                    secs = _parse_interval(kwargs["interval"])
                except (ValueError, IndexError):
                    return {"error": f"Invalid interval: {kwargs['interval']}"}
                if secs < 10:
                    return {"error": "Minimum interval is 10 seconds."}
                job["schedule_type"] = "interval"
                job["interval"] = kwargs["interval"]
                job["interval_secs"] = secs
                job["run_at"] = None
                job["run_at_hour"] = None
                job["run_at_minute"] = None
                job["repeat"] = None

            if "run_at" in kwargs and kwargs["run_at"]:
                try:
                    h, m = _parse_time(kwargs["run_at"])
                except ValueError as e:
                    return {"error": str(e)}
                job["schedule_type"] = "time"
                job["run_at"] = kwargs["run_at"]
                job["run_at_hour"] = h
                job["run_at_minute"] = m
                job["interval"] = None
                job["interval_secs"] = None
                if "repeat" in kwargs:
                    job["repeat"] = kwargs["repeat"]
                elif not job.get("repeat"):
                    job["repeat"] = "once"

            if "repeat" in kwargs and kwargs["repeat"] and job.get("schedule_type") == "time":
                if kwargs["repeat"] not in ("once", "daily"):
                    return {"error": "repeat must be 'once' or 'daily'."}
                job["repeat"] = kwargs["repeat"]

            self._save()
            return {"status": "updated", "job": dict(job)}

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
        print(f"[CRON] Scheduler thread started with {len(self._jobs)} jobs")

    def _run_loop(self):
        # Track next run times in memory (not persisted)
        next_runs: dict[str, float] = {}
        # Track which time-of-day jobs already fired today
        fired_today: dict[str, str] = {}  # job_id -> date string
        action_file = os.path.join(os.environ.get("TMPDIR", "/tmp"), "pegasus_cron_action.json")

        print(f"[CRON] Run loop started, checking every 5s")

        while self._running:
            try:
                now = time.time()
                now_dt = datetime.now()

                # Check for UI actions (toggle/delete via file-based IPC)
                self._process_action_file(action_file)

                with self._lock:
                    jobs_snapshot = [
                        dict(j) for j in self._jobs.values() if j["enabled"]
                    ]

                for job in jobs_snapshot:
                    jid = job["id"]
                    schedule_type = job.get("schedule_type", "interval")

                    if schedule_type == "time":
                        # Time-of-day job
                        target_hour = job.get("run_at_hour", 0)
                        target_minute = job.get("run_at_minute", 0)
                        today_str = now_dt.strftime("%Y-%m-%d")

                        # Already fired today?
                        if fired_today.get(jid) == today_str:
                            continue

                        # Check if we're at or past the target time
                        if now_dt.hour > target_hour or (now_dt.hour == target_hour and now_dt.minute >= target_minute):
                            # Don't fire if the job was created well after the target time today
                            # (grace: fire if created within 2 minutes of target)
                            created = job.get("created_at", "")
                            skip = False
                            if created:
                                try:
                                    created_dt = datetime.fromisoformat(created)
                                    if created_dt.date() == now_dt.date():
                                        created_target = created_dt.replace(hour=target_hour, minute=target_minute, second=0)
                                        seconds_after = (created_dt - created_target).total_seconds()
                                        if seconds_after > 120:
                                            # Created more than 2 min after target time today, skip until tomorrow
                                            print(f"[CRON] Skipping '{job['name']}' — created {int(seconds_after)}s after target {target_hour}:{target_minute:02d}")
                                            fired_today[jid] = today_str
                                            skip = True
                                except (ValueError, TypeError) as e:
                                    print(f"[CRON] Error parsing created_at for '{job['name']}': {e}")

                            if skip:
                                continue

                            print(f"[CRON] FIRING time job '{job['name']}' (target {target_hour}:{target_minute:02d}, now {now_dt.strftime('%H:%M:%S')})")
                            fired_today[jid] = today_str
                            self._execute_job(job)

                            # If once-only, disable the job after firing
                            if job.get("repeat") == "once":
                                with self._lock:
                                    if jid in self._jobs:
                                        self._jobs[jid]["enabled"] = False
                                        self._save()
                                        print(f"[CRON] '{job['name']}' fired (once) — now disabled")
                        else:
                            # Not yet time — log occasionally (every ~60s)
                            if int(now) % 60 < 6:
                                print(f"[CRON] Waiting for '{job['name']}' at {target_hour}:{target_minute:02d} (now {now_dt.strftime('%H:%M:%S')})")
                    else:
                        # Interval job
                        isecs = job.get("interval_secs")
                        if not isecs:
                            continue
                        if jid not in next_runs:
                            next_runs[jid] = now + isecs
                            print(f"[CRON] Scheduled interval job '{job['name']}' — next run in {isecs}s")
                            continue
                        if now >= next_runs[jid]:
                            print(f"[CRON] FIRING interval job '{job['name']}'")
                            self._execute_job(job)
                            next_runs[jid] = now + isecs

                # Clean up next_runs / fired_today for deleted jobs
                with self._lock:
                    active_ids = set(self._jobs.keys())
                for jid in list(next_runs.keys()):
                    if jid not in active_ids:
                        del next_runs[jid]
                for jid in list(fired_today.keys()):
                    if jid not in active_ids:
                        del fired_today[jid]

            except Exception as e:
                print(f"[CRON] ERROR in run loop: {e}")
                import traceback
                traceback.print_exc()

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
            elif action == "update":
                kwargs = {}
                for key in ("name", "command", "interval", "run_at", "repeat", "job_type", "enabled"):
                    if key in payload and payload[key] is not None and payload[key] != "":
                        kwargs[key] = payload[key]
                result = self.update_job(job_id, **kwargs)
                logger.info(f"Cron action update: {result}")
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
        print(f"[CRON] Executing '{job['name']}' ({job_type}): {command[:100]}")

        try:
            if job_type == "agent" and self._agent_fn is not None:
                output = self._run_agent_job(command)
            else:
                output = self._run_shell_job(command)
        except Exception as e:
            print(f"[CRON] Execute failed for '{job['name']}': {e}")
            output = {"type": job_type, "error": str(e)}

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
            print(f"[CRON] Agent job failed: {e}")
            import traceback
            traceback.print_exc()
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
print(f"[CRON] CronManager initialized, {len(cron._jobs)} persisted jobs")
