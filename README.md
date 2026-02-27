# causa-demos

### This Repository contains the demos for CAUSA AI

This repository provides runnable demos to showcase CAUSA AI capabilities in Kubernetes environments.

Currently, it contains a Kind-based demo that sets up a complete local Kubernetes environment and triggers a controlled failure scenario for RCA (Root Cause Analysis).

### Available Demos

#### 1. Kind Demo

The Kind demo provisions a local Kubernetes cluster using kind and installs all required components to demonstrate CAUSA AI in action.

What the demo does:

- Creates a kind Kubernetes cluster named causa
- Installs CAUSA RCA Agent into the cluster
- Installs Prometheus stack (via kube-prometheus)
- Installs cAdvisor for container metrics
- Deploys Ollama in-cluster and pulls the [phi3:mini](https://ollama.com/library/phi3) model to enable fully local, offline root cause analysis.
- Deploys a Quarkus-based sample application that intentionally causes a Heap Out Of Memory (OOM) condition
- Deploys a load generator that gradually increases heap usage
- Triggers a controlled OOM failure in the application
- Allows CAUSA RCA Agent to analyze the failure and produce RCA logs

#### Prerequisites

Ensure the following tools are installed and available in your `$PATH` before running the demo:

```text
kind

docker

kubectl

git

jq

python3
```

##### Ollama Model Requirements: 

- During deployment, the Ollama pod automatically pulls the required language model so it is available for inference at runtime. Currently, the following model is downloaded:

    - **Model**: [phi3:mini](https://ollama.com/library/phi3) (Provided by Microsoft)
    - Requires CPU-only execution with a minimum of 4 vCPUs (6+ vCPUs recommended).
    - Requires at least 8 GB RAM (16 GB recommended for stability).
    - ~ 2.5 GB to 3 GB free space is required for the model weights.
    - *Note: CPU and memory requirements are inferred from the model size, as Ollama does not publish per-model resource limits.*




#### How to run the demo

```bash
git clone https://github.com/causaai/causa-demos.git
cd causa-demos/kind
./demo.sh
```

#### Steps After the Demo Script Completes

Once the Kind demo script finishes running and reports that the Heap OOM has been reached, follow these steps to observe CAUSA AI in action:

- Inspect CAUSA RCA Agent logs

```bash
kubectl logs -f <rca-agent-pod>
```

- Clean up resources when done

Once you are done with the demo, proceed to clean it up with `-t` option

```bash
./demo.sh -t
```

To also remove the artifacts directory during cleanup, use `-f` with `-t`:

```bash
./demo.sh -f -t
```
