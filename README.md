# causa-demos

> Runnable demos that showcase **Causa AI** capabilities in Kubernetes environments.

---

## Available Demos

The two demos are **independent** — each provisions its own Kind cluster and can be run in any order or in isolation. You do not need to run the Kind demo before the Quarkus RCA demo.

### 1. Kind Demo

Provisions a local Kubernetes cluster using Kind and installs all required components to demonstrate Causa AI in action with a fully local, offline setup.

**What the demo does:**

- Creates a Kind Kubernetes cluster named `causa`
- Installs the Causa RCA Agent into the cluster
- Installs Prometheus stack (via kube-prometheus) and cAdvisor for container metrics
- Deploys Ollama in-cluster and pulls the [phi3:mini](https://ollama.com/library/phi3) model for fully local, offline root cause analysis
- Deploys a Quarkus-based sample application that intentionally causes a heap Out Of Memory (OOM) condition
- Deploys a load generator that gradually increases heap usage
- Triggers a controlled OOM failure and allows the Causa RCA Agent to produce RCA output

**Prerequisites:**

```text
kind      docker      kubectl      git      jq      python3     helm
```

> Ollama requires CPU-only execution with a minimum of 4 vCPUs (6+ recommended), at least 8 GB RAM (16 GB recommended), and approximately 2.5–3 GB free disk space for the phi3:mini model weights.

**Quick start:**

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/kind
./demo.sh
```

**Cleanup:**

```bash
# Remove all resources
./demo.sh -t

# Remove resources and artifacts directory
./demo.sh -t -f
```

---

### 2. Quarkus RCA Demo

An end-to-end demo that deploys a **quarkus-perf** workload engineered for chaos testing, installs the full Causa RCA stack, configures LLM credentials, and wires up any MCP-capable AI assistant for AI-powered root cause analysis.

**What the demo does:**

- Provisions the target environment (`kind` or `openshift`) and deploys the full Causa RCA stack via the [Causa RCA installer](https://github.com/causaai/installer)
- Deploys **quarkus-perf** with chaos scenarios enabled (`large-response`, `idle-timeout`, `memory-cache`) and starts a load-gen job
- Pushes LLM credentials to Causa Backend (Vertex AI, Bob, Anthropic, OpenAI, and others)
- Writes `.mcp.json` to the repo root — auto-loaded by Claude Code, Cursor, Windsurf, VS Code Copilot, and Gemini CLI
- Optionally installs the `causa-rca` skill to Bob or Claude Code via `--skill-path`
- Prints ready-to-paste RCA prompts

**Prerequisites:**

```text
kind      kubectl      docker (or podman)      git      python3     helm
```

**Quick start:**

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/quarkus-rca
./demo.sh
```

See **[quarkus-rca/README.md](quarkus-rca/README.md)** for skill installation, LLM setup, and CLI options.

**Cleanup:**

```bash
./demo.sh -t
```
