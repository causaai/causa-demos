# Quarkus RCA Demo

> A robust, configurable demo that provisions a target Kubernetes environment (`kind`, `openshift`, `vm`), deploys a Quarkus workload engineered for chaos testing, and wires up **Causa AI** for AI-powered root cause analysis across **Bob IDE**, **Claude Desktop**, or any MCP-compatible AI assistant.

---

## What the Demo Does

| Step | Action |
|------|--------|
| **1** | Clones and runs the Quarkus RCA installer with `--target <kind|openshift|vm>` — provisions infrastructure, Prometheus, Causa Backend, Causa MCP, PostgreSQL, and the Kubernetes MCP Server |
| **2** | Deploys the **quarkus-perf** workload and load-gen job into the target namespace with chaos scenarios enabled (`large-response`, `idle-timeout`, `memory-cache`) |
| **3** | Sources `llm.env` (supports Vertex AI, Bob, Anthropic, OpenAI, etc.), creates credentials secrets, and pushes LLM config to Causa via `POST /api/v1/configs` |
| **4** | Configures the selected frontend assistant (`--frontend bob|claude|all|none`, default `bob`) — registers Causa MCP and installs the skill |
| **5** | Prints ready prompts with container/namespace/pod info to paste directly into your AI chat assistant |

The workload runs with `CHAOS_MEMORY_CACHE_ENABLED=true` — each transaction caches 192 KB with no eviction. Load-gen drives traffic at 20 workers × 100 ms delay. The 512 Mi heap fills in approximately 3–5 minutes, triggering an OOMKill that Causa diagnoses autonomously.

---

## Running the Demo

See **[docs/SETUP.md](docs/SETUP.md)** for:

- Prerequisites (CLI tools, cluster access, LLM credentials)
- Quick-start commands
- All CLI options
- Image override configuration
- Repository structure after setup
- Troubleshooting guide

---

## Quick Start

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/quarkus-rca

# Full demo — Kind cluster + installer + workload + LLM config
./demo.sh

# Tear down everything when done
./demo.sh -t
```

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

### 4. Use Bob IDE

The demo script registers the Causa MCP server in `~/.bob/settings/mcp.json` automatically.
Once setup is complete, paste the ready prompt printed by the script into Bob IDE:

> "Use Causa RCA to investigate why my quarkus-perf app keeps crashing.
> App: quarkus-perf, namespace: causa-rca, container: quarkus-perf, pod: \<pod-name\>.
> Run RCA using the causa-rca skill and show me the root cause and fix."

Bob calls `initiate_rca`, polls until `COMPLETED`, then presents root cause + fix.

---

## Logs

Demo log: `demo.log` (same directory as the script)

---

## Cleanup

```bash
# Remove all demo resources
./demo.sh -t
```
