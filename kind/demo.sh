#!/usr/bin/env bash
set -euo pipefail

for bin in kind kubectl git docker jq python3; do
  command -v "${bin}" >/dev/null 2>&1 || {
    echo "ERROR: ${bin} is not installed"
    exit 1
  }
done

get_free_port() {
  python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
EOF
}

DEFAULT_RCA_AGENT_IMAGE="quay.io/rh-ee-shesaxen/rca-agent:poc_2.0"
RCA_AGENT_IMAGE="${DEFAULT_RCA_AGENT_IMAGE}"

REPO_URL="https://github.com/causaai/causa.git"
REPO_NAME="causa"
ARTIFACTS_DIR="artifacts"
DEPLOYMENT_DIR="deployment/kind"
DEFAULT_BRANCH_NAME="poc"
BRANCH_NAME="${DEFAULT_BRANCH_NAME}"

PROM_REPO_NAME="kube-prometheus"
PROM_REPO_URL="https://github.com/prometheus-operator/kube-prometheus.git"

PROM_VERSION="v0.13.0"
PROM_DIR="${ARTIFACTS_DIR}/${PROM_REPO_NAME}"

CLUSTER_NAME="causa"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

FORCE=false
TERMINATE=false

while getopts ":fti:b:" opt; do
  case "${opt}" in
    f) FORCE=true ;;
    t) TERMINATE=true ;;
    i) RCA_AGENT_IMAGE="${OPTARG}" ;;
    b) BRANCH_NAME="${OPTARG}" ;;
    *)
      echo "Usage: $0 [-f] [-t] [-i <rca-agent-image>] [-b <branch-name>]"
      exit 1
      ;;
  esac
done

if [ "${FORCE}" = true ] && [ "${TERMINATE}" = true ]; then
  echo "ERROR: -f and -t cannot be used together"
  exit 1
fi

if [ "${TERMINATE}" = true ]; then
  echo "Termination requested. Cleaning up..."

  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    kubectl config use-context "${KUBE_CONTEXT}" || true

    echo "Deleting application resources..."
    if [ -d "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}" ]; then
      kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}" --ignore-not-found
    fi

    echo "Deleting heap-oom application"
    kubectl delete -f https://raw.githubusercontent.com/doofenshmirtz-dev/quarkus-crash/main/heap-oom/manifests/deploy.yaml

    echo "Deleting Prometheus resources..."
    kubectl delete -f "${PROM_DIR}/manifests" --ignore-not-found
    kubectl delete namespace monitoring --ignore-not-found

    echo "Deleting cAdvisor resources..."
    kubectl delete -f https://raw.githubusercontent.com/google/cadvisor/master/deploy/kubernetes/base/daemonset.yaml \
      --ignore-not-found || true

    echo "Deleting kind cluster '${CLUSTER_NAME}'..."
    kind delete cluster --name "${CLUSTER_NAME}"
  else
    echo "kind cluster '${CLUSTER_NAME}' does not exist. Nothing to terminate."
  fi

  echo "Cleaning up artifacts directory..."
  if [ -d "${ARTIFACTS_DIR}" ]; then
    rm -rf -- "${ARTIFACTS_DIR}"
    echo "Artifacts directory removed."
  else
    echo "Artifacts directory does not exist."
  fi

  echo "Termination complete."
  exit 0
fi

if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}"
else
  echo "kind cluster '${CLUSTER_NAME}' already exists."
fi

CURRENT_CONTEXT="$(kubectl config current-context || true)"
if [ "${CURRENT_CONTEXT}" != "${KUBE_CONTEXT}" ]; then
  kubectl config use-context "${KUBE_CONTEXT}"
fi

IMAGES=(
  "docker.io/ollama/ollama:0.17.1"
  "${RCA_AGENT_IMAGE}"
  "docker.io/library/mongo:7.0"
  "quay.io/causa-ai-hub/quarkus-heap-oom:latest"
)

echo "Preloading Docker images..."

for image in "${IMAGES[@]}"; do
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Pulling ${image}..."
    docker pull "${image}"
  else
    echo "Image ${image} already present locally."
  fi

  echo "Loading ${image} into kind cluster '${CLUSTER_NAME}'..."
  kind load docker-image "${image}" --name "${CLUSTER_NAME}"
done

echo "Installing cAdvisor..."
kubectl create namespace cadvisor --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://raw.githubusercontent.com/google/cadvisor/master/deploy/kubernetes/base/daemonset.yaml



