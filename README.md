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
kind      docker      kubectl      git      jq      python3
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

An end-to-end demo that deploys a **quarkus-perf** workload engineered for chaos testing, installs the full Causa RCA stack (Causa Backend, Causa MCP, Kubernetes MCP Server, PostgreSQL, Prometheus), configures LLM credentials (Vertex AI, Bob, Anthropic, OpenAI), and wires up **Bob IDE** or **Claude Desktop** for AI-powered root cause analysis.

**What the demo does:**

- Provisions the target environment (`kind`, `openshift`, `vm`) and deploys the full Causa RCA stack via the [Quarkus RCA installer](https://github.com/causaai/installer)
- Deploys **quarkus-perf** with chaos scenarios enabled (`large-response`, `idle-timeout`, `memory-cache`)
- Pushes configurable LLM credentials (Vertex AI, Bob, Anthropic, OpenAI) to Causa Backend
- Registers the Causa MCP server in your selected frontend assistant (Bob IDE or Claude Desktop) and installs the `causa-rca` skill
- Prints ready-to-paste prompts for triggering RCA from any AI assistant

**Prerequisites:**

```text
kind      kubectl     docker (or podman)     git     python3
```

**Quick start:**

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/quarkus-rca
./demo.sh
```

See **[quarkus-rca/docs/SETUP.md](quarkus-rca/docs/SETUP.md)** for full prerequisites, LLM credential setup, CLI options, image overrides, Alertmanager configuration, and troubleshooting.

**Cleanup:**

```bash
./demo.sh -t
```
