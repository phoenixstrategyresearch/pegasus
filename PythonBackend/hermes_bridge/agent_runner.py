"""
Core agent loop inspired by Hermes Agent architecture.
Runs a tool-calling conversation loop against the local LLM server.

Uses stdlib urllib.request (no external dependencies) to call the
OpenAI-compatible endpoint provided by LocalOpenAIServer (Swift).

This is the heart of the agent - it:
1. Sends messages to the LLM with tool schemas
2. Parses tool_calls from the response
3. Dispatches tools via the registry
4. Appends results and loops until the LLM gives a final answer
"""

import json
import logging
import os
import time
from typing import Optional

from .tool_registry import registry
from .memory_manager import memory
from .skill_manager import skills
from .prompt_builder import build_system_prompt

logger = logging.getLogger(__name__)

DEFAULT_MAX_ITERATIONS = 100
# Max total chars for all messages sent to the LLM.
# On-device models typically have 2K-8K context (in tokens).
# Rough estimate: 1 token ~ 4 chars, so 8K tokens ~ 32K chars.
# We use a conservative limit to leave room for the response.
MAX_CONTEXT_CHARS = 12000  # on-device default
MAX_CONTEXT_CHARS_CLOUD = 200000  # cloud models handle much larger contexts


def _get_tmpdir():
    """Get tmp dir at call time, not import time, so TMPDIR env var is respected."""
    return os.environ.get("TMPDIR", "/tmp")


def _get_llm_request_file():
    return os.path.join(_get_tmpdir(), "pegasus_llm_request.json")


def _get_llm_response_file():
    return os.path.join(_get_tmpdir(), "pegasus_llm_response.json")


def _trim_messages(messages, max_chars=MAX_CONTEXT_CHARS):
    """Trim messages to fit within context limit.

    CRITICAL: Never orphan tool messages. A 'tool' message MUST always be
    preceded by an 'assistant' message that has 'tool_calls'. Dropping one
    without the other causes OpenAI API errors.

    Strategy:
    1. Truncate long tool result content
    2. Find safe cut points (never split assistant+tool groups)
    3. Drop oldest non-system message groups if over limit
    4. Aggressively truncate content as last resort
    """
    if not messages:
        return messages

    # First pass: truncate long tool result content
    for msg in messages:
        if msg.get("role") == "tool":
            content = msg.get("content", "")
            if len(content) > 2000:
                msg["content"] = content[:2000] + "\n[trimmed]"

    total = sum(len(json.dumps(m, ensure_ascii=False)) for m in messages)
    if total <= max_chars:
        return messages

    # Group messages into atomic units that can't be split:
    # - system message alone
    # - user message alone
    # - assistant (no tool_calls) alone
    # - assistant (with tool_calls) + all following tool messages = one group
    groups = []
    i = 0
    while i < len(messages):
        msg = messages[i]
        if msg.get("role") == "assistant" and msg.get("tool_calls"):
            # This assistant + all following tool messages are one atomic group
            group = [msg]
            j = i + 1
            while j < len(messages) and messages[j].get("role") == "tool":
                group.append(messages[j])
                j += 1
            groups.append(group)
            i = j
        else:
            groups.append([msg])
            i += 1

    # Second pass: drop oldest non-system groups until under limit
    # Always keep first group (system) and last 2 groups
    while len(groups) > 3:
        total = sum(len(json.dumps(m, ensure_ascii=False)) for g in groups for m in g)
        if total <= max_chars:
            break
        # Drop the second group (oldest after system)
        groups.pop(1)

    # Flatten groups back to messages
    result = []
    for g in groups:
        result.extend(g)

    # Third pass: aggressively truncate content if still over
    total = sum(len(json.dumps(m, ensure_ascii=False)) for m in result)
    if total > max_chars:
        for msg in result:
            content = msg.get("content", "")
            if isinstance(content, str) and len(content) > 1000:
                msg["content"] = content[:1000] + "\n[trimmed]"

    return result


