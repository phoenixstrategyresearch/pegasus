"""
Pegasus Fine-Tuning Script: Qwen 2.5 3B -> Hermes Tool-Calling Expert
======================================================================
Run this on Google Colab (free T4 GPU) or any machine with a GPU.

Setup (run these in a Colab cell first):
    !pip install unsloth
    !pip install --no-deps trl peft accelerate bitsandbytes

Then run this script:
    !python finetune_qwen_hermes.py

Output: A GGUF file you can drop into Pegasus.
"""

from unsloth import FastLanguageModel
from trl import SFTTrainer
from transformers import TrainingArguments
from datasets import load_dataset
import json
import re

# =============================================================================
# CONFIG
# =============================================================================
BASE_MODEL = "unsloth/Qwen2.5-3B"  # Unsloth's optimized 4-bit version
MAX_SEQ_LENGTH = 4096
LORA_RANK = 64  # Higher rank = more capacity for tool-calling patterns
OUTPUT_DIR = "./pegasus_qwen_finetuned"
GGUF_QUANTIZATION = "q8_0"  # Match your current model's quantization

# Pegasus tool schemas - these match what's registered in tools_builtin.py
PEGASUS_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web using DuckDuckGo",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"}
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "web_fetch",
            "description": "Fetch and read content from a URL",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL to fetch"}
                },
                "required": ["url"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_read",
            "description": "Read a file from the workspace",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path to read"}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_write",
            "description": "Write content to a file",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path"},
                    "content": {"type": "string", "description": "Content to write"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_list",
            "description": "List files in a directory",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory path"}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "python_exec",
            "description": "Execute Python code and return the result",
            "parameters": {
                "type": "object",
                "properties": {
                    "code": {"type": "string", "description": "Python code to execute"}
                },
                "required": ["code"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "memory_read",
            "description": "Read the agent's persistent memory",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "memory_write",
            "description": "Write an entry to persistent memory",
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "Memory entry to store"}
                },
                "required": ["content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "shell_exec",
            "description": "Execute a shell command",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command to run"}
                },
                "required": ["command"]
            }
        }
    },
]

TOOLS_STR = json.dumps(PEGASUS_TOOLS, indent=2)

# =============================================================================
# STEP 1: Load model with Unsloth (4-bit quantized, fast)
# =============================================================================
print("[1/5] Loading model...")
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name=BASE_MODEL,
    max_seq_length=MAX_SEQ_LENGTH,
    dtype=None,  # Auto-detect
    load_in_4bit=True,
)

# Add LoRA adapters
model = FastLanguageModel.get_peft_model(
    model,
    r=LORA_RANK,
    target_modules=[
        "q_proj", "k_proj", "v_proj", "o_proj",
        "gate_proj", "up_proj", "down_proj",
    ],
    lora_alpha=LORA_RANK,  # alpha = rank is a good default
    lora_dropout=0,
    bias="none",
    use_gradient_checkpointing="unsloth",  # Memory efficient
    random_state=42,
)

# =============================================================================
# STEP 2: Load and format the Hermes function-calling dataset
# =============================================================================
print("[2/5] Loading Hermes function-calling dataset...")
dataset = load_dataset("NousResearch/hermes-function-calling-v1", split="train")

# The Hermes dataset has conversations with tool calls.
# We need to format them into the Hermes chat template with <tool_call> tags,
# which is exactly the format Pegasus expects.

