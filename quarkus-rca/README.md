# Quarkus RCA Demo

> A configurable demo that provisions a Kubernetes environment (`kind` or `openshift`), deploys a Quarkus workload engineered for chaos testing, and wires up **Causa AI** for AI-powered root cause analysis with any MCP-capable AI assistant.

---

## What the Demo Does

| Step | Action |
|------|--------|
| **1** | Clones and runs the Quarkus RCA installer with `--target <kind\|openshift>` — provisions infrastructure, Prometheus, Causa Backend, Causa MCP, PostgreSQL, and the Kubernetes MCP Server |
| **2** | Deploys the **quarkus-perf** workload and load-gen job into the target namespace with chaos scenarios enabled (`large-response`, `idle-timeout`, `memory-cache`) |
| **3** | Sources `llm.env` (supports Vertex AI, Bob, Anthropic, OpenAI, etc.), creates credentials secrets, and pushes LLM config to Causa via `POST /api/v1/configs` |
| **4** | Writes `.mcp.json` to the repo root (cross-IDE MCP standard — auto-loaded by Claude Code, Cursor, Windsurf, VS Code Copilot, Gemini CLI). Optionally installs the causa-rca skill to a user-supplied directory via `--skill-path` |
| **5** | Prints ready prompts with workload details and skill setup instructions |

The workload runs with `CHAOS_MEMORY_CACHE_ENABLED=true` — each transaction caches 192 KB with no eviction. Load-gen drives traffic at 20 workers × 100 ms delay. The 512 Mi heap fills in approximately 3–5 minutes, triggering an OOMKill that Causa diagnoses autonomously.

---

## Prerequisites

- `kind` (if `--target kind`) or an existing cluster (`--target openshift`)
- `kubectl`, `git`, `python3`
- `docker` or `podman`
- LLM credentials in `llm.env` (copy `llm.env.example` and fill in values)

---

## Quick Start

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/quarkus-rca

# Full demo — MCP configured via .mcp.json, skill instructions printed at end
./demo.sh

# Also install the causa-rca skill to Bob
./demo.sh --skill-path ~/.bob/skills

# Also install the causa-rca skill to Claude Code
./demo.sh --skill-path ~/.claude/skills

# Tear down everything when done
./demo.sh -t
```

---

## MCP Server Configuration

The demo always writes `.mcp.json` to the repo root. Any tool that implements the cross-IDE MCP standard picks it up automatically when you open the project — no per-user or per-tool setup required:

| Tool | How it loads `.mcp.json` |
|------|--------------------------|
| Claude Code (`claude` CLI / IDE) | Auto-loaded from the current directory |
| Cursor | Auto-loaded from the project root |
| Windsurf | Auto-loaded from the project root |
| VS Code + Copilot | Auto-loaded from `.vscode/mcp.json` or project root |
| Gemini CLI | Auto-loaded from the current directory |

---

## Skill Configuration

The `causa-rca` skill teaches the AI assistant how to use the Causa MCP tools correctly. Use `--skill-path` to install it automatically, or copy it manually after the script completes.

```bash
# Bob — script appends /causa-rca automatically
./demo.sh --skill-path ~/.bob/skills

# Claude Code — placed as ~/.claude/skills/causa-rca/SKILL.md (invokable as /causa-rca)
./demo.sh --skill-path ~/.claude/skills
```

If `--skill-path` is not passed, the script prints the exact commands to do it manually at the end.

---

## After the Demo Script Completes

### 1. OOM pressure builds automatically

quarkus-perf leaks 192 KB of heap per transaction with no eviction. The load-gen job drives traffic that fills the 512 Mi container limit in approximately 3–5 minutes, at which point the pod is OOMKilled and Causa triggers autonomous RCA.

Watch pod restarts:
```bash
kubectl get pods -n causa-rca -w
```

### 2. Watch Causa analyse the failure

```bash
kubectl logs -n causa-rca -l app=causa-backend -f
```

### 3. Query RCA results directly

```bash
# List all diagnostics
curl http://localhost:30001/api/v1/diagnostics

# Full result for a specific diagnostic
curl http://localhost:30001/api/v1/diagnostics/<diag_id>
```

### 4. Paste the ready prompt into your AI assistant

The demo script prints 4 ready-to-use prompts at the end. Example:

> "Use the causa-rca skill to investigate why my quarkus-perf app is unhealthy.
> App: quarkus-perf, namespace: causa-rca, container: quarkus-perf, pod: \<pod-name\>.
> Check existing diagnostics first, then run RCA if needed, and show the root cause and fix."

---

## Logs

Demo log: `demo.log` (same directory as the script)

---

## Cleanup

```bash
./demo.sh -t
```
