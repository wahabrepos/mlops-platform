#!/usr/bin/env bash
# Create a kind cluster wired to a local Docker registry.
#
# WHY THE REGISTRY: without it, every image change needs `kind load docker-image`,
# which copies the whole image into each node — slow, and easy to forget, which
# produces the maddening symptom of a pod running yesterday's code. With a
# registry, `docker push` then `kubectl rollout restart` behaves exactly like a
# real cluster pulling from ACR.
#
# set -euo pipefail: exit on error, on undefined variable, and on any failure
# inside a pipeline. Without -o pipefail, `false | tee log` succeeds, which is
# how a broken script reports success.
set -euo pipefail

CLUSTER_NAME=mlops
REGISTRY_NAME=kind-registry
REGISTRY_PORT=5001

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

for tool in kind kubectl docker; do
  command -v "$tool" >/dev/null || { echo "missing: $tool"; exit 1; }
done

# --- 1. the registry ---------------------------------------------------------
if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]; then
  info "starting local registry on :${REGISTRY_PORT}"
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --name "$REGISTRY_NAME" registry:2
else
  info "registry already running"
fi

# --- 2. the cluster ----------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "cluster '$CLUSTER_NAME' already exists"
else
  info "creating cluster '$CLUSTER_NAME' (about 60s)"
  kind create cluster --config platform/local/kind-cluster.yaml
fi

# --- 3. connect them ---------------------------------------------------------
# The registry container and the kind nodes must share a Docker network, or the
# nodes cannot resolve "kind-registry".
if ! docker network inspect kind | grep -q "\"$REGISTRY_NAME\""; then
  info "connecting registry to the kind network"
  docker network connect kind "$REGISTRY_NAME" 2>/dev/null || true
fi

# --- 4. tell the cluster the registry exists ---------------------------------
# This ConfigMap is the documented KEP-1755 contract. Tools read it to learn
# where the cluster-local registry lives.
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
YAML

info "waiting for nodes to become Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

kubectl get nodes -o wide
echo
info "cluster ready. Push images to localhost:${REGISTRY_PORT}/<name>:<tag>"
