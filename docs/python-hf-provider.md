# python-hf LLM provider

The `python-hf` provider backs the `LLMHoneypot` plugin with a public Hugging Face
Space (`WillemVH/LinuxEmulator`) instead of OpenAI or Ollama. It is currently used
by the SSH honeypot on port 22 (`configurations/services/ssh-22.yaml`).

## How it works

1. A command that matches a rule with `plugin: "LLMHoneypot"` reaches
   `ExecuteModel` in `plugins/llm-integration.go`.
2. For `PythonHF`, only the last user message (the command itself) is used. The
   system prompt, custom `prompt` and session history are not sent.
3. `pythonHFCaller` runs `python3 plugins/python_hf.py` and passes the command
   on stdin.
4. `python_hf.py` calls the Space's `/execute_command` endpoint through
   `gradio_client` and prints the result to stdout, which is returned to the
   attacker.

If anything fails, the error is logged as `error ExecuteModel: <command>, ...`
and the attacker sees `command not found`.

## Configuration

```yaml
commands:
  # ...static rules first; the first matching rule wins...
  - regex: "^(.+)$"
    plugin: "LLMHoneypot"
plugin:
  llmProvider: "python-hf"
```

| Setting | Default | Notes |
|---|---|---|
| `PYTHON_HF_SCRIPT` env var | `plugins/python_hf.py` | Path to the script, relative to the working directory. |
| Timeout | 30s | `pythonHFTimeout`. The script is killed and `python-hf timed out after 30s` is logged. |
| `inputValidationEnabled` / `outputValidationEnabled` | off | Not supported. `ExecuteModel` returns `input/output validation is not supported by the python-hf provider`. |

Python dependencies are pinned in `plugins/requirements.txt` (`gradio_client==2.7.1`).

## Docker

The final image is built from `python:3.13-slim` (previously `scratch`) so the
provider can run. It installs `plugins/requirements.txt` and copies
`plugins/python_hf.py` to `/plugins/`, with `/` as the working directory. The image
is about 267MB, up from a few MB, for every deployment, including ones that don't
use `python-hf`.

## Known limitations and open issues

### The Space is asleep

As of 2026-09-28, the Hugging Face API reports `WillemVH/LinuxEmulator` as
`SLEEPING` and its URL returns 403. `gradio_client` cannot wake a sleeping Space,
so every call fails with `Could not fetch config for https://willemvh-linuxemulator.hf.space`,
and port 22 answers `command not found` to any command that isn't a static rule.
The decision for now is to wait until the Space is back. Other options:

- Duplicate the Space into an account you control and change the name in
  `plugins/python_hf.py`. Free Spaces still sleep when idle.
- Switch `ssh-22.yaml` back to `llmProvider: "openai"` or `"ollama"`.

### A new Python process for every command

Each command starts a new `python3` process and a new Gradio client connection.
This adds noticeable delay, which an attacker could use to recognise the
honeypot. Fixing it needs a long-running helper process (or calling the Space's
HTTP API directly from Go), which is a larger design change.

### Commands are sent to a third-party Space

Every unmatched command an attacker types is sent to a public Space run by
someone else. They can see that traffic, and the honeypot depends on a service
that can be changed, rate-limited or removed at any time. Worth a deliberate
decision before relying on it.

### The Helm chart does not pick up the new image yet

`beelzebub-chart` pulls a published image rather than building locally. It won't
include the Python runtime until a new image is built and pushed to its registry.

### Other gaps

- No conversation memory: the Space sees each command in isolation.
- Input/output guardrails can't be used with this provider (see Configuration).
