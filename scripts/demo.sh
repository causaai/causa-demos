#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OLLAMA_IMAGE="docker.io/ollama/ollama:0.17.1"
DEFAULT_MONGO_IMAGE="docker.io/library/mongo:7.0"
DEFAULT_HEAP_OOM_IMAGE="quay.io/causa-ai-hub/quarkus-heap-oom:heap-oom-prom"

DEFAULT_RCA_AGENT_IMAGE="quay.io/rh-ee-shesaxen/rca-agent:poc_v9"
RCA_AGENT_IMAGE="${DEFAULT_RCA_AGENT_IMAGE}"
OLLAMA_IMAGE="${$DEFAULT_OLLAMA_IMAGE}"
MONGO_IMAGE="${$DEFAULT_MONGO_IMAGE}"
HEAP_OOM_IMAGE="${$DEFAULT_HEAP_OOM_IMAGE}"


REPO_URL="https://github.com/causaai/causa.git"
REPO_NAME="causa"
ARTIFACTS_DIR="artifacts"
ALERT_YAML_DIR="deployment/sample"
DEFAULT_BRANCH_NAME="poc"
BRANCH_NAME="${DEFAULT_BRANCH_NAME}"

PROM_REPO_NAME="kube-prometheus"
PROM_REPO_URL="https://github.com/prometheus-operator/kube-prometheus.git"

PROM_VERSION="v0.13.0"
PROM_DIR="${ARTIFACTS_DIR}/${PROM_REPO_NAME}"

CLUSTER_NAME="causa"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

CLUSTER_TYPE="kind"

FORCE=false
TERMINATE=false
LOAD=false

while getopts ":fti:b:lc:" opt; do
  case "${opt}" in
    f) FORCE=true ;;
    t) TERMINATE=true ;;
    i) RCA_AGENT_IMAGE="${OPTARG}" ;;
    b) BRANCH_NAME="${OPTARG}" ;;
    l) LOAD=true ;;
    c)
      if [[ "${OPTARG}" != "kind" && "${OPTARG}" != "openshift" ]]; then
        echo "ERROR: Cluster type must be 'kind' or 'openshift'"
        exit 1
      fi
      CLUSTER_TYPE="${OPTARG}"
      ;;
    o) OLLAMA_IMAGE="${OPTARG}" ;;
    m) MONGO_IMAGE="${OPTARG}" ;;
    w) HEAP_OOM_IMAGE="${OPTARG}" ;;
    *)
      echo "Usage: $0 [-f] [-t] [-l] [-c <Cluster Type: kind | openshift>] [-i <rca-agent-image>] [-o <ollama-image>] [-m <mongo-image>] [-w <heap-oom-image>] [-b <branch-name>]"
      exit 1
      ;;
  esac
done

# Set deployment directory based on cluster type
if [[ "${CLUSTER_TYPE}" == "openshift" ]]; then
  DEPLOYMENT_DIR="deployment/openshift"
else
  DEPLOYMENT_DIR="deployment/kind"
fi

# Always required
REQUIRED_BINS=(curl kubectl git)

# Conditionally required
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  REQUIRED_BINS+=(kind docker jq python3)
fi

# Validate tools
for bin in "${REQUIRED_BINS[@]}"; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: ${bin} is not installed"
    exit 1
  fi
done

install_cadvisor() {
  echo "Installing cAdvisor..."
  kubectl create namespace cadvisor --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f https://raw.githubusercontent.com/google/cadvisor/master/deploy/kubernetes/base/daemonset.yaml
}

install_prom() {
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
}

get_free_port() {
  python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
EOF
}

run_heap_load() {
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

}

if [ "${TERMINATE}" = true ]; then
  echo "Termination requested for ${CLUSTER_TYPE} cluster. Cleaning up..."

  if [[ "${CLUSTER_TYPE}" == "openshift" ]]; then
    # OpenShift cleanup path
    echo "Cleaning up OpenShift resources..."
    
    # Delete RCA agent
    kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}/deployment.yaml" --ignore-not-found
    
    # Delete heap-oom application
    kubectl delete -f https://raw.githubusercontent.com/causaai/chaos-lab/main/heap-oom-prom/manifests/deploy.yaml --ignore-not-found
    
    # Delete alerts
    kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${ALERT_YAML_DIR}/prometheus-alerting-openshift.yaml" --ignore-not-found
    
    # Delete supporting resources (ollama, mongodb, rbac)
    kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}/ollama.yaml" --ignore-not-found
    kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}/mongodb.yaml" --ignore-not-found
    kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}/rbac.yaml" --ignore-not-found
    
  elif [[ "${CLUSTER_TYPE}" == "kind" ]]; then
    # Kind cleanup path
    if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
      kubectl config use-context "${KUBE_CONTEXT}" || true

      # Delete RCA agent and supporting resources
      if [ -d "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}" ]; then
        kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${DEPLOYMENT_DIR}" --ignore-not-found
      fi

      # Delete heap-oom application
      kubectl delete -f https://raw.githubusercontent.com/causaai/chaos-lab/main/heap-oom-prom/manifests/deploy.yaml --ignore-not-found

      # Delete alerts
      kubectl delete -f "${ARTIFACTS_DIR}/${REPO_NAME}/${ALERT_YAML_DIR}/prometheus-alerting-kind.yaml" --ignore-not-found

      # Delete Prometheus
      kubectl delete -f "${PROM_DIR}/manifests" --ignore-not-found
      kubectl delete namespace monitoring --ignore-not-found

      # Delete cAdvisor
      kubectl delete -f https://raw.githubusercontent.com/google/cadvisor/master/deploy/kubernetes/base/daemonset.yaml --ignore-not-found || true

      # Delete Kind cluster
      echo "Deleting kind cluster '${CLUSTER_NAME}'..."
      kind delete cluster --name "${CLUSTER_NAME}"
    else
      echo "kind cluster '${CLUSTER_NAME}' does not exist. Nothing to terminate."
    fi
  fi

  # Force cleanup of artifacts (common to both paths)
  if [ "${FORCE}" = true ]; then
    echo "Cleaning up artifacts directory..."
    if [ -d "${ARTIFACTS_DIR}" ]; then
      rm -rf -- "${ARTIFACTS_DIR}"
      echo "Artifacts directory removed."
    fi
  fi

  echo "Termination complete for ${CLUSTER_TYPE}."
  exit 0
