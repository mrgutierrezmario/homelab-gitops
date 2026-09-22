#!/bin/bash
# Install k3s on a Linux box that is not the Lima VM (a spare laptop, a mini
# PC — DESIGN.md §3 "Phase B"). bootstrap/lima.yaml runs the same lines for
# the VM; keep the two in step.
#
#   curl -sfL https://raw.githubusercontent.com/mrgutierrezmario/homelab-gitops/main/bootstrap/k3s.sh | sudo bash
#
# Flags:
#   --write-kubeconfig-mode 644   the login user can run kubectl without sudo
#   --tls-san host.docker.internal
#                                 the API cert is also valid for the name the
#                                 dev container uses to reach the Mac
#   --disable traefik             ingress is the Tailscale operator
#                                 (DESIGN.md §3); Traefik would sit idle at
#                                 ~150 MB. The local-path storage class,
#                                 CoreDNS and metrics-server stay.
set -euo pipefail

if command -v k3s >/dev/null; then
  echo "k3s already installed: $(k3s --version | head -1)"
  exit 0
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - \
  --write-kubeconfig-mode 644 \
  --tls-san host.docker.internal \
  --disable traefik

echo
echo "kubeconfig: /etc/rancher/k3s/k3s.yaml"
echo "next:       bootstrap/argocd.sh from a machine that can reach this API"