class LLMClient:
    """LLM client using file-based IPC instead of HTTP.

    Python writes a request JSON file, Swift picks it up, runs inference,
    and writes a response JSON file. No sockets needed.
    """

    def __init__(self, **kwargs):
        self.request_file = _get_llm_request_file()
        self.response_file = _get_llm_response_file()
        print(f"[LLM-IPC-PY] Init: request={self.request_file}")
        print(f"[LLM-IPC-PY] Init: response={self.response_file}")
        print(f"[LLM-IPC-PY] TMPDIR={os.environ.get('TMPDIR', 'NOT SET')}")
        logger.info(f"LLMClient using file IPC: request={self.request_file}, response={self.response_file}")

    @staticmethod
    def _clean_text(text):
        """Force text to pure ASCII with no control characters."""
        if not isinstance(text, str):
            return text
        # Strip control characters (U+0000-U+001F except \n \r \t)
        text = ''.join(c if c in ('\n', '\r', '\t') or ord(c) >= 32 else ' ' for c in text)
        # Replace common non-ASCII with ASCII equivalents
        replacements = {
            '\u2014': '-', '\u2013': '-',  # em/en dash
            '\u2018': "'", '\u2019': "'",  # smart quotes
            '\u201c': '"', '\u201d': '"',  # smart double quotes
            '\u2026': '...', '\u00a0': ' ',  # ellipsis, nbsp
            '\u2022': '-', '\u00b7': '-',  # bullets
            '\u2192': '->', '\u2190': '<-',  # arrows
            '\ufffd': '?',  # replacement character from bad decodes
        }
        for old, new in replacements.items():
            text = text.replace(old, new)
        return text.encode('ascii', 'replace').decode('ascii')

    def _clean_messages(self, messages):
        """Deep-clean all string content in messages for safe JSON serialization."""
        cleaned = []
        for msg in messages:
            m = dict(msg)
            if 'content' in m and isinstance(m['content'], str):
                m['content'] = self._clean_text(m['content'])
            # Also clean tool_call arguments (they contain web content sometimes)
            if 'tool_calls' in m and isinstance(m['tool_calls'], list):
                clean_tcs = []
                for tc in m['tool_calls']:
                    tc = dict(tc)
                    if 'function' in tc:
                        tc['function'] = dict(tc['function'])
                        if isinstance(tc['function'].get('arguments'), str):
                            tc['function']['arguments'] = self._clean_text(tc['function']['arguments'])
                    clean_tcs.append(tc)
                m['tool_calls'] = clean_tcs
            cleaned.append(m)
        return cleaned

    def chat_completions(self, model, messages, tools=None, temperature=0.6, max_tokens=None):
        """Write request to file, wait for Swift to write response."""
        is_cloud = model != "local-model"
        # Cloud models get higher token limits
        if max_tokens is None:
            max_tokens = 16384 if is_cloud else 4096
        # Force all message content to ASCII to prevent JSON parse failures
        clean_msgs = self._clean_messages(messages)
        body = {
            "model": model,
            "messages": clean_msgs,
            "temperature": temperature,
        }
        # GPT-5.x requires max_completion_tokens (max_tokens is deprecated and errors)
        if is_cloud:
            body["max_completion_tokens"] = max_tokens
        else:
            body["max_tokens"] = max_tokens
        if tools:
            body["tools"] = tools
            body["tool_choice"] = "auto"

        # Re-resolve paths each call in case TMPDIR changed
        self.request_file = _get_llm_request_file()
        self.response_file = _get_llm_response_file()

        # Clean up any stale response file
        try:
            os.remove(self.response_file)
        except OSError:
            pass

        # Serialize to string first, validate, then write atomically
        json_str = json.dumps(body, ensure_ascii=True)
        # Verify it's valid JSON before writing (catches any corruption)
        json.loads(json_str)

        # Write atomically: temp file -> fsync -> rename
        # This prevents Swift from reading a partially-written file
        tmp_request = self.request_file + ".tmp"
        with open(tmp_request, "w", encoding="ascii") as f:
            f.write(json_str)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp_request, self.request_file)

        print(f"[LLM-IPC-PY] Request written, waiting for response...")
        logger.info("LLM request written, waiting for response...")

        # Poll for response - use open() directly instead of os.path.exists()
        # because stat() can be unreliable in embedded Python on iOS
        timeout = 1800  # 30 minutes — cloud models can take 60s+ per call, complex tasks need many iterations
        interrupt_file = os.path.join(_get_tmpdir(), "pegasus_interrupt")
        start = time.time()
        poll_count = 0
        while time.time() - start < timeout:
            poll_count += 1

            # Check for interrupt every poll — allows fast cancellation
            try:
                with open(interrupt_file, "r") as _if:
                    _if.read()
                # Interrupt file exists — abort immediately
                try:
                    os.remove(interrupt_file)
                except OSError:
                    pass
                try:
                    os.remove(self.request_file)
                except OSError:
                    pass
                raise InterruptedError("Agent interrupted")
            except FileNotFoundError:
                pass

            try:
                with open(self.response_file, "r", encoding="utf-8") as f:
                    raw = f.read()
                if not raw or len(raw) < 2:
                    # File exists but is empty/incomplete - wait for write to finish
                    time.sleep(0.1)
                    continue
                result = json.loads(raw)
                try:
                    os.remove(self.response_file)
                except OSError:
                    pass
                elapsed = time.time() - start
                print(f"[LLM-IPC-PY] Response received ({len(raw)} bytes, {elapsed:.1f}s, {poll_count} polls)")
                return result
            except FileNotFoundError:
                # Response not written yet - keep polling
                pass
            except json.JSONDecodeError:
                # File partially written - wait and retry
                time.sleep(0.1)
                continue
            except IOError:
                pass

            if poll_count % 100 == 0:
                elapsed = time.time() - start
                print(f"[LLM-IPC-PY] Still waiting... ({elapsed:.0f}s, {poll_count} polls)")
                tmpdir = _get_tmpdir()
                try:
                    files = [f for f in os.listdir(tmpdir) if 'pegasus' in f]
                    print(f"[LLM-IPC-PY] Pegasus files in tmp: {files}")
                except Exception:
                    pass

            time.sleep(0.05)

        raise RuntimeError(f"LLM response timed out after {timeout}s ({poll_count} polls)")


