#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/load-packer-vars.sh"
VM_NAME="${1:-${VM_NAME:-$(default_vm_name_from_pkrvars)}}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
GUEST_TMP_DIR="${GUEST_TMP_DIR:-/var/tmp/truenas-lab}"
GUEST_PAYLOAD_TGZ="${GUEST_TMP_DIR}/guest-payload.tgz"

: "${GUEST_USER:=truenas_admin}"
: "${GUEST_PASSWORD:?set GUEST_PASSWORD to the TrueNAS password created during install}"

export_govc_from_pkrvars

log() {
  printf '[customize-vm] %s\n' "$*" >&2
}

run_guest_command() {
  local user="$1"
  local password="$2"
  shift 2

  local output
  if output="$(govc guest.run -vm "${VM_NAME}" -l "${user}:${password}" -- "$@" 2>&1)"; then
    return 0
  fi

  log "guest.run failed for ${user}: ${output}"
  return 1
}

wait_for_guest_operations() {
  local user="$1"
  local status_json
  local guest_ops_ready
  local tools_status

  for _ in $(seq 1 180); do
    if ! status_json="$(govc vm.info -json "${VM_NAME}" 2>/dev/null)"; then
      log "vm.info is not available yet for ${VM_NAME}"
      sleep 5
      continue
    fi

    guest_ops_ready="$(printf '%s' "${status_json}" | jq -r '.virtualMachines[0].guest.guestOperationsReady // empty')"
    tools_status="$(printf '%s' "${status_json}" | jq -r '.virtualMachines[0].guest.toolsRunningStatus // empty')"
    log "tools=${tools_status:-unknown} guestOperationsReady=${guest_ops_ready:-unknown} auth_user=${user}"

    if [[ "${guest_ops_ready}" == "true" ]]; then
      log "guest operations is ready for ${user}"
      return 0
    fi

    sleep 5
  done

  return 1
}

tar -C "${ROOT_DIR}" -czf "${TMP_DIR}/guest-payload.tgz" guest

log "powering on ${VM_NAME}"
govc vm.power -on "${VM_NAME}" >/dev/null 2>&1 || true

log "waiting for guest operations on ${VM_NAME} as ${GUEST_USER}"
if ! wait_for_guest_operations "${GUEST_USER}"; then
  echo "Guest operations did not become ready for ${GUEST_USER} on ${VM_NAME}" >&2
  exit 1
fi

ROOT_BOOTSTRAP_CMD='
set -euo pipefail
python3 -c '"'"'
import json
import subprocess

def midclt(*args):
    result = subprocess.run(["midclt", "call", *args], check=True, capture_output=True, text=True)
    return result.stdout.strip()

users = json.loads(midclt("user.query"))
root_user = next((user for user in users if user.get("username") == "root"), None)
if root_user is None:
    raise SystemExit("root user was not found")

payload = {
    "password": "'"${GUEST_PASSWORD}"'",
    "password_disabled": False,
    "ssh_password_enabled": True,
    "locked": False,
}
midclt("user.update", str(root_user["id"]), json.dumps(payload))
'"'"'
'

log "enabling root password via midclt as ${GUEST_USER}"
run_guest_command "${GUEST_USER}" "${GUEST_PASSWORD}" /bin/bash -lc "${ROOT_BOOTSTRAP_CMD}"

log "waiting for guest operations on ${VM_NAME} as root"
if ! wait_for_guest_operations "root"; then
  echo "Guest operations did not become ready for root on ${VM_NAME}" >&2
  exit 1
fi

log "creating guest temp directory ${GUEST_TMP_DIR} as root"
govc guest.mkdir -vm "${VM_NAME}" -l "root:${GUEST_PASSWORD}" -p "${GUEST_TMP_DIR}"

log "uploading guest payload to ${GUEST_PAYLOAD_TGZ} as root"
govc guest.upload -vm "${VM_NAME}" -l "root:${GUEST_PASSWORD}" \
  "${TMP_DIR}/guest-payload.tgz" "${GUEST_PAYLOAD_TGZ}"

ROOT_INSTALL_CMD="$(cat <<EOF
set -euo pipefail
if ! touch /opt/.truenas-lab-write-test 2>/dev/null; then
  if ! command -v install-dev-tools >/dev/null 2>&1; then
    echo "install-dev-tools is not available and /opt is read-only" >&2
    exit 1
  fi

  echo "enabling developer mode tooling so /opt and /etc become writable" >&2
  install-dev-tools
else
  rm -f /opt/.truenas-lab-write-test
fi

rm -rf ${GUEST_TMP_DIR}/guest-payload
mkdir -p ${GUEST_TMP_DIR}/guest-payload
tar -C ${GUEST_TMP_DIR}/guest-payload -xzf ${GUEST_PAYLOAD_TGZ}
${GUEST_TMP_DIR}/guest-payload/guest/install-guest-customization.sh

EOF
)"

log "running guest customization script as root"
run_guest_command "root" "${GUEST_PASSWORD}" /bin/bash -lc "${ROOT_INSTALL_CMD}"

log "customization payload installed on ${VM_NAME}"
