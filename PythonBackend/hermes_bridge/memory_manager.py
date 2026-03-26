"""
Persistent memory manager - bounded file-backed storage.
Ported from Hermes Agent's memory system.

Two stores:
- MEMORY.md: Agent observations, learned patterns, environment notes
- USER.md: User preferences, communication style, workflow habits

Limits scale with mode:
- Local: 2200 / 1375 chars (fits in small context windows)
- Cloud: 20000 / 10000 chars (GPT-5.4 has 272K context)

Uses section sign (S) as delimiter between entries.
"""

import os
import threading
from pathlib import Path

MEMORY_DIR = os.environ.get("PEGASUS_DATA_DIR", os.path.expanduser("~/Documents/pegasus_data"))
MEMORY_FILE = os.path.join(MEMORY_DIR, "MEMORY.md")
USER_FILE = os.path.join(MEMORY_DIR, "USER.md")

MEMORY_LIMIT_LOCAL = 2200
MEMORY_LIMIT_CLOUD = 20000
USER_LIMIT_LOCAL = 1375
USER_LIMIT_CLOUD = 10000
DELIMITER = "\n\u00a7 "


def _is_cloud():
    try:
        from . import tools_builtin
        return tools_builtin._CLOUD_MODE
    except Exception:
        return False


class MemoryManager:
    def __init__(self):
        self._lock = threading.Lock()
        os.makedirs(MEMORY_DIR, exist_ok=True)

    def _read_file(self, path: str) -> str:
        if not os.path.isfile(path):
            return ""
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    def _write_file(self, path: str, content: str, limit: int):
        content = content.strip()
        if len(content) > limit:
            # Truncate from the beginning, keeping newest entries
            content = content[-limit:]
            # Clean up partial entry at the start
            idx = content.find(DELIMITER)
            if idx > 0:
                content = content[idx:]
        with self._lock:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)

    # -- MEMORY.md --

    def read_memory(self) -> str:
        return self._read_file(MEMORY_FILE)

    @property
    def _memory_limit(self):
        return MEMORY_LIMIT_CLOUD if _is_cloud() else MEMORY_LIMIT_LOCAL

    @property
    def _user_limit(self):
        return USER_LIMIT_CLOUD if _is_cloud() else USER_LIMIT_LOCAL

    def add_memory(self, entry: str):
        current = self.read_memory()
        if entry in current:
            return  # Deduplicate
        new = current + DELIMITER + entry if current else entry
        self._write_file(MEMORY_FILE, new, self._memory_limit)

    def replace_memory(self, old: str, new: str):
        current = self.read_memory()
        updated = current.replace(old, new)
        self._write_file(MEMORY_FILE, updated, self._memory_limit)

    def remove_memory(self, entry: str):
        current = self.read_memory()
        updated = current.replace(entry, "").replace(DELIMITER + DELIMITER, DELIMITER)
        self._write_file(MEMORY_FILE, updated, self._memory_limit)

    # -- USER.md --

    def read_user(self) -> str:
        return self._read_file(USER_FILE)

    def add_user(self, entry: str):
        current = self.read_user()
        if entry in current:
            return
        new = current + DELIMITER + entry if current else entry
        self._write_file(USER_FILE, new, self._user_limit)

    def replace_user(self, old: str, new: str):
        current = self.read_user()
        updated = current.replace(old, new)
        self._write_file(USER_FILE, updated, self._user_limit)

    def remove_user(self, entry: str):
        current = self.read_user()
        updated = current.replace(entry, "").replace(DELIMITER + DELIMITER, DELIMITER)
        self._write_file(USER_FILE, updated, self._user_limit)


# Global singleton
memory = MemoryManager()
