#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/load-packer-vars.sh"

VM_NAME="${1:-${VM_NAME:-$(default_vm_name_from_pkrvars)}}"
: "${GUEST_PASSWORD:=$(get_pkr_var packer_admin_password)}"
: "${ZERO_FILL_TIMEOUT_PER_MOUNT:=600}"
: "${FSTRIM_TIMEOUT:=300}"

export_govc_from_pkrvars

log() {
  printf '[zerofill-vm] %s\n' "$*" >&2
}

run_guest_command() {
  local output
  if output="$(govc guest.run -vm "${VM_NAME}" -l "root:${GUEST_PASSWORD}" -- "$@" 2>&1)"; then
    [[ -n "${output}" ]] && log "${output}"
    return 0
  fi

  log "guest.run failed: ${output}"
  return 1
}

wait_for_guest_operations() {
  local status_json
  local guest_ops_ready

  for _ in $(seq 1 180); do
    if ! status_json="$(govc vm.info -json "${VM_NAME}" 2>/dev/null)"; then
      sleep 5
      continue
    fi

    guest_ops_ready="$(printf '%s' "${status_json}" | jq -r '.virtualMachines[0].guest.guestOperationsReady // empty')"
    if [[ "${guest_ops_ready}" == "true" ]]; then
      return 0
    fi

    sleep 5
  done

  return 1
}

ZERO_FILL_CMD="$(cat <<EOF
set -euo pipefail
echo "[guest] zero-fill starting"

mapfile -t mountpoints < <(
  zfs list -H -o mountpoint -r boot-pool -t filesystem | awk '$1 ~ "^/" {print $1}'
)

for mountpoint in "${mountpoints[@]}"; do
  [[ -z "\${mountpoint}" ]] && continue
  [[ ! -d "\${mountpoint}" ]] && continue
  [[ ! -w "\${mountpoint}" ]] && continue

  zero_file="\${mountpoint%/}/.truenas-lab-zerofill"
  echo "[guest] zero-filling \${mountpoint}"
  rm -f "\${zero_file}"
  timeout "${ZERO_FILL_TIMEOUT_PER_MOUNT}" dd if=/dev/zero of="\${zero_file}" bs=1M status=none || true
  sync
  rm -f "\${zero_file}"
  sync
done

if command -v fstrim >/dev/null 2>&1; then
  echo "[guest] running fstrim"
  timeout "${FSTRIM_TIMEOUT}" fstrim -av || true
fi

echo "[guest] zero-fill completed"
EOF
)"

log "powering on ${VM_NAME} for zero-fill"
govc vm.power -on "${VM_NAME}" >/dev/null 2>&1 || true

log "waiting for guest operations on ${VM_NAME} as root"
if ! wait_for_guest_operations; then
  echo "Guest operations did not become ready for root on ${VM_NAME}" >&2
  exit 1
fi

log "running zero-fill inside ${VM_NAME}"
run_guest_command /bin/bash -lc "${ZERO_FILL_CMD}"

log "zero-fill completed on ${VM_NAME}"
