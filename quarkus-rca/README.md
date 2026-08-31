# Quarkus RCA Demo

An end-to-end demo that deploys a **quarkus-perf** workload engineered for chaos testing, provisions the full Causa RCA stack, and wires up any MCP-capable AI assistant for AI-powered root cause analysis.

---

## What the Demo Does

- Runs the [Quarkus RCA installer](https://github.com/causaai/installer) — provisions Causa Backend, Causa MCP, Kubernetes MCP Server, PostgreSQL, and Prometheus
- Deploys **quarkus-perf** with all three chaos scenarios enabled (`large-response`, `idle-timeout`, `memory-cache`) and starts a load-gen job
- Pushes LLM credentials to Causa Backend (Vertex AI, Bob, Anthropic, OpenAI, and others)
- Writes `.mcp.json` to the repo root — auto-loaded by Claude Code, Cursor, Windsurf, VS Code Copilot, and Gemini CLI
- Optionally installs the `causa-rca` skill to Bob or Claude Code via `--skill-path`
- Prints ready-to-paste RCA prompts

---

## Prerequisites

```text
kind      kubectl      docker (or podman)      git      python3     helm
```

- LLM credentials in `llm.env` (copy `llm.env.example` and fill in values)

---

## Quick Start

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/quarkus-rca

# Full demo — MCP registered, skill instructions printed at end
./demo.sh

# Also install the causa-rca skill to Bob
./demo.sh --skill-path ~/.bob/skills

# Also install the causa-rca skill to Claude Code
./demo.sh --skill-path ~/.claude/skills

# Tear down everything when done
./demo.sh -t
```

---

## Skill Installation

The `causa-rca` skill tells the AI assistant how to use the Causa MCP tools. Pass `--skill-path` to install automatically, or copy manually after the script completes.

| Tool | Path | Result |
|------|------|--------|
| Bob | `--skill-path ~/.bob/skills` | `~/.bob/skills/causa-rca/SKILL.md` |
| Claude Code | `--skill-path ~/.claude/skills` | `~/.claude/skills/causa-rca/SKILL.md` — invokable as `/causa-rca` |

If `--skill-path` is omitted, the script prints the exact manual copy commands at the end.

---

## After Setup

The load-gen job drives traffic that fills the 512 Mi heap in ~3–5 minutes, triggering an OOMKill. Causa detects and analyses the failure autonomously.

```bash
# Watch pod restarts
kubectl get pods -n causa-rca -w

# Watch Causa analyse the failure
kubectl logs -n causa-rca -l app=causa-backend -f

# Query RCA results directly
curl http://localhost:30001/api/v1/diagnostics
```

Paste one of the ready prompts printed by the script into your AI assistant to trigger RCA via the Causa MCP tools.

---

## Cleanup

```bash
./demo.sh -t
```

Demo log: `quarkus-rca/demo.log`
