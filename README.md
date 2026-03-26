# Pegasus

A private AI agent for iOS. Full tool execution, persistent memory, voice I/O, OCR vision, RAG knowledge base, shell access, and iOS device control. Best with GPT-5.4 cloud inference. On-device mode via llama.cpp + Metal GPU available with reduced capability.

---

## Table of Contents

- [Inspiration & Acknowledgments](#inspiration--acknowledgments)
- [Architecture](#architecture)
- [How It Works](#how-it-works)
- [Features](#features)
  - [Agent Core](#agent-core)
  - [40+ Built-in Tools](#40-built-in-tools)
  - [Memory System](#memory-system)
  - [Skill System](#skill-system)
  - [Cron Scheduler](#cron-scheduler)
  - [Voice Pipeline](#voice-pipeline)
  - [RAG (Document Q&A)](#rag-document-qa)
  - [iOS Device Control](#ios-device-control)
  - [Sensors & Location](#sensors--location)
  - [Security & Privacy](#security--privacy)
  - [Custom Packages](#custom-packages)
  - [Background Tasks](#background-tasks)
- [Cloud Mode (GPT-5.4)](#cloud-mode-gpt-54)
- [Local Mode (llama.cpp)](#local-mode-llamacpp)
- [User Interface](#user-interface)
- [Siri, Shortcuts & Action Button](#siri-shortcuts--action-button)
- [Known Shortcomings](#known-shortcomings)
- [Sideloading via Developer Mode](#sideloading-via-developer-mode)
- [Project Structure](#project-structure)
- [License](#license)

---

## Inspiration & Acknowledgments

Pegasus owes its existence to [Nous Research](https://nousresearch.com/) and the **Hermes Agent** architecture. We didn't just take inspiration — we studied it, ported it, and rebuilt it for a platform nobody expected: an iPhone.

### What We Took from Hermes

The Hermes Agent framework established a clean, powerful pattern for building tool-calling AI agents:

- **Tool Registry Pattern** — Tools self-register at import time by calling `registry.register()`. The agent loop discovers tools via `get_tool_schemas()` and dispatches via `dispatch()`. This is directly ported from Hermes into our `tool_registry.py`.
- **Iterative Tool-Calling Loop** — The core agent loop sends messages to the LLM with tool schemas, parses `tool_calls` from the response, dispatches tools, appends results, and loops until the LLM produces a final text answer. Our `agent_runner.py` follows this exact pattern.
- **Multi-Layered System Prompt** — Hermes assembles the system prompt from composable layers: identity, capabilities, memory state, and skills index. Our `prompt_builder.py` replicates this with five layers:
  1. **Identity** — loaded from `SOUL.md` (customizable personality)
  2. **Capability guidance** — tool routing rules and usage patterns
  3. **Memory snapshot** — frozen at turn start from `MEMORY.md` and `USER.md`
  4. **Skills index** — available agent-created workflows
  5. **Custom packages** — agent-created Python libraries
- **Persistent Memory** — Bounded file-backed memory with add/replace/remove operations, using section delimiters. Two stores: agent observations and user profile. Ported from Hermes's memory system.
- **Skill System** — Skills stored as markdown files with frontmatter metadata. The agent can create, list, view, and delete skills. Each skill is a reusable workflow defined in `SKILL.md`. Directly inspired by Hermes.

### Where We Diverge

Hermes runs on servers with full network access, subprocess, and heavyweight Python environments. Pegasus runs inside an iOS app sandbox:

- **No sockets** — iOS blocks raw socket creation on unjailbroken devices. All inter-process communication is file-based: Python writes JSON to a temp file, Swift polls and picks it up.
- **No subprocess** — Shell commands are emulated in pure Python. We reimplemented 70+ Unix commands (ls, grep, find, sed, awk, curl, wget, tar, zip, sort, uniq, cut, wc, diff, paste, column, and more) entirely in Python.
- **Embedded runtime** — Python runs inside the app process via Python.xcframework and the C API (`Py_Initialize`, `PyRun_SimpleString`). There's no separate Python process.
- **Dual inference** — Hermes talks to an API server. Pegasus can use either a cloud API (OpenAI) or run inference directly on the device's Neural Engine + GPU via llama.cpp with Metal.

We have deep respect for Nous Research's work on open-weight models and agent frameworks. Hermes proved that capable tool-calling agents don't need massive infrastructure — Pegasus takes that philosophy to its logical extreme: a full agent stack running on the computer in your pocket.

### Credits

- [Nous Research](https://nousresearch.com/) — Hermes Agent architecture, open-weight model research, and the vision that inspired this project
- [llama.cpp](https://github.com/ggerganov/llama.cpp) — The foundation for on-device LLM inference with Metal GPU acceleration
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — On-device speech recognition that runs entirely offline
- [beeware/Python-Apple-support](https://github.com/beeware/Python-Apple-support) — Python.xcframework that makes embedded Python on iOS possible

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      SwiftUI Frontend                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐│
│  │ ChatView │ │FilesView │ │ModelsView│ │SettingsView      ││
│  │ streaming│ │ SOUL.md  │ │cloud/    │ │skills, memory,   ││
│  │ tool vis │ │ MEMORY   │ │local     │ │packages, voice   ││
│  │ voice UI │ │workspace │ │settings  │ │shortcuts, reset  ││
│  └────┬─────┘ └──────────┘ └──────────┘ └──────────────────┘│
│       │                                                       │
│  ┌────▼──────────────────────────────────────────────────┐   │
│  │              BackendService (Router)                   │   │
│  │  Cloud mode → OpenAI API (Responses API for GPT-5.x)  │   │
│  │  Local mode → llama.cpp inference on-device            │   │
│  │  Both modes → Full agent toolchain via EmbeddedPython  │   │
│  └────┬──────────────────────────────────────────────────┘   │
│       │                                                       │
│  ┌────▼──────────────┐        ┌──────────────────────────┐   │
│  │  EmbeddedPython   │◄──────►│    LocalLLMEngine        │   │
│  │                   │  file  │                          │   │
│  │  Python.xcframework│  IPC  │  llama.cpp C API         │   │
│  │  C API bridge     │ (JSON) │  Metal GPU offload       │   │
│  │  GIL management   │        │  GGUF model loading      │   │
│  │  stdout redirect  │        │  Streaming generation    │   │
│  └────┬──────────────┘        └──────────────────────────┘   │
│       │                                                       │
│  ┌────▼──────────────────────────────────────────────────┐   │
│  │          Python Agent (hermes_bridge)                  │   │
│  │                                                        │   │
│  │  AgentRunner ─── core loop (up to 100 iterations)     │   │
│  │       │                                                │   │
│  │  ToolRegistry ── 40+ tools, self-registering          │   │
│  │       │                                                │   │
│  │  PromptBuilder ─ 5-layer system prompt assembly       │   │
│  │       │                                                │   │
│  │  MemoryManager ─ MEMORY.md + USER.md persistence      │   │
│  │       │                                                │   │
│  │  SkillManager ── reusable workflows (SKILL.md)        │   │
│  │       │                                                │   │
│  │  CronManager ─── scheduled background jobs            │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐   │
│  │               iOS Framework Integration               │   │
│  │  WhisperEngine (STT) │ AVSpeechSynthesizer (TTS)      │   │
│  │  VisionKit (OCR)     │ NLEmbedding (vectors)          │   │
│  │  CoreMotion (sensors)│ CoreLocation (GPS)              │   │
│  │  EventKit (calendar) │ Contacts                        │   │
│  │  HealthKit (fitness) │ CryptoKit (AES-GCM)            │   │
│  │  LocalAuthentication │ AVAudioEngine (keep-alive)      │   │
│  └───────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

**File-Based IPC** — Python sockets do not work on unjailbroken iOS. Instead of HTTP servers or TCP ports, all communication between Swift and the embedded Python runtime happens through JSON files in the app's temp directory:
- Python writes an LLM request file → Swift's `checkForLLMRequest()` watcher picks it up → runs inference (local or cloud) → writes a response file → Python reads it and continues
- Streaming events use JSONL files polled by a Swift timer
- iOS actions (contacts, calendar, TTS, etc.) use a similar request/response file pair

**GIL Management** — The Python GIL is released after initialization (`PyEval_SaveThread`) and re-acquired around each `PyRun_SimpleString` call (`PyGILState_Ensure`/`Release`). This prevents the Python runtime from blocking the main thread.

**Serial Python Queue** — All Python execution goes through a single serial `DispatchQueue`. This prevents concurrent access to the Python interpreter but means a stuck operation blocks everything. The interrupt mechanism (writing a file that Python polls) provides an escape hatch.

**Atomic File Writes** — All IPC files are written atomically (write to `.tmp`, `fsync`, then `os.rename`) to prevent partial reads that cause JSON parse failures.

**Background Keep-Alive** — A silent `AVAudioEngine` session keeps the app alive in the background using the `audio` background mode. This allows cron jobs and long-running tasks to continue when the app is backgrounded.

---

## How It Works

### The Agent Loop

When you send a message, here's what happens:

1. **Swift** receives your text in `ChatView` and calls `BackendService.runAgentStreaming()`
2. **EmbeddedPython** queues the work on the serial `pythonQueue`, calling `AgentRunner.run_streaming()` via `PyRun_SimpleString`
3. **AgentRunner** builds the conversation with `PromptBuilder.build_system_prompt()` (identity + capabilities + memory snapshot + skills + packages)
4. **AgentRunner** writes an LLM request file (messages + tool schemas) and polls for the response
5. **Swift** detects the request file via a repeating timer, reads it, and either:
   - **Cloud mode**: Sends it to OpenAI's Responses API (for GPT-5.x with reasoning) or Chat Completions API
   - **Local mode**: Feeds it to `LocalLLMEngine` which runs llama.cpp inference with Metal GPU
6. **Swift** writes the response file; Python reads it
7. If the response contains `tool_calls`, **AgentRunner** dispatches each tool through the `ToolRegistry`, appends results, and loops back to step 4
8. If the response is plain text, **AgentRunner** writes it to the stream file
9. **Swift** polls the stream file and updates `ChatView` in real-time
10. This loop repeats for up to **100 iterations** per task

### Interrupt Mechanism

If you tap "Stop" or send a new message while the agent is working:

1. Swift writes a `pegasus_interrupt` file to the temp directory
2. Swift also writes a fake LLM response to unblock Python if it's polling
3. Python's agent loop checks for the interrupt file every 2 seconds
4. `python_exec` also polls for interrupts, allowing cancellation of stuck code execution
5. The old agent task is auto-superseded when a new message arrives

---

## Features

### Agent Core

The agent runs a full tool-calling loop inspired by the Hermes architecture:

- **Up to 100 iterations per task** — complex multi-step reasoning with tool calling
- **Batch tool calls** — when the LLM requests multiple independent tools, they can execute in a single turn
- **Automatic context management** — conversation history is trimmed when it approaches limits:
  - Cloud mode: 200,000 character limit
  - Local mode: 12,000 character limit
- **Auto-continuation** — if the model hits its output token limit mid-response, the agent automatically sends "Continue your response" to get the rest
- **Conversation persistence** — chat history and agent conversation state are saved to disk and restored across app launches
- **Mistake learning** — the agent is instructed to immediately save mistakes and corrections to persistent memory so the same error never happens twice

### 40+ Built-in Tools

Every tool self-registers with the `ToolRegistry` at import time and is available to the LLM via OpenAI-format function calling schemas.

#### File System
| Tool | Description |
|------|-------------|
| `file_read` | Read files from the workspace. Paths relative to workspace root. |
| `file_write` | Write content to workspace files. Creates directories as needed. |
| `file_list` | List files and directories in the workspace with sizes. |

#### Shell Emulation
| Tool | Description |
|------|-------------|
| `shell_exec` | Execute shell commands in pure Python. Supports 70+ commands. |

The shell emulation layer is one of Pegasus's most ambitious features. Since iOS doesn't allow `subprocess`, every command is reimplemented in Python:

**File operations**: `ls` (with `-l`, `-a`, `-R`, `-S`, `-t`, `-h`), `cat`, `head`, `tail`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `chmod`, `ln`, `readlink`, `realpath`, `basename`, `dirname`, `stat`, `file`, `tree`

**Text processing**: `grep` (with `-i`, `-r`, `-n`, `-c`, `-v`, `-l`, `-w`, `-E`), `sed` (with `-i`, `-n`, regex substitution, delete, print), `awk` (field extraction, patterns, NR/NF variables), `cut`, `tr`, `sort` (with `-r`, `-n`, `-u`, `-k`, `-t`), `uniq` (with `-c`, `-d`, `-u`), `wc`, `tee`, `rev`, `fold`, `expand`, `unexpand`, `paste`, `column`

**Search**: `find` (with `-name`, `-type`, `-size`, `-mtime`, `-maxdepth`), `which`, `type`, `locate`

**Archives**: `tar` (create/extract/list, gzip support), `zip`/`unzip`, `gzip`/`gunzip`

**Network**: `curl` (GET/POST, headers, data), `wget` (download files)

**Data**: `diff` (unified and ndiff), `md5sum`/`sha256sum`, `base64`, `xxd`, `od`

**System**: `echo`, `printf`, `date`, `cal`, `env`, `export`, `pwd`, `cd`, `sleep`, `true`, `false`, `yes`, `seq`, `xargs`

**Python**: `python`/`python3` (inline execution), `pip install`

All commands support **pipes** (`|`), **chains** (`&&`, `;`), and **redirects** (`>`, `>>`).

#### Code Execution
| Tool | Description |
|------|-------------|
| `python_exec` | Execute Python code with persistent namespace. Set `result` to return values. Imports persist between calls. |
| `pip_install` | Install pure-Python packages from PyPI directly on iOS. Downloads and extracts wheels without pip or subprocess. |
| `create_package` | Create a reusable Python package that persists across sessions. Immediately importable via `import name`. |
| `list_custom_packages` | List all custom packages with name, type, and description. |
| `delete_custom_package` | Delete a custom package. |

`python_exec` runs in a separate thread with configurable timeout:
- **Cloud mode**: 1 hour timeout, 100K character output capture
- **Local mode**: 5 minute timeout, 5K character output capture
- Polls every 2 seconds for interrupt signals so users can cancel stuck executions

#### Web
| Tool | Description |
|------|-------------|
| `web_search` | Search the web via DuckDuckGo. Returns titles, URLs, and snippets. |
| `web_fetch` | Fetch and clean web page content. Uses lxml for HTML parsing when available, regex fallback otherwise. Strips scripts, styles, nav, footers. |

Web fetching uses `urllib.request` with a permissive SSL context (iOS embedded Python has no CA bundle). HTML is cleaned with lxml's tree parser for high-quality text extraction, falling back to regex-based stripping.

#### Data
| Tool | Description |
|------|-------------|
| `excel_read` | Read Excel files efficiently using openpyxl. Handles 30MB+ files. Specify sheet name and cell range. |
| `scan_qr` | Read QR codes and barcodes from images via iOS Vision framework. Supports QR, EAN, UPC, Code128, and more. |

Excel output caps:
- Cloud mode: 50K characters
- Local mode: 5K characters

#### Voice
| Tool | Description |
|------|-------------|
| `speak` | Text-to-speech via iOS AVSpeechSynthesizer. Multiple languages, adjustable rate (0.0–1.0). |
| `stop_speaking` | Stop any ongoing TTS output. |
| `voice_record` | Record audio from the microphone. `action='start'` to begin, `'stop'` to end. |
| `transcribe` | Speech-to-text via whisper.cpp. Works offline, supports 99 languages. |

#### Vision
| Tool | Description |
|------|-------------|
| `ocr_image` | Extract text from images using on-device VisionKit OCR. Works with photos, screenshots, documents, receipts, whiteboards. |

#### Translation
| Tool | Description |
|------|-------------|
| `translate` | On-device translation via Apple Translation framework. 20+ languages. Works offline. |

#### Security
| Tool | Description |
|------|-------------|
| `authenticate` | Face ID / Touch ID verification via LocalAuthentication. Gate sensitive operations. |
| `encrypt` | AES-GCM encryption with password. Returns base64-encoded ciphertext. |
| `decrypt` | Decrypt AES-GCM ciphertext with the original password. |

#### iOS Device Control
| Tool | Description |
|------|-------------|
| `ios_action` | Access iOS native APIs (see detailed list below). |
| `create_event` | Create calendar events with title, start/end times, location, notes. Supports timed and all-day events. |
| `create_contact` | Add contacts with name, phone, email. |
| `complete_reminder` | Mark a reminder as completed by title. |

#### Sensors
| Tool | Description |
|------|-------------|
| `get_motion` | Device motion data: pitch, roll, yaw, acceleration vectors. |
| `get_steps` | Pedometer: step count, distance, floors climbed for last N days. |
| `get_activity` | Current activity: walking, running, driving, stationary, cycling. |
| `get_location` | GPS: latitude, longitude, altitude, accuracy. |

#### Memory & Skills
| Tool | Description |
|------|-------------|
| `memory_read` | Read persistent memory. `target='memory'` for agent notes, `'user'` for user profile. |
| `memory_write` | Write to persistent memory with smart routing. |
| `skills_list` | List all available skills with names and descriptions. |
| `skill_view` | View a skill's SKILL.md content. |
| `skill_create` | Create a new reusable skill as markdown instructions. |
| `skill_delete` | Permanently delete a skill. |

#### Cron
| Tool | Description |
|------|-------------|
| `cron_create` | Schedule recurring tasks. Supports `"shell"` and `"agent"` job types with intervals like `5m`, `2h`, `1d`. |
| `cron_list` | List all scheduled jobs with status and last run time. |
| `cron_delete` | Delete a scheduled job. |
| `cron_toggle` | Enable or disable a job. |
| `cron_logs` | View last N run logs with full agent responses. |

#### Background Tasks
| Tool | Description |
|------|-------------|
| `task_run` | Start a long-running operation in a background thread. Returns a task ID. |
| `task_status` | Check task status and retrieve results. |
| `task_cancel` | Cancel a running background task. |

---

### Memory System

Pegasus maintains two persistent memory stores, ported from the Hermes Agent pattern:

**MEMORY.md** — Agent observations, learned patterns, environment details, mistakes and fixes, task notes, saved information. This is the agent's scratchpad that persists across conversations.

**USER.md** — User identity information: name, job, contact info, personal preferences, communication style. Only genuine identity signals are routed here.

Limits scale with inference mode:

| Store | Local | Cloud |
|-------|-------|-------|
| **MEMORY.md** | 2,200 chars | 20,000 chars |
| **USER.md** | 1,375 chars | 10,000 chars |
| **SOUL.md** | 5,000 chars | 20,000 chars |

Memory operations:
- **Add**: Append a new entry. Duplicate entries are automatically rejected.
- **Replace**: Find and replace content within a memory file.
- **Remove**: Delete an entry and clean up delimiters.
- **Auto-truncation**: When a file exceeds its limit, the oldest entries are truncated from the beginning, keeping newest information.

The agent has a built-in directive: when it makes a mistake, gets corrected, or encounters a failure, it immediately saves a `MISTAKE: ... | FIX: ...` entry to memory so the same error never repeats.

Smart routing logic in `memory_write` detects genuine identity signals ("my name is", "I work at", "I prefer") to route to USER.md — everything else goes to MEMORY.md by default.

---

### Skill System

Skills are reusable agent workflows stored as markdown files with optional YAML-like frontmatter:

```markdown
---
name: data-analysis
description: Analyze CSV data and produce summary statistics
category: data
---

# Data Analysis Workflow

1. Read the CSV file with file_read or python_exec
2. Load into a data structure
3. Compute summary statistics
...
```

Skills are stored in `~/Documents/pegasus_data/skills/<skill-name>/SKILL.md`. The agent can:
- Create skills from conversations ("save this as a skill")
- List and view existing skills
- Delete skills no longer needed
- Skills appear in the system prompt so the agent knows what workflows are available

A default **context-optimizer** skill is included for intelligent context window management during long conversations.

---

### Cron Scheduler

The cron system runs a background thread that checks job schedules every 30 seconds:

- **Shell jobs**: Execute a shell command on schedule
- **Agent jobs**: Send a prompt through the full agent loop (with all tools, memory, and context)
- Jobs persist to `pegasus_workspace/.pegasus_cron.json`
- Logs are saved per-job in `.cron_logs/` with timestamps and full output
- Jobs can be enabled/disabled without deletion
- The CronView in the UI shows job status, next run time, and logs

Example: `cron_create(name="news-digest", type="agent", prompt="Search for today's top tech news and save a summary to a file", interval="6h")`

---

### Voice Pipeline

End-to-end voice interaction:

1. **Mic input** → `VoiceRecorder` (AVAudioRecorder) captures audio
2. **Speech-to-text** → `WhisperEngine` (whisper.cpp, runs offline, 99 languages) transcribes
3. **Agent processing** → Transcribed text goes through the full agent loop
4. **Text-to-speech** → `AVSpeechSynthesizer` reads the response aloud

The voice UI includes:
- Mic button in ChatView with recording indicator
- Whisper model auto-loads the bundled `ggml-tiny.bin` on app launch
- Shortcuts integration for hands-free voice interaction via Siri or Action Button

---

### RAG (Document Q&A)

Semantic search over documents using Apple's NLEmbedding framework:

1. **Index**: `rag_index(source='document_name', content='...')` splits text into chunks and generates embeddings via iOS NLEmbedding (zero external dependencies)
2. **Search**: `rag_search(query='what is the revenue?')` computes query embedding, performs cosine similarity search, returns top-k relevant chunks
3. **Answer**: Agent uses retrieved context to answer questions accurately

The vector store uses SQLite for persistence. All embedding computation happens on-device — no API calls needed.

---

### iOS Device Control

The `ios_action` tool provides access to native iOS APIs through the file-based IPC bridge:

| Action | Description |
|--------|-------------|
| `send_message` | Send an iMessage/SMS to a contact |
| `make_call` | Initiate a phone call |
| `read_contacts` | Search and read contacts |
| `read_calendar` | View calendar events |
| `read_reminders` | View reminders |
| `open_url` | Open a URL in Safari |
| `notify` | Show a local notification |
| `clipboard` | Read or write the clipboard |
| `haptic` | Trigger haptic feedback (light, medium, heavy, success, warning, error) |
| `get_battery` | Get battery level and charging state |
| `get_device_info` | Device model, OS version, storage, etc. |
| `set_alarm` | Create an alarm (opens Clock app) |
| `flashlight` | Toggle flashlight on/off |

Each iOS action works through the same file-based IPC: Python writes a request JSON → Swift picks it up on the main thread (required for UIKit/system APIs) → executes → writes response → Python reads result.

---

### Sensors & Location

| Sensor | Framework | Details |
|--------|-----------|---------|
| Motion | CoreMotion | Pitch, roll, yaw, user acceleration, gravity vectors. No permission prompt. |
| Pedometer | CoreMotion | Steps, distance (m), floors climbed/descended. Configurable lookback (days). |
| Activity | CoreMotion | Real-time: walking, running, driving, cycling, stationary. Confidence level. |
| Location | CoreLocation | Latitude, longitude, altitude, horizontal/vertical accuracy. Prompts for permission on first use. |

---

### Security & Privacy

- **Face ID gating** — Use `authenticate(reason='...')` to require biometric verification before sensitive operations
- **AES-GCM encryption** — `encrypt(text, password)` / `decrypt(ciphertext, password)` for securing sensitive data in memory or files
- **On-device processing** — All tool execution, OCR, speech recognition, translation, and embedding computation happen on-device
- **No telemetry** — Pegasus sends no analytics, no usage data, nothing to any server except the OpenAI API when in cloud mode (and only the conversation messages + tool calls)
- **Sandbox isolation** — All file operations are sandboxed to `~/Documents/pegasus_workspace/` and `~/Documents/pegasus_data/`

---

### Custom Packages

The agent can create persistent Python packages that survive across sessions:

```python
# Agent calls create_package(name="stats_utils", code="...", description="Statistical helpers")
# Immediately importable in any future python_exec call:
import stats_utils
```

Packages are stored in `~/Documents/pegasus_data/custom_packages/` and automatically added to `sys.path`. The system prompt includes an index of available custom packages so the agent knows what it has built.

---

### Background Tasks

For long-running operations that shouldn't block the chat:

```
task_run(type="python", code="<long analysis>")
→ Returns task_id: "abc123"

task_status(task_id="abc123")
→ {"status": "running", "output": "Processing row 5000..."}

task_status(task_id="abc123")
→ {"status": "done", "output": "Analysis complete. Results saved to output.csv"}
```

Background task output limits:
- Cloud mode: 50K characters
- Local mode: 10K characters

---

## Cloud Mode (GPT-5.4)

Cloud mode connects to OpenAI's API for inference while keeping all tool execution local:

| Setting | Value |
|---------|-------|
| **Supported models** | GPT-5.4, GPT-5.4 mini, GPT-5.2, GPT-4o |
| **API** | Responses API (`/v1/responses`) for GPT-5.x with reasoning; Chat Completions for `reasoning_effort=none` |
| **Reasoning effort** | none, low, medium, high, xhigh (configurable in Settings) |
| **Max output tokens** | Up to 128K (configurable: 4K, 8K, 16K, 32K, 64K, 128K presets) |
| **Context window** | 272K tokens (GPT-5.4) |
| **Request timeout** | 10 minutes (URLRequest + semaphore) |
| **Tool result size** | Up to 60K characters per tool result |
| **Output capture** | Up to 100K characters from python_exec |
| **Agent iterations** | Up to 100 per task |
| **Polling timeout** | 30 minutes for LLM response |

When `reasoning_effort` is set to anything other than "none" with a GPT-5.x model, Pegasus automatically uses the OpenAI Responses API, which supports reasoning + function calling together. It handles the full format conversion (messages → Responses API input, output → Chat Completions format for Python compatibility).

### Responses API Format Conversion

The Responses API uses a different message format than Chat Completions:
- `system` → `developer` role
- `tool` results → `function_call_output` items
- `tool_calls` → `function_call` output items
- Response `function_call` items → `tool_calls` format

Pegasus handles this conversion transparently in `EmbeddedPython.swift` via `buildResponsesAPIBody()` and `convertResponsesAPIToChatCompletions()`.

---

## Local Mode (llama.cpp)

On-device inference using llama.cpp with full Metal GPU acceleration:

| Setting | Value |
|---------|-------|
| **Framework** | llama.cpp via llama.xcframework |
| **GPU** | Full Metal offload (all layers on GPU) |
| **CPU** | All available cores |
| **Batch size** | 512 |
| **Default context** | 8,192 tokens (configurable up to 128K) |
| **Flash attention** | Auto-enabled when supported |
| **Model format** | GGUF (Q4, Q5, Q6, Q8, etc.) |
| **Sampling** | penalties(1.1) → DRY(0.8) → min_p(0.05) → temp(0.6) → dist |
| **Special tokens** | ChatML format with `parse_special=true` |
| **Inference timeout** | 10 minutes per generation |

### Optimized for iPhone 16 Pro (A18 Pro)

The inference engine is tuned for Apple's latest silicon:
- All CPU performance cores utilized
- Full GPU offload via Metal — no CPU fallback for matrix operations
- Aggressive batch size (512) for maximum throughput
- Flash attention for memory-efficient long contexts

### Model Management

- Models stored in `~/Documents/models/`
- Import `.gguf` files via the Files app or in-app file importer
- Model info displayed: name, size, parameter count
- Load/unload models dynamically without restarting the app
- Memory pressure handling: auto-unloads model on iOS memory warnings

---

## User Interface

### Mac OS X Leopard Theme

Pegasus uses a custom UI theme inspired by Mac OS X Leopard (2007):

- **Brushed metal gradients** — toolbar and header backgrounds use multi-stop linear gradients mimicking Apple's brushed metal aesthetic
- **Aqua buttons** — glossy buttons with highlight overlays and shadow, inspired by the original Aqua interface
- **Pinstripe backgrounds** — subtle alternating row stripes in lists
- **Color palette**: toolbar grey (#B0B8C2), aqua blue (#3366D9), selection blue (#4080F2), silver bubbles (#E0E3E8)
- **Message bubbles** — user messages in aqua blue, agent responses in silver, tool results in system grey

### Views

| View | Purpose |
|------|---------|
| **ChatView** | Dual-panel chat with Cloud/Local toggle. Both panels stay alive with separate chat histories. Streaming responses, tool call visualization, voice recording UI, file sharing, stop button. Mode toggle automatically sets cloud/local inference for each message. |
| **FilesView** | Edit SOUL.md (personality), MEMORY.md (agent notes), USER.md (user profile). Upload files to workspace. Browse, share, and delete workspace files. |
| **ModelsView** | Cloud/local toggle, OpenAI API key entry with connection test, model picker (GPT-5.4/5.4 mini/5.2/4o), reasoning effort selector, max output tokens, context window slider, local GGUF model list with load/unload, model import |
| **SettingsView** | Status display, Siri/Shortcuts setup guide, SOUL editor, memory viewer, skills browser with import/delete, custom packages browser, remote backend host, danger zone (reset all data) |
| **CronView** | Scheduled job list with status indicators, last run time, next run time, output preview, log viewer, clear button |

---

## Siri, Shortcuts & Action Button

### App Intents

Two App Intents are registered for Shortcuts and Siri. **Voice is the default** — it's listed first in the shortcuts provider so it appears as the primary Action Button option:

**PegasusVoiceIntent** — "Talk to Pegasus" (default)
- Opens app and immediately starts voice recording
- Siri phrases: "Talk to Pegasus", "Pegasus voice", "Pegasus listen", "Pegasus"
- Recommended for Action Button

**AskPegasusIntent** — "Ask Pegasus"
- Optional `question` parameter
- If no question provided, opens in voice mode
- Siri phrases: "Ask Pegasus", "Hey Pegasus"

### Action Button Setup

1. Go to **Settings → Action Button** on iPhone 15 Pro/16 Pro
2. Select **Shortcut**
3. Choose **"Talk to Pegasus"** (voice, recommended) or "Ask Pegasus" (text)
4. Press the Action Button to invoke Pegasus instantly

### URL Schemes

- `pegasus://voice` — Open app and start voice recording
- `pegasus://ask?q=your+question` — Open app and send a query

### Background Modes

Pegasus registers three background modes:
- `audio` — Silent audio session for keep-alive
- `fetch` — Background app refresh (every 60s)
- `processing` — Background processing tasks (every 120s)

---

## Known Shortcomings

### Local Model Limitations
On-device GGUF models (2B-8B parameters that fit in iPhone memory) have significantly reduced capability compared to GPT-5.4. They struggle with:
- Complex multi-step tool calling chains
- Correctly formatting tool call JSON with multiple arguments
- Following nuanced system prompt instructions
- Maintaining coherence over long conversations

Cloud mode with GPT-5.4 is recommended for any serious task. Local mode is best for simple Q&A, quick calculations, and offline use.

### No Real Subprocess
Shell commands are emulated in pure Python. While 70+ commands are supported with most common flags, edge cases differ from real Unix:
- No process management (ps, kill, top)
- No real file permissions (chmod is a no-op)
- Pipe and redirect behavior is approximated, not exact
- `curl` and `wget` use `urllib.request` under the hood

### Python Socket Restrictions
iOS sandbox blocks raw socket creation on unjailbroken devices. This means:
- `urllib.request` works (it uses the system's URL loading)
- No HTTP servers can be started
- No TCP/UDP listeners
- No WebSocket connections from Python
- All networking must go through `urllib.request` or the iOS action bridge

### Single-Threaded Python
The embedded Python runtime runs on a serial DispatchQueue. Heavy `python_exec` tasks block other agent operations until they complete. The interrupt mechanism (2-second polling) provides cancellation, but the thread cannot be forcefully killed — it runs as a daemon thread that may leak if stuck.

### Package Limitations
`pip_install` downloads and extracts wheel files but cannot:
- Compile C extensions (no compiler on iOS)
- Install packages with native dependencies (numpy requires pre-compilation)
- Handle complex dependency trees reliably

Packages with native code (lxml, openpyxl, numpy, pandas) must be cross-compiled for iOS arm64 and bundled at build time.

### Re-Signing Requirement
Free Apple Developer accounts require re-signing the app every 7 days. The app will stop launching after 7 days unless re-deployed from Xcode. A paid developer account ($99/year) removes this limitation.

### No App Store Distribution
Pegasus uses private APIs (background audio keep-alive, unrestricted file access, embedded Python runtime) that would not pass App Store review. It must be sideloaded.

### Memory Pressure
Loading large GGUF models (4GB+) alongside the Python runtime, whisper model, and iOS frameworks can trigger memory warnings on devices with 6GB RAM. The app auto-unloads models on memory pressure, but this interrupts any in-progress generation.

### Whisper Framework
The whisper.xcframework must be built separately using `build_whisper.sh`. The pre-built framework is not included in the repository due to its size. Without it, voice transcription is unavailable.

---

## Sideloading via Developer Mode

Pegasus is a sideloaded app — it runs outside the App Store using Xcode and a developer certificate.

### Prerequisites

| Requirement | Details |
|-------------|---------|
| **Mac** | macOS 14+ with Xcode 15+ installed |
| **iPhone** | iOS 17.0+ (iPhone 15 Pro / 16 series recommended for performance) |
| **Apple Developer Account** | Free works (7-day re-signing) or paid $99/year (no expiration) |
| **Connection** | USB cable or same Wi-Fi network for wireless deployment |

### Step 1: Enable Developer Mode on iPhone

Developer Mode must be enabled before Xcode can install apps:

1. Connect your iPhone to your Mac via USB (Xcode needs to detect it once)
2. On iPhone: **Settings → Privacy & Security → Developer Mode**
3. Toggle **Developer Mode ON**
4. iPhone will prompt to restart — tap **Restart**
5. After reboot, you'll see a confirmation dialog — tap **Turn On**
6. Enter your passcode when prompted

> If you don't see Developer Mode in Settings, connect the iPhone to a Mac with Xcode installed. It appears after the device is recognized by Xcode.

### Step 2: Clone and Set Up

```bash
# Clone the repository
git clone https://github.com/phoenixstrategyresearch/pegasus.git
cd pegasus

# Run the setup script (creates directories, checks dependencies)
./scripts/setup.sh
```

### Step 3: Build Dependencies

```bash
# Build or download Python.xcframework (if not included)
./setup_python.sh

# Build whisper.xcframework (optional — needed for voice input)
./build_whisper.sh

# Build lxml for iOS (optional — improves web scraping quality)
cd build_ios_deps && ./build_lxml.sh && cd ..
```

### Step 4: Generate Xcode Project

```bash
# Install xcodegen if you don't have it
brew install xcodegen

# Generate the Xcode project from project.yml
xcodegen generate
```

### Step 5: Configure and Build in Xcode

1. Open `Pegasus.xcodeproj` in Xcode
2. Select the **Pegasus** target
3. Under **Signing & Capabilities**:
   - Select your **Team** (your Apple Developer account)
   - Change the **Bundle Identifier** if needed (e.g., `com.yourname.pegasus`)
   - Xcode will create a provisioning profile automatically
4. Select your connected iPhone as the **build destination** (top toolbar)
5. Press **Cmd+R** to build and run

### Step 6: Trust the Developer Certificate

On first install, iOS needs to trust your developer certificate:

1. On iPhone: **Settings → General → VPN & Device Management**
2. Under "Developer App", tap your developer certificate
3. Tap **Trust** and confirm

The app will now launch normally.

### Step 7: Download a Model (for local inference)

```bash
# Example: Qwen3.5 2B quantized (good balance of speed and quality)
huggingface-cli download unsloth/Qwen3.5-2B-GGUF \
  Qwen3.5-2B-UD-Q8_K_XL.gguf \
  --local-dir ~/Documents/models

# Transfer to device via Xcode:
# Window → Devices and Simulators → select device → Pegasus → + (add files)
# Or use the in-app file importer (Models → Import GGUF Model)
```

### Step 8: Configure Cloud Mode (recommended)

For the best experience with full tool-calling capability:

1. Open Pegasus on your iPhone
2. Go to **Models** tab
3. Toggle **Cloud LLM** on
4. Enter your **OpenAI API key** (`sk-proj-...`)
5. Tap **Test** to verify the connection
6. Select **GPT-5.4** as the model
7. Optionally adjust reasoning effort and max output tokens

### Troubleshooting

| Issue | Solution |
|-------|----------|
| "Untrusted Developer" | Settings → General → VPN & Device Management → Trust |
| App won't install | Check Bundle ID is unique, ensure Developer Mode is on |
| Build errors about frameworks | Run `./setup_python.sh` and `xcodegen generate` again |
| App crashes on launch | Check Xcode console for logs. Common: missing model file, memory pressure |
| Model won't load | Ensure .gguf file is in the app's Documents/models/ directory |
| Agent not responding | Check Models tab — ensure cloud mode is online or a local model is loaded |
| Voice not working | Whisper model must be built and bundled. Check Settings → Voice status |
| App stops working after 7 days | Re-deploy from Xcode (free account limitation). Get a paid account to avoid this. |
| "Could not launch" error | Device may be locked. Unlock iPhone and try again. |
| Code signing errors | Ensure your Team is selected and Bundle ID doesn't conflict with another app |

---

## Project Structure

```
pegasus/
├── README.md                       # This file
├── .gitignore                      # Git ignore rules
├── project.yml                     # XcodeGen project configuration
│
├── Pegasus/                        # iOS app (Swift)
│   ├── App/
│   │   ├── PegasusApp.swift        # App entry point, background tasks, deep links, keep-alive
│   │   ├── ContentView.swift       # Tab bar (Chat, Files, Models, Cron, Settings)
│   │   └── PegasusIntents.swift    # App Intents for Shortcuts/Siri/Action Button
│   │
│   ├── Services/
│   │   ├── BackendService.swift    # Router: cloud API ↔ embedded agent ↔ local inference
│   │   ├── EmbeddedPython.swift    # Python runtime, file-based IPC, LLM request watcher,
│   │   │                          # OpenAI API calls, iOS action handler, GIL management
│   │   ├── LocalLLMEngine.swift    # llama.cpp inference engine (Metal GPU, streaming, sampling)
│   │   ├── LocalOpenAIServer.swift # OpenAI-compatible wrapper around LocalLLMEngine
│   │   ├── WhisperEngine.swift     # whisper.cpp speech-to-text engine
│   │   └── VoiceRecorder.swift     # AVAudioRecorder wrapper for mic input
│   │
│   ├── Views/
│   │   ├── ChatView.swift          # Main chat UI, streaming, tool visualization, voice
│   │   ├── FilesView.swift         # SOUL/MEMORY/USER editor, workspace file manager
│   │   ├── ModelsView.swift        # Cloud/local model config, API key, reasoning settings
│   │   ├── SettingsView.swift      # Skills, packages, memory, shortcuts, advanced options
│   │   ├── CronView.swift          # Scheduled jobs viewer with logs
│   │   └── LeopardTheme.swift      # Mac OS X Leopard UI components and color palette
│   │
│   ├── BridgingHeader.h            # C API bridge for Python + llama + whisper
│   ├── Info.plist                   # App permissions, URL schemes, background modes
│   ├── Pegasus.entitlements         # App entitlements
│   ├── Python.xcframework/          # Embedded Python runtime (beeware)
│   └── whisper.xcframework/         # Speech-to-text engine (ggerganov)
│
├── PythonBackend/
│   └── hermes_bridge/              # Python agent (inspired by Hermes Agent)
│       ├── __init__.py             # Package init, starts agent on import
│       ├── agent_runner.py         # Core agent loop: messages → LLM → tool_calls → loop
│       ├── tools_builtin.py        # 40+ tool implementations (3800+ lines)
│       ├── tool_registry.py        # Tool registration, schema generation, dispatch
│       ├── prompt_builder.py       # 5-layer system prompt assembly
│       ├── memory_manager.py       # Bounded MEMORY.md + USER.md persistence
│       ├── skill_manager.py        # Skill CRUD with YAML frontmatter
│       ├── cron_manager.py         # Background job scheduler with logging
│       ├── llm_server.py           # (Legacy) LLM server for remote backend mode
│       └── api_server.py           # (Legacy) Flask API for remote backend mode
│
├── scripts/
│   ├── setup.sh                    # Initial setup: directories, dependencies, model check
│   └── download-model.sh           # Helper to download GGUF models from HuggingFace
│
├── training/
│   ├── finetune_qwen_hermes.py     # Fine-tuning script for custom Hermes-style models
│   └── Pegasus_Finetune.ipynb      # Jupyter notebook for model fine-tuning
│
├── build_ios_deps/
│   └── build_lxml.sh              # Cross-compile lxml for iOS arm64
│
├── build_whisper.sh                # Build whisper.xcframework from source
└── setup_python.sh                 # Set up Python.xcframework
```

---

## License

This project is provided as-is for personal and research use.
