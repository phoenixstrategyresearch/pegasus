"""
Tool registry - central hub for registering, discovering, and dispatching tools.
Ported from Hermes Agent's registry pattern.

Tools self-register by calling registry.register() at import time.
The agent loop queries get_tool_schemas() and dispatches via dispatch().
"""

import json
import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

logger = logging.getLogger(__name__)


@dataclass
class ToolEntry:
    name: str
    description: str
    parameters: dict
    handler: Callable
    category: str = "general"
    enabled: bool = True


class ToolRegistry:
    def __init__(self):
        self._tools: dict[str, ToolEntry] = {}

    def register(
        self,
        name: str,
        description: str,
        parameters: dict,
        handler: Callable,
        category: str = "general",
    ):
        """Register a tool with the registry."""
        self._tools[name] = ToolEntry(
            name=name,
            description=description,
            parameters=parameters,
            handler=handler,
            category=category,
        )
        logger.debug(f"Registered tool: {name}")

    def unregister(self, name: str):
        """Remove a tool from the registry."""
        self._tools.pop(name, None)

    def dispatch(self, name: str, arguments: dict) -> Any:
        """Execute a tool by name with given arguments."""
        entry = self._tools.get(name)
        if entry is None:
            return {"error": f"Unknown tool: {name}"}
        if not entry.enabled:
            return {"error": f"Tool '{name}' is currently disabled"}
        try:
            return entry.handler(**arguments)
        except Exception as e:
            import traceback
            print("[TOOL ERROR] " + name + ": " + str(e))
            traceback.print_exc()
            return {"error": f"Tool '{name}' failed: {str(e)}"}

    def get_tool_schemas(self) -> list[dict]:
        """Return OpenAI-format tool schemas for all enabled tools."""
        schemas = []
        for entry in self._tools.values():
            if not entry.enabled:
                continue
            schemas.append({
                "type": "function",
                "function": {
                    "name": entry.name,
                    "description": entry.description,
                    "parameters": entry.parameters,
                },
            })
        return schemas

    def list_tools(self) -> list[dict]:
        """Return summary of all registered tools."""
        return [
            {
                "name": e.name,
                "description": e.description,
                "category": e.category,
                "enabled": e.enabled,
            }
            for e in self._tools.values()
        ]

    def set_enabled(self, name: str, enabled: bool):
        """Enable or disable a tool."""
        if name in self._tools:
            self._tools[name].enabled = enabled


# Global singleton
registry = ToolRegistry()
