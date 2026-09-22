#!/bin/bash
# One-time: put Argo CD on a fresh cluster and hand it the root app. After
# this, Argo manages everything — including itself — from apps/.
#
#   export KUBECONFIG=~/.lima/k3s/copied-from-guest/kubeconfig.yaml
#   bootstrap/argocd.sh
#
# Idempotent: rerun after a rebuild of the VM, or if the first run failed.
#
# The chart is rendered with `helm template` and applied with kubectl rather
# than `helm install`, so there is no Helm release for Argo to fight with once
# apps/platform/argocd.yaml takes over. Version and values are the same ones
# that Application uses; when bumping, bump both.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_CHART_VERSION=$(sed -n 's/^ *targetRevision: *//p' apps/platform/argocd.yaml | head -1)
VALUES=apps/platform/values/argocd.yaml

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "need $tool (brew install $tool)"; exit 1; }
done
kubectl cluster-info >/dev/null || { echo "no cluster: is KUBECONFIG set?"; exit 1; }

echo "== Argo CD $ARGOCD_CHART_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Server-side apply: the Argo CD CRDs are bigger than the annotation limit
# client-side apply needs. The Application below sets the same option.
helm template argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd \
  --include-crds \
  -f "$VALUES" \
  | kubectl apply --server-side --force-conflicts -n argocd -f -

echo "== waiting for the server"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

echo "== root app"
kubectl apply -f bootstrap/root-app.yaml

echo
echo "Argo CD is up. Until the Tailscale operator has synced (it needs the"
echo "sealed OAuth secret — see secrets/README.md), reach the UI with:"
echo
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:80   # http://localhost:8080"
echo "  user: admin"
echo "  pass: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
echo "Then: https://argocd.tail3659a6.ts.net (tailnet only, no Funnel)."
