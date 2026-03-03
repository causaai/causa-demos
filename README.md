# Causa Demo

This repository contains a demonstration setup for the Causa RCA (Root Cause Analysis) agent, showcasing automated incident detection and analysis capabilities using Prometheus monitoring and AI-powered diagnostics.

## Overview

The demo script automates the deployment of a complete monitoring and analysis stack, including:
- **Prometheus Operator** for metrics collection and alerting
- **cAdvisor** for container metrics
- **Ollama** with LLaMA 2 model for AI-powered analysis
- **MongoDB** for data persistence
- **Causa RCA Agent** for automated root cause analysis
- **Heap OOM Application** as a sample workload to demonstrate failure scenarios

## Supported Platforms

This demo supports two Kubernetes platforms:

### 1. **Kind (Kubernetes in Docker)** - Default
- Creates a local Kubernetes cluster using Kind
- Automatically handles cluster creation and image loading
- Ideal for local development and testing

### 2. **OpenShift**
- Works with existing OpenShift clusters
- Skips cluster creation and image loading steps
- Uses OpenShift-specific alert configurations

## Prerequisites

### Common Requirements (Both Platforms)
- `curl`
- `kubectl`
- `git`

### Additional Requirements for Kind
- `kind`
- `docker`
- `jq`
- `python3`

## Usage

### Basic Setup

```bash
# For Kind (default)
./scripts/demo.sh

# For OpenShift
./scripts/demo.sh -c openshift
```

### Command-Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-c <type>` | Cluster type: `kind` or `openshift` | `kind` |
| `-i <image>` | Custom RCA agent image | `quay.io/rh-ee-shesaxen/rca-agent:poc_v9` |
| `-b <branch>` | Git branch to clone from causa repository | `poc` |
| `-l` | Enable heap load generation for demo | Disabled |
| `-f` | Force cleanup of artifacts directory | Disabled |
| `-t` | Terminate and cleanup all resources | Disabled |

### Examples

```bash
# Setup with custom RCA agent image
./scripts/demo.sh -i quay.io/myorg/rca-agent:latest

# Setup and run heap OOM load test
./scripts/demo.sh -l

# Setup on OpenShift with load generation
./scripts/demo.sh -c openshift -l

# Cleanup everything including artifacts
./scripts/demo.sh -t -f
```

## What the Demo Does

### For Kind Clusters

1. **Cluster Setup**
   - Creates a Kind cluster named `causa`
   - Sets the kubectl context to `kind-causa`

2. **Image Pre-loading**
   - Pulls and loads the following images into the Kind cluster:
     - `ollama/ollama:0.17.1`
     - RCA agent image (configurable)
     - `mongo:7.0`
     - `quarkus-heap-oom:heap-oom-prom`

3. **Monitoring Stack Installation**
   - Deploys cAdvisor for container metrics
   - Installs Prometheus Operator (v0.13.0)
   - Configures Prometheus custom resources
   - Waits for all monitoring components to be ready

4. **Application Deployment**
   - Clones the Causa repository
   - Applies Kind-specific Prometheus alert configurations
   - Deploys the heap-oom test application
   - Patches the application with RCA labels (`kruize/rca: enabled`)
   - Deploys RBAC, Ollama, and MongoDB
   - Deploys the RCA agent

5. **Model Setup**
   - Downloads the `llama2:7b-chat-q8_0` model into Ollama
   - Waits for all deployments to become available

6. **Optional Load Generation** (with `-l` flag)
   - Port-forwards the heap-oom service
   - Sends controlled allocation requests
   - Triggers an OOM scenario for demonstration

### For OpenShift Clusters

1. **Monitoring Stack Installation**
   - Assumes cluster already exists
   - Installs cAdvisor for container metrics
   - Installs Prometheus Operator (v0.13.0)
   - Configures Prometheus custom resources

2. **Application Deployment**
   - Clones the Causa repository
   - Applies OpenShift-specific Prometheus alert configurations
   - Deploys the heap-oom test application
   - Patches the application with RCA labels
   - Deploys RBAC, Ollama, and MongoDB
   - Deploys the RCA agent

3. **Model Setup**
   - Downloads the `llama2:7b-chat-q8_0` model into Ollama
   - Waits for all deployments to become available

4. **Optional Load Generation** (with `-l` flag)
   - Same as Kind setup

## Cleanup

### Partial Cleanup (Keep Artifacts)
```bash
./scripts/demo.sh -t
```

This removes:
- Application deployments
- Prometheus stack
- cAdvisor
- Kind cluster (if using Kind)

### Full Cleanup (Remove Everything)
```bash
./scripts/demo.sh -t -f
```

This removes everything above plus:
- Cloned repositories
- Downloaded artifacts

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                    │
│  ┌────────────┐  ┌──────────┐  ┌─────────────────────┐ │
│  │  cAdvisor  │  │Prometheus│  │   Heap OOM App      │ │
│  │ (metrics)  │─▶│ Operator │◀─│ (test workload)     │ │
│  └────────────┘  └──────────┘  └─────────────────────┘ │
│                        │                                 │
│                        ▼                                 │
│  ┌────────────────────────────────────────────────────┐ │
│  │              Prometheus Alerts                      │ │
│  └────────────────────────────────────────────────────┘ │
│                        │                                 │
│                        ▼                                 │
│  ┌────────────┐  ┌──────────┐  ┌─────────────────────┐ │
│  │  MongoDB   │◀─│RCA Agent │─▶│  Ollama + LLaMA 2   │ │
│  │ (storage)  │  │          │  │  (AI analysis)      │ │
│  └────────────┘  └──────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods --all-namespaces
```

### View RCA Agent Logs
```bash
kubectl logs -l app=rca-agent -f
```

### View Prometheus Alerts
```bash
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090
# Access http://localhost:9090/alerts
```

### Verify Ollama Model
```bash
OLLAMA_POD=$(kubectl get pods -l app=ollama -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $OLLAMA_POD -- ollama list
```

## Repository Structure

```
.
├── scripts/
│   └── demo.sh              # Main demo automation script
├── artifacts/               # Created during setup (gitignored)
│   ├── causa/              # Cloned Causa repository
│   └── kube-prometheus/    # Cloned Prometheus Operator
└── README.md               # This file
```

## License

See [LICENSE](LICENSE) file for details.
```