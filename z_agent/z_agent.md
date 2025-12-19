# agent.md: AI Collaboration Protocol

This document defines the working relationship and technical standards for AI-assisted development in this repository.

## 1. The `copycf` Workflow (Context Management)
To maintain high reasoning quality, we use a "Small Context, High Frequency" reset strategy. Long chat threads degrade AI performance.

### The Skill
- **Tool:** `copycf` (Aliased from `home/zsh/copycr.sh`).
- **Function:** Aggregates specific file contents with clear markers (`===== ./path =====`) and metadata into the clipboard.
- **Protocol:**
    1.  User identifies the specific files relevant to a task.
    2.  User runs `copycf file1 file2...` and pastes the output into a **fresh** AI session.
   3.  This ensures the AI is not distracted by irrelevant code or previous chat history.

## 2. System Instructions for the AI
When starting a new session or providing a prompt, the following rules apply to the AI:

### Code Preservation & Editing
- **Surgical Edits:** Only change the specific logic requested. Do not refactor unrelated code.
- **Preserve Comments:** Do not delete or summarize my comments. Keep all headers and explanatory text exactly as they are.
- **Nix Structure:** Group related attributes (e.g., all `services`, all `boot` options) as seen in existing files. Do not flatten nested attribute sets.
- **Maintain Style:** Follow the existing indentation and "let...in" usage patterns.

### Output Standard
- **Full Files Only:** Always provide the **complete** content of the file being edited. Do not use `...` or "rest of file stays the same." This allows for immediate, safe copy-pasting back into the repository.
- **No Unnecessary Code:** Unless requested, do not provide boilerplate or examples outside of the files currently being edited.
- **Comments:** always leave old comments in code. Always comment your own code well, avoid anti-patterns such as the words "new" or "changed". just comment how your code work, not that it's 'changed'

## 3. Refactoring Protocol (Plan First)
Before writing any code, the AI must:
1.  Review the provided context.
2.  Provide a **conceptual plan** in plain English.
3.  Wait for user approval before generating Nix code.

## 4. Source of Truth
- **`hosts.nix`** is the Single Source of Truth for the entire fleet.
- All modules should dynamically read from `allHosts` and `hostConfig` rather than hardcoding usernames, IPs, or paths.

***

## How to use this file
When you start a new chat with an AI (Claude, GPT, etc.), you can simply say:

> "I'm working in my NixOS repo. Please read my `agent.md` for our working protocol, and then I will provide the `copycf` output for the files we are editing."

Then run your `copycf` command:
```bash
copycf agent.md hosts.nix [target_file]
``` 
