# SmartPot

SmartPot is a low-code honeypot built on [Beelzebub](https://github.com/mariocandela/beelzebub).
You describe fake services in YAML (SSH, HTTP, TCP and MCP), and an LLM can play the
part of a real system for any request you don't script yourself. Attackers get a
convincing, interactive target, while SmartPot itself never executes what they type.

![LLM honeypot demo](https://github.com/user-attachments/assets/4dbb9a67-6c12-49c5-82ac-9b3e340406ca)

## What's different from upstream Beelzebub

- **`python-hf` LLM provider:** backs the LLM plugin with a Hugging Face Space
  instead of OpenAI or Ollama. See [docs/python-hf-provider.md](docs/python-hf-provider.md)
  for setup and known limitations. The Space it currently uses is asleep, so this
  provider isn't answering right now.
- **Docker image includes Python** (`python:3.13-slim` instead of `scratch`) so that
  provider can run.
- **The SSH honeypot on port 22 uses `python-hf`** for any command without a scripted reply.

## Features

- **YAML services:** one file per service in `configurations/services/`.
- **LLM-backed responses:** OpenAI, Ollama or `python-hf`, with optional
  prompt-injection guardrails (OpenAI and Ollama only).
- **Protocols:** SSH, HTTP/HTTPS, TCP, and MCP (to catch prompt injection against
  LLM agents).
- **Observability:** Prometheus metrics, JSON logs, optional RabbitMQ event
  tracing, and an [ELK integration](https://www.elastic.co/docs/reference/integrations/beelzebub).
- **Deployment:** Docker Compose, a plain Go binary, or the Helm chart in `beelzebub-chart/`.

## Quick start

### Docker Compose

```bash
make beelzebub.start   # docker compose build && docker compose up -d
make beelzebub.stop    # docker compose down
```

`configurations/` is mounted into the container, so config changes need only a
restart, not a rebuild. Set `OPEN_AI_SECRET_KEY` in your environment to use the
OpenAI-backed services.

> The Compose file publishes 22, 2222, 80, 8080, 3306 and 2112 (plus 8081, which no
> bundled service uses). The MCP honeypot listens on 8000 inside the container but
> isn't published; add `"8000:8000"` to `docker-compose.yml` to expose it.

### Go

Requires Go 1.24+.

```bash
go build
./beelzebub
```

For `python-hf`, also run `pip install -r plugins/requirements.txt` and start the
binary from the repo root (or set `PYTHON_HF_SCRIPT`).

### Kubernetes (Helm)

```bash
helm install beelzebub ./beelzebub-chart
helm upgrade beelzebub ./beelzebub-chart
```

The chart pulls a published image, so it won't have the `python-hf` changes until
an image built from this repo is pushed to its registry.

## Bundled services

| File | Port | What it pretends to be | Responses |
|---|---|---|---|
| `ssh-22.yaml` | 22 | Ubuntu SSH | Scripted replies for a few commands, `python-hf` for the rest |
| `ssh-2222.yaml` | 2222 | Ubuntu SSH | Everything from OpenAI `gpt-4o` |
| `http-80.yaml` | 80 | WordPress 6.0 | Scripted index page, OpenAI for all other paths |
| `http-8080.yaml` | 8080 | Apache with Basic auth | Always `401 Unauthorized` |
| `tcp-3306.yaml` | 3306 | MySQL 8.0.29 | Banner only |
| `mcp-8000.yaml` | 8000 | MCP server with admin tools | Scripted tool results |

The sample OpenAI keys (`sk-proj-123456`) are placeholders. Use `OPEN_AI_SECRET_KEY`
or put a real key in the file.

## Configuration

### Command-line flags

| Flag | Default | Purpose |
|---|---|---|
| `--confCore` | `./configurations/beelzebub.yaml` | Core config file |
| `--confServices` | `./configurations/services/` | Directory of service files |
| `--memLimitMiB` | `100` | Go memory limit; `-1` uses the system default |

### Core config (`configurations/beelzebub.yaml`)

```yaml
core:
  logging:
    debug: false
    debugReportCaller: false
    logDisableTimestamp: true
    logsPath: ./logs
  tracings:
    rabbit-mq:
      enabled: false
      uri: ""
  prometheus:
    path: "/metrics"
    port: ":2112"
  beelzebub-cloud:
    enabled: false
    uri: ""
    auth-token: ""
```

### Service files

Every file needs `apiVersion: "v1"`, `protocol` (`ssh`, `http`, `tcp` or `mcp`),
`address` (for example `":22"`) and a `description`.

**Commands** (`ssh`, `http`) are checked in order, and the first `regex` that matches wins:

| Field | Applies to | Purpose |
|---|---|---|
| `regex` | ssh, http | Matched against the command or request path |
| `handler` | ssh, http | Fixed response text |
| `plugin` | ssh, http | `"LLMHoneypot"` to answer with the LLM instead of `handler` |
| `headers`, `statusCode` | http | Response headers and status |
| `name` | ssh, http | Label recorded in events |

Put a catch-all such as `"^(.+)$"` last, or unmatched SSH commands get no reply at all.

**Other service fields:**

| Field | Applies to | Purpose |
|---|---|---|
| `serverVersion`, `serverName` | ssh | SSH version string and shell prompt host name |
| `passwordRegex` | ssh | Passwords that are "accepted" |
| `deadlineTimeoutSeconds` | ssh, tcp | Session timeout |
| `banner` | tcp | Text sent on connect |
| `fallbackCommand` | http | Response when no command matches |
| `tlsCertPath`, `tlsKeyPath` | http | Serve HTTPS when both are set |
| `tools` | mcp | Decoy tools, see below |

**LLM plugin** (`plugin:` block at the service level):

| Field | Purpose |
|---|---|
| `llmProvider` | `openai`, `ollama` or `python-hf` |
| `llmModel` | Model name, for example `gpt-4o` or `codellama:7b` |
| `openAISecretKey` | OpenAI key; the `OPEN_AI_SECRET_KEY` env var overrides it |
| `host` | Custom API endpoint (defaults to OpenAI's API or `http://localhost:11434/api/chat`) |
| `prompt` | Replaces the built-in system prompt |
| `inputValidationEnabled`, `inputValidationPrompt` | Ask the LLM to reject prompt-injection attempts before answering |
| `outputValidationEnabled`, `outputValidationPrompt` | Ask the LLM to reject responses that leak instructions or secrets |

Validation isn't supported with `python-hf`; enabling it makes every LLM call fail.

## Examples

### SSH answered by an LLM

```yaml
apiVersion: "v1"
protocol: "ssh"
address: ":2222"
description: "SSH interactive OpenAI GPT-4o"
commands:
  - regex: "^(.+)$"
    plugin: "LLMHoneypot"
serverVersion: "OpenSSH"
serverName: "ubuntu"
passwordRegex: "^(root|qwerty|123456|postgres)$"
deadlineTimeoutSeconds: 60
plugin:
  llmProvider: "openai"          # or "ollama" / "python-hf"
  llmModel: "gpt-4o"
  openAISecretKey: "sk-proj-123456"
```

For Ollama, set `llmProvider: "ollama"`, a model such as `llmModel: "codellama:7b"`,
and `host` if Ollama isn't on `localhost:11434`.

### SSH with scripted replies and an LLM fallback

```yaml
commands:
  - regex: "^ls$"
    handler: "Documents Images  Desktop Downloads .m2 .kube .ssh  .docker"
  - regex: "^uname -m$"
    handler: "x86_64"
  - regex: "^(.+)$"              # everything else
    plugin: "LLMHoneypot"
plugin:
  llmProvider: "python-hf"
```

### HTTP

```yaml
apiVersion: "v1"
protocol: "http"
address: ":8080"
description: "Apache 401"
commands:
  - regex: ".*"
    handler: "Unauthorized"
    headers:
      - "www-Authenticate: Basic"
      - "server: Apache"
    statusCode: 401
```

See `configurations/services/http-80.yaml` for a fake WordPress site that uses the LLM
for unknown paths.

### MCP decoy tools

An MCP honeypot exposes tools that a well-behaved agent should never call. When
one is called, a prompt injection has got past your agent's guardrails, and the
prompt that did it is logged.

```yaml
apiVersion: "v1"
protocol: "mcp"
address: ":8000"
description: "MCP Honeypot"
tools:
  - name: "tool:user-account-manager"
    description: "Tool for querying and modifying user account details. Requires administrator privileges."
    params:
      - name: "user_id"
        description: "The ID of the user account to manage."
      - name: "action"
        description: "get_details, reset_password or deactivate_account"
    handler: |
      {"tool_id": "tool:user-account-manager", "status": "completed",
       "output": {"result": {"operation_status": "success",
                             "details": "email: kirsten@gmail.com, role: admin"}}}
```

Tools also accept optional MCP `annotations` (`title`, `readOnlyHint`,
`destructiveHint`, `idempotentHint`, `openWorldHint`). Agents connect over
streamable HTTP at `http://<host>:8000/mcp`.

## Monitoring

- **Prometheus:** metrics at `:2112/metrics`, including total events and events per
  protocol (SSH, HTTP, TCP, MCP).
- **Logs:** JSON, written to `logsPath`.
- **RabbitMQ:** set `tracings.rabbit-mq.enabled: true` and `uri` in the core
  config to publish every event.

## Development

```bash
make test.unit                 # go test ./...
make test.dependencies.start   # start integration test dependencies
make test.integration          # INTEGRATION=1 go test ./...
make test.dependencies.down
```

The `python-hf` tests use a stand-in script and need `python3` on the `PATH`; they
are skipped otherwise.

## Credits and license

SmartPot is a fork of [Beelzebub](https://github.com/mariocandela/beelzebub) by
Mario Candela and contributors. For upstream's CI status, the Beelzebub
[white paper](https://github.com/beelzebub-labs/white-paper/) and community, and
upstream sponsors, see the Beelzebub repository. The previous README is kept as
[README.md.old](README.md.old).

Licensed under the [GNU GPL v3](LICENSE), as upstream is. See
[CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).
