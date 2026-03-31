#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/opt/truenas-lab"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="truenas-lab-firstboot.service"

mkdir -p "${INSTALL_ROOT}"
install -m 0755 "${BASE_DIR}/truenas-lab-firstboot.py" "${INSTALL_ROOT}/truenas-lab-firstboot.py"
install -m 0644 "${BASE_DIR}/${SERVICE_NAME}" "${SYSTEMD_DIR}/${SERVICE_NAME}"

mkdir -p /var/lib/truenas-lab

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

# Accept the EULA during image baking so first boot can focus on OVF-driven config.
if midclt call truenas.is_eula_accepted >/dev/null 2>&1; then
  if [[ "$(midclt call truenas.is_eula_accepted)" != "true" ]]; then
    midclt call truenas.accept_eula || true
  fi
fi