if [ ! -d "${PROM_DIR}" ]; then
  git clone "${PROM_REPO_URL}" "${PROM_DIR}"
  cd "${PROM_DIR}"
  git checkout "${PROM_VERSION}"
  cd -
fi

echo "Installing Prometheus stack..."

kubectl apply --server-side -f "${PROM_DIR}/manifests/setup"
kubectl wait \
  --for condition=Established \
  --all CustomResourceDefinition \
  -n monitoring

kubectl apply -f "${PROM_DIR}/manifests"

echo -n "Wait till prometheus pods comes up ... "
kubectl wait \
  --for=condition=Ready \
  pod \
  --all \
  -n monitoring \
  --timeout=10m

echo "Done."


echo "Installing heap-oom application"
kubectl apply -f https://raw.githubusercontent.com/causaai/chaos-lab/main/heap-oom/manifests/deploy.yaml

echo "Patching the application with rca label"
kubectl patch deployment heap-oom -p '{"spec":{"template":{"metadata":{"labels":{"kruize/rca":"enabled"}}}}}'

mkdir -p "${ARTIFACTS_DIR}"
REPO_PATH="${ARTIFACTS_DIR}/${REPO_NAME}"

if [ "${FORCE}" = true ] && [ -d "${REPO_PATH}" ]; then
  rm -rf "${REPO_PATH}"
fi

if [ ! -d "${REPO_PATH}/.git" ]; then
  git clone -b "${BRANCH_NAME}" --single-branch "${REPO_URL}" "${REPO_PATH}"
fi

DEPLOY_PATH="${REPO_PATH}/${DEPLOYMENT_DIR}"
if [ ! -d "${DEPLOY_PATH}" ]; then
  echo "ERROR: Deployment directory not found: ${DEPLOY_PATH}"
  exit 1
fi

kubectl apply -f "${DEPLOY_PATH}"

echo "Waiting for application deployments to become ready..."

kubectl wait deployment/heap-oom \
  --for=condition=Available \
  --timeout=300s

kubectl wait deployment/ollama \
  --for=condition=Available \
  --timeout=900s

kubectl wait deployment/mongodb \
  --for=condition=Available \
  --timeout=300s

kubectl wait deployment/rca-agent \
  --for=condition=Available \
  --timeout=300s

echo "All deployments are ready."

echo "Pulling models in Ollama..."

OLLAMA_POD="$(kubectl get pods -l app=ollama -o jsonpath='{.items[0].metadata.name}')"

kubectl exec -it "${OLLAMA_POD}" -- ollama pull phi3:mini

echo "phi3:mini model downloaded successfully."

LOCAL_PORT="$(get_free_port)"
SERVICE_PORT=8080
SERVICE_NAME="heap-oom-service"

echo "Using free local port: ${LOCAL_PORT}"

HEAP_OOM_URL="http://127.0.0.1:${LOCAL_PORT}/alloc/hit"
echo "Heap OOM URL: ${HEAP_OOM_URL}"
DELAY_SECS=2
FINAL_TIMEOUT=10

echo "Port-forwarding heap-oom service..."
kubectl port-forward svc/${SERVICE_NAME} "${LOCAL_PORT}:${SERVICE_PORT}" >/tmp/heap-oom-pf.log 2>&1 &
PF_PID=$!

cleanup() {
  kill "${PF_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo -n "Waiting for 5 secs for port-forward to be active "
for _ in {1..10}; do
  printf "."
  sleep 0.5
done
echo " done"

echo "Starting controlled heap allocation load..."

while true; do
  echo "Sending allocation request..."

  RESPONSE="$(curl -s --fail "${HEAP_OOM_URL}" || true)"
  echo ${RESPONSE}

  if [ -z "${RESPONSE}" ]; then
    echo "Request failed or service unreachable. Exiting."
    exit 1
  fi

  UNITS_LEFT="$(echo "${RESPONSE}" | jq -r '.unitsLeft')"

  echo "unitsLeft=${UNITS_LEFT}"

  if [ "${UNITS_LEFT}" -eq 1 ]; then
    echo "unitsLeft == 1 detected. Sending FINAL request..."

    curl "${HEAP_OOM_URL}" &
    FINAL_PID=$!

    echo "Waiting ${FINAL_TIMEOUT}s for final request..."
    sleep "${FINAL_TIMEOUT}"

    echo "Cancelling final request (PID=${FINAL_PID})"
    kill "${FINAL_PID}" >/dev/null 2>&1 || true

    echo "Demo complete: heap OOM reached."
    exit 0
  fi

  sleep "${DELAY_SECS}"
done

echo "Causa Demo Setup complete."