def format_hermes_conversation(example):
    """Convert a Hermes dataset example into a training prompt.

    The Hermes dataset format has a 'conversations' field with roles:
    system, human, gpt, tool (for tool results).

    We format this into the Hermes-style chat template that Pegasus uses:
    - System message includes available tools
    - Assistant tool calls use <tool_call> XML tags
    - Tool results come back as tool role messages
    """
    conversations = example.get("conversations", [])
    if not conversations:
        return {"text": ""}

    parts = []
    has_tool_call = False

    for msg in conversations:
        role = msg.get("from", msg.get("role", ""))
        content = msg.get("value", msg.get("content", ""))

        if not content:
            continue

        if role == "system":
            # Inject Pegasus tools into system prompt if it mentions tools
            system_content = content
            if "function" in content.lower() or "tool" in content.lower():
                system_content = (
                    f"{content}\n\n"
                    f"You have access to the following tools:\n"
                    f"<tools>\n{TOOLS_STR}\n</tools>\n\n"
                    f"To call a tool, output a JSON object inside <tool_call></tool_call> tags.\n"
                    f"Do NOT narrate or explain which tool you will use. Just call it directly."
                )
            parts.append(f"<|im_start|>system\n{system_content}<|im_end|>")

        elif role == "human":
            parts.append(f"<|im_start|>user\n{content}<|im_end|>")

        elif role == "gpt":
            # Check if the content contains function/tool calls
            # Hermes dataset may have them in various formats
            formatted_content = content

            # Convert JSON function calls to <tool_call> format
            # The dataset sometimes has raw JSON tool calls
            if '"name"' in content and '"arguments"' in content:
                has_tool_call = True
                # Wrap in tool_call tags if not already wrapped
                if "<tool_call>" not in content:
                    # Try to extract and reformat
                    try:
                        # Handle cases where content is just a JSON tool call
                        parsed = json.loads(content)
                        if isinstance(parsed, dict) and "name" in parsed:
                            formatted_content = (
                                f"<tool_call>\n"
                                f'{json.dumps(parsed)}\n'
                                f"</tool_call>"
                            )
                        elif isinstance(parsed, list):
                            # Multiple tool calls
                            tc_parts = []
                            for tc in parsed:
                                if isinstance(tc, dict) and "name" in tc:
                                    tc_parts.append(
                                        f"<tool_call>\n"
                                        f"{json.dumps(tc)}\n"
                                        f"</tool_call>"
                                    )
                            if tc_parts:
                                formatted_content = "\n".join(tc_parts)
                    except json.JSONDecodeError:
                        pass

            parts.append(f"<|im_start|>assistant\n{formatted_content}<|im_end|>")

        elif role == "tool":
            parts.append(f"<|im_start|>tool\n{content}<|im_end|>")

    text = "\n".join(parts)

    # Only keep examples that actually have tool interactions
    # (this is a tool-calling fine-tune, so skip pure chat)
    if not has_tool_call and "tool_call" not in text.lower():
        return {"text": ""}

    return {"text": text}


print("[2/5] Formatting dataset...")
formatted_dataset = dataset.map(format_hermes_conversation, num_proc=4)

# Filter out empty examples
formatted_dataset = formatted_dataset.filter(lambda x: len(x["text"]) > 100)
print(f"[2/5] Training examples after filtering: {len(formatted_dataset)}")

# Show a sample
print("\n--- Sample training example ---")
print(formatted_dataset[0]["text"][:1000])
print("--- End sample ---\n")

# =============================================================================
# STEP 3: Train with SFTTrainer
# =============================================================================
print("[3/5] Starting training...")
trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=formatted_dataset,
    args=TrainingArguments(
        output_dir=OUTPUT_DIR,
        per_device_train_batch_size=2,
        gradient_accumulation_steps=4,
        warmup_steps=50,
        num_train_epochs=2,
        learning_rate=2e-4,
        fp16=True,
        logging_steps=25,
        save_strategy="steps",
        save_steps=500,
        optim="adamw_8bit",
        seed=42,
        report_to="none",
    ),
    max_seq_length=MAX_SEQ_LENGTH,
    dataset_text_field="text",
    packing=True,  # Pack short examples together for efficiency
)

trainer.train()
print("[3/5] Training complete!")

# =============================================================================
# STEP 4: Save the model
# =============================================================================
print("[4/5] Saving model...")
model.save_pretrained(OUTPUT_DIR)
tokenizer.save_pretrained(OUTPUT_DIR)

# =============================================================================
# STEP 5: Export to GGUF for Pegasus
# =============================================================================
print(f"[5/5] Exporting to GGUF ({GGUF_QUANTIZATION})...")
model.save_pretrained_gguf(
    OUTPUT_DIR,
    tokenizer,
    quantization_method=GGUF_QUANTIZATION,
)

print(f"""
{'='*60}
DONE! Your fine-tuned model is ready.
{'='*60}

GGUF file location: {OUTPUT_DIR}/

To use in Pegasus:
1. Find the .gguf file in {OUTPUT_DIR}/
2. AirDrop or transfer it to your iPhone
3. Import it in Pegasus Models tab
4. Select it as your active model

The model is now trained on Hermes tool-calling data
with Pegasus-specific tool schemas. It should:
- Call tools directly without narrating
- Use <tool_call> XML tags correctly
- Handle web_search, web_fetch, file ops, memory, etc.
- Synthesize tool results into clean responses
""")