fi


# check if kind
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
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


  # pre-load images
  IMAGES=(
    "${OLLAMA_IMAGE}"
    "${RCA_AGENT_IMAGE}"
    "${MONGO_IMAGE}"
    "${HEAP_OOM_IMAGE}"
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

  # Install Cadvisor
  install_cadvisor

  # Install Prometheus
  install_prom

  # Check for CRD's
  echo "Waiting for Prometheus custom resource to be fully available..."
  kubectl wait --for=condition=Available --timeout=300s \
    -n monitoring prometheus/k8s
fi

mkdir -p "${ARTIFACTS_DIR}"
REPO_PATH="${ARTIFACTS_DIR}/${REPO_NAME}"

if [ "${FORCE}" = true ] && [ -d "${REPO_PATH}" ]; then
  rm -rf "${REPO_PATH}"
fi

if [ ! -d "${REPO_PATH}/.git" ]; then
  git clone -b "${BRANCH_NAME}" --single-branch "${REPO_URL}" "${REPO_PATH}"
fi

ALERT_PATH="${REPO_PATH}/${ALERT_YAML_DIR}"
if [ -d "${ALERT_PATH}" ]; then
  echo "Applying Prometheus alert configurations..."
  kubectl apply -f "${ALERT_PATH}/prometheus-alerting-${CLUSTER_TYPE}.yaml"
else
  echo "WARNING: Alert configuration directory not found: ${ALERT_PATH}"
fi

echo "Installing heap-oom application"
kubectl apply -f https://raw.githubusercontent.com/causaai/chaos-lab/main/heap-oom-prom/manifests/deploy.yaml

echo "Patching the application with rca label"
kubectl patch -n chaos-test deployment heap-oom-prom -p '{"spec":{"template":{"metadata":{"labels":{"kruize/rca":"enabled"}}}}}'

DEPLOY_PATH="${REPO_PATH}/${DEPLOYMENT_DIR}"
if [ ! -d "${DEPLOY_PATH}" ]; then
  echo "ERROR: Deployment directory not found: ${DEPLOY_PATH}"
  exit 1
fi

kubectl apply -f "${DEPLOY_PATH}/rbac.yaml"
kubectl apply -f "${DEPLOY_PATH}/ollama.yaml"
kubectl apply -f "${DEPLOY_PATH}/mongodb.yaml"

echo "Waiting for application deployments to become ready..."

kubectl wait -n chaos-test deployment/heap-oom-prom \
  --for=condition=Available \
  --timeout=300s

kubectl wait deployment/ollama \
  --for=condition=Available \
  --timeout=900s

kubectl wait deployment/mongodb \
  --for=condition=Available \
  --timeout=300s

echo "Pulling models in Ollama..."

OLLAMA_POD="$(kubectl get pods -l app=ollama -o jsonpath='{.items[0].metadata.name}')"

kubectl exec -it "${OLLAMA_POD}" -- ollama pull llama2:7b-chat-q8_0

echo "llama2:7b-chat-q8_0 model downloaded successfully."

kubectl apply -f "${DEPLOY_PATH}/deployment.yaml"
echo "Waiting for RCA agent deployment to become ready..."

kubectl wait deployment/rca-agent \
  --for=condition=Available \
  --timeout=300s

echo "All deployments are ready."


if [ "${LOAD}" = true ]; then
  run_heap_load
else
  echo "Load generation disabled. Use -l to enable heap load demo."
fi

echo ""
echo "Setting up port-forward for RCA Agent Dashboard..."
RCA_LOCAL_PORT=9090
kubectl port-forward -n default svc/rca-agent ${RCA_LOCAL_PORT}:9090 >/dev/null 2>&1 &
PF_RCA_PID=$!

echo "Waiting for port-forward to be active..."
sleep 3

echo ""
echo "=========================================="
echo "Causa Demo Setup Complete!"
echo "=========================================="
echo ""
echo "RCA Agent Dashboard: http://localhost:${RCA_LOCAL_PORT}"
echo ""
echo "To stop port-forward: kill ${PF_RCA_PID}"
echo "=========================================="