class AgentRunner:
    _HISTORY_FILE = os.path.join(
        os.environ.get("PEGASUS_DATA_DIR", os.path.expanduser("~/Documents/pegasus_data")),
        "conversation_history.json"
    )

    def __init__(
        self,
        model="local-model",
        max_iterations=DEFAULT_MAX_ITERATIONS,
        **kwargs,
    ):
        self.client = LLMClient()
        self.model = model
        self.max_iterations = max_iterations
        self.conversation_history = self._load_history()
        self.interrupt_requested = False
        # Set cloud mode flag for tools (affects truncation, limits, etc.)
        from . import tools_builtin
        tools_builtin._CLOUD_MODE = (model != "local-model")

    def _load_history(self) -> list:
        """Load conversation history from disk."""
        try:
            with open(self._HISTORY_FILE, "r", encoding="utf-8") as f:
                data = json.loads(f.read())
            if isinstance(data, list):
                print(f"[Agent] Loaded {len(data)} messages from history")
                return data
        except (FileNotFoundError, json.JSONDecodeError, IOError):
            pass
        return []

    def _save_history(self):
        """Persist conversation history to disk."""
        try:
            os.makedirs(os.path.dirname(self._HISTORY_FILE), exist_ok=True)
            with open(self._HISTORY_FILE, "w", encoding="utf-8") as f:
                json.dump(self.conversation_history, f, ensure_ascii=True)
        except Exception as e:
            print(f"[Agent] Failed to save history: {e}")

    def reset(self):
        """Clear conversation history."""
        self.conversation_history = []
        self.interrupt_requested = False
        self._save_history()

    def compact(self):
        """Summarize conversation history into a compact summary message.

        Replaces all history with a single assistant message containing
        a summary, freeing context window space while preserving key info.
        """
        if len(self.conversation_history) < 4:
            return "Nothing to compact."

        # Build a text representation of the conversation for summarization
        lines = []
        for msg in self.conversation_history:
            role = msg.get("role", "unknown")
            content = msg.get("content", "")
            if role == "tool":
                # Truncate tool results for summary input
                content = content[:500] if len(content) > 500 else content
                lines.append(f"[Tool Result] {content}")
            elif role == "assistant" and msg.get("tool_calls"):
                tool_names = [tc["function"]["name"] for tc in msg["tool_calls"]]
                lines.append(f"[Assistant called: {', '.join(tool_names)}]")
                if content:
                    lines.append(f"[Assistant] {content[:500]}")
            else:
                lines.append(f"[{role.title()}] {content[:1000]}")

        conversation_text = "\n".join(lines)
        # Truncate if extremely long
        if len(conversation_text) > 30000:
            conversation_text = conversation_text[:30000] + "\n[...truncated...]"

        summary_request = [
            {"role": "system", "content": "You are a conversation summarizer. Produce a concise summary of the conversation below. Include: key topics discussed, important facts/decisions, files created or modified, tools used and their outcomes, and any pending tasks. Be thorough but concise."},
            {"role": "user", "content": f"Summarize this conversation:\n\n{conversation_text}"}
        ]

        try:
            result = self.client.chat_completions(
                model=self.model,
                messages=summary_request,
                tools=None,
                temperature=0.3,
            )
            summary = result["choices"][0]["message"].get("content", "")
            if not summary:
                return "Failed to generate summary."
        except Exception as e:
            return f"Compact failed: {e}"

        old_count = len(self.conversation_history)
        self.conversation_history = [
            {"role": "assistant", "content": f"[Conversation Summary — {old_count} messages compacted]\n\n{summary}"}
        ]
        self._save_history()
        return f"Compacted {old_count} messages into summary."

    def interrupt(self):
        """Signal the agent loop to stop."""
        self.interrupt_requested = True

    def _check_interrupt(self):
        """Check for interrupt signal from Swift."""
        interrupt_file = os.path.join(_get_tmpdir(), "pegasus_interrupt")
        if os.path.exists(interrupt_file):
            try:
                os.remove(interrupt_file)
            except OSError:
                pass
            self.interrupt_requested = True
        return self.interrupt_requested

    def run(self, user_message: str) -> str:
        """
        Run the agent loop for a single user turn.

        1. Append user message to history
        2. Build system prompt with memory + skills index
        3. Loop: call LLM -> check for tool_calls -> dispatch -> append results
        4. Return final assistant text
        """
        self.interrupt_requested = False
        # Clear any stale interrupt signal
        try:
            os.remove(os.path.join(_get_tmpdir(), "pegasus_interrupt"))
        except OSError:
            pass

        # Build system prompt fresh each turn (picks up memory changes)
        system_prompt = build_system_prompt()

        self.conversation_history.append({
            "role": "user",
            "content": user_message,
        })

        # Assemble messages for the API call
        messages = [{"role": "system", "content": system_prompt}] + self.conversation_history

        # Limit tools to reduce prompt size for small on-device models
        tool_schemas = registry.get_tool_schemas()

        iteration = 0
        while iteration < self.max_iterations and not self._check_interrupt():
            iteration += 1
            logger.info(f"Agent iteration {iteration}/{self.max_iterations}")

            # Trim messages to fit context window
            ctx_limit = MAX_CONTEXT_CHARS_CLOUD if self.model != "local-model" else MAX_CONTEXT_CHARS
            messages = _trim_messages(messages, max_chars=ctx_limit)

            try:
                llm_result = self.client.chat_completions(
                    model=self.model,
                    messages=messages,
                    tools=tool_schemas if tool_schemas else None,
                    temperature=0.6,
                )
            except Exception as e:
                error_msg = f"LLM call failed: {e}"
                logger.error(error_msg)
                self.conversation_history.append({
                    "role": "assistant",
                    "content": error_msg,
                })
                self._save_history()
                return error_msg

            choice = llm_result["choices"][0]
            message = choice["message"]
            content = message.get("content") or ""
            tool_calls = message.get("tool_calls")
            finish_reason = choice.get("finish_reason", "unknown")

            # Append assistant message to history
            assistant_msg = {"role": "assistant", "content": content}
            if tool_calls:
                assistant_msg["tool_calls"] = tool_calls
            self.conversation_history.append(assistant_msg)
            messages.append(assistant_msg)

            # If no tool calls, we have a final response
            if not tool_calls:
                # Handle empty response (finish_reason=length with no content)
                if not content and finish_reason == "length":
                    self.conversation_history.pop()
                    messages.pop()
                    messages.append({"role": "user", "content": "Continue your response."})
                    continue
                if not content:
                    content = "[No response generated. Try rephrasing or simplifying your request.]"
                self._save_history()
                return content

            # Dispatch tool calls — parallel when multiple
            had_timeout = False
            if len(tool_calls) > 1:
                import concurrent.futures
                parsed = []
                for tc in tool_calls:
                    fn = tc["function"]["name"]
                    try:
                        a = json.loads(tc["function"]["arguments"])
                    except json.JSONDecodeError:
                        a = {}
                    logger.info(f"Tool call (parallel): {fn}({json.dumps(a, ensure_ascii=False)[:200]})")
                    parsed.append((tc, fn, a))

                results = {}
                def _run_tool(tc_fn_a):
                    tc, fn, a = tc_fn_a
                    return tc["id"], registry.dispatch(fn, a)

                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                    futures = [pool.submit(_run_tool, c) for c in parsed]
                    for fut in concurrent.futures.as_completed(futures):
                        tc_id, result = fut.result()
                        results[tc_id] = result

                for tc, fn, a in parsed:
                    tool_result = results[tc["id"]]
                    result_str = json.dumps(tool_result, ensure_ascii=False) if isinstance(tool_result, dict) else str(tool_result)
                    max_result = 60000 if self.model != "local-model" else 3000
                    if len(result_str) > max_result:
                        result_str = result_str[:max_result] + "\n[truncated]"
                    if "timed out" in result_str:
                        had_timeout = True
                    tool_result_msg = {
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": result_str,
                    }
                    self.conversation_history.append(tool_result_msg)
                    messages.append(tool_result_msg)
            else:
                for tool_call in tool_calls:
                    func_name = tool_call["function"]["name"]
                    try:
                        args = json.loads(tool_call["function"]["arguments"])
                    except json.JSONDecodeError:
                        args = {}
                    logger.info(f"Tool call: {func_name}({json.dumps(args, ensure_ascii=False)[:200]})")
                    tool_result = registry.dispatch(func_name, args)
                    result_str = json.dumps(tool_result, ensure_ascii=False) if isinstance(tool_result, dict) else str(tool_result)
                    max_result = 60000 if self.model != "local-model" else 3000
                    if len(result_str) > max_result:
                        result_str = result_str[:max_result] + "\n[truncated]"
                    if "timed out" in result_str:
                        had_timeout = True
                    tool_result_msg = {
                        "role": "tool",
                        "tool_call_id": tool_call["id"],
                        "content": result_str,
                    }
                    self.conversation_history.append(tool_result_msg)
                    messages.append(tool_result_msg)

            if had_timeout:
                self._save_history()
                return "Code execution timed out. Please try a simpler approach or break the task into smaller steps."

        self._save_history()
        if self._check_interrupt():
            return "[Agent interrupted]"
        return "[Max iterations reached]"

    def run_streaming(self, user_message: str):
        """
        Generator that yields partial results as the agent runs.
        Yields dicts: {"type": "thinking"|"tool_call"|"tool_result"|"text", "content": ...}
        """
        self.interrupt_requested = False
        # Clear any stale interrupt file from previous session/stop
        try:
            os.remove(os.path.join(_get_tmpdir(), "pegasus_interrupt"))
        except OSError:
            pass

        system_prompt = build_system_prompt()

        self.conversation_history.append({
            "role": "user",
            "content": user_message,
        })

        messages = [{"role": "system", "content": system_prompt}] + self.conversation_history
        # Limit tools to reduce prompt size for small on-device models
        tool_schemas = registry.get_tool_schemas()

        iteration = 0
        while iteration < self.max_iterations and not self.interrupt_requested:
            iteration += 1
            if iteration == 1:
                yield {"type": "status", "content": "Sending to model..."}
            else:
                yield {"type": "status", "content": "Analyzing results..."}

            # Trim messages to fit context window
            ctx_limit = MAX_CONTEXT_CHARS_CLOUD if self.model != "local-model" else MAX_CONTEXT_CHARS
            messages = _trim_messages(messages, max_chars=ctx_limit)

            try:
                llm_result = self.client.chat_completions(
                    model=self.model,
                    messages=messages,
                    tools=tool_schemas if tool_schemas else None,
                    temperature=0.6,
                )
            except InterruptedError:
                print("[Agent] Interrupted during LLM call")
                self._save_history()
                yield {"type": "text", "content": "[Stopped]"}
                return
            except Exception as e:
                self._save_history()
                yield {"type": "text", "content": "Error: " + str(e)}
                return

            if self._check_interrupt():
                self._save_history()
                yield {"type": "text", "content": "[Stopped]"}
                return

            choice = llm_result["choices"][0]
            message = choice["message"]
            content = message.get("content") or ""
            tool_calls = message.get("tool_calls")
            finish_reason = choice.get("finish_reason", "unknown")

            print("[Agent] Iteration " + str(iteration) + ": finish_reason=" + str(finish_reason) + ", has_content=" + str(bool(content)) + ", tool_calls=" + str(len(tool_calls) if tool_calls else 0))

            assistant_msg = {"role": "assistant", "content": content}
            if tool_calls:
                assistant_msg["tool_calls"] = tool_calls
            self.conversation_history.append(assistant_msg)
            messages.append(assistant_msg)

            if not tool_calls:
                # Handle empty response (finish_reason=length with no content)
                if not content and finish_reason == "length":
                    print("[Agent] Empty response with finish_reason=length — asking model to continue")
                    # Remove the empty assistant message and ask model to continue
                    self.conversation_history.pop()
                    messages.pop()
                    messages.append({"role": "user", "content": "Continue your response."})
                    continue
                if not content:
                    content = "[No response generated. Try rephrasing or simplifying your request.]"
                print("[Agent] Final response: " + content[:200])
                self._save_history()
                yield {"type": "text", "content": content}
                return

            # Dispatch tool calls — parallel when multiple, sequential when single
            had_timeout = False
            if len(tool_calls) > 1:
                import concurrent.futures
                # Show all tool calls first
                parsed_calls = []
                for tc in tool_calls:
                    fn = tc["function"]["name"]
                    try:
                        a = json.loads(tc["function"]["arguments"])
                    except json.JSONDecodeError:
                        a = {}
                    a_str = json.dumps(a, ensure_ascii=False)
                    print("[Agent] Tool call (parallel): " + fn + "(" + a_str[:200] + ")")
                    yield {"type": "tool_call", "content": fn + "(" + a_str[:100] + ")"}
                    parsed_calls.append((tc, fn, a))

                # Run all tools in parallel
                results = {}
                def _run_tool(tc_fn_args):
                    tc, fn, a = tc_fn_args
                    r = registry.dispatch(fn, a)
                    return tc["id"], r

                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                    futures = [pool.submit(_run_tool, c) for c in parsed_calls]
                    for fut in concurrent.futures.as_completed(futures):
                        tc_id, result = fut.result()
                        results[tc_id] = result

                # Append results in original order
                for tc, fn, a in parsed_calls:
                    tool_result = results[tc["id"]]
                    result_str = json.dumps(tool_result, ensure_ascii=False) if isinstance(tool_result, dict) else str(tool_result)
                    max_result = 60000 if self.model != "local-model" else 3000
                    if len(result_str) > max_result:
                        result_str = result_str[:max_result] + "\n[truncated]"
                    if "timed out" in result_str:
                        had_timeout = True
                    print("[Agent] Tool result: " + result_str[:200])
                    yield {"type": "tool_result", "content": result_str[:500]}
                    tool_result_msg = {
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": result_str,
                    }
                    self.conversation_history.append(tool_result_msg)
                    messages.append(tool_result_msg)
            else:
                # Single tool call — run directly
                for tool_call in tool_calls:
                    func_name = tool_call["function"]["name"]
                    try:
                        args = json.loads(tool_call["function"]["arguments"])
                    except json.JSONDecodeError:
                        args = {}

                    args_str = json.dumps(args, ensure_ascii=False)
                    print("[Agent] Tool call: " + func_name + "(" + args_str[:200] + ")")
                    yield {"type": "tool_call", "content": func_name + "(" + args_str[:100] + ")"}

                    tool_result = registry.dispatch(func_name, args)
                    result_str = json.dumps(tool_result, ensure_ascii=False) if isinstance(tool_result, dict) else str(tool_result)
                    max_result = 60000 if self.model != "local-model" else 3000
                    if len(result_str) > max_result:
                        result_str = result_str[:max_result] + "\n[truncated]"
                    if "timed out" in result_str:
                        had_timeout = True

                    print("[Agent] Tool result: " + result_str[:200])
                    yield {"type": "tool_result", "content": result_str[:500]}

                    tool_result_msg = {
                        "role": "tool",
                        "tool_call_id": tool_call["id"],
                        "content": result_str,
                    }
                    self.conversation_history.append(tool_result_msg)
                    messages.append(tool_result_msg)

            # If any tool timed out, stop the agent loop immediately
            # Swift side detects "timed out" in tool_result and shows its own message
            if had_timeout:
                print("[Agent] Tool execution timed out — aborting to prevent retry loop")
                self._save_history()
                return

        self._save_history()
        yield {"type": "text", "content": "[Max iterations reached]"}
