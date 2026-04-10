#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/load-packer-vars.sh"

OVA_PATH="${1:-}"
if [[ -z "${OVA_PATH}" ]]; then
  echo "usage: $0 <ova-path>" >&2
  exit 1
fi

if [[ ! -f "${OVA_PATH}" ]]; then
  echo "ova not found: ${OVA_PATH}" >&2
  exit 1
fi

export_govc_from_pkrvars

VM_NAME="${VM_NAME:-$(default_vm_name_from_pkrvars)}"
DATASTORE="${DATASTORE:-$(get_pkr_var vsphere_datastore)}"
NETWORK="${NETWORK:-$(get_pkr_var vsphere_network)}"
NETWORKS="${NETWORKS:-}"
RESOURCE_POOL="${RESOURCE_POOL:-$(maybe_get_pkr_var vsphere_resource_pool)}"
FOLDER="${FOLDER:-$(maybe_get_pkr_var vsphere_folder)}"
HOST_SYSTEM="${HOST_SYSTEM:-$(maybe_get_pkr_var vsphere_host)}"
DISK_PROVISIONING="${DISK_PROVISIONING:-thin}"
POWER_ON="${POWER_ON:-0}"
DATA_DISK_SIZES_GB="${DATA_DISK_SIZES_GB:-}"
OVF_PROPERTIES_FILE="${OVF_PROPERTIES_FILE:-}"
INIT_SCRIPT_PATH="${INIT_SCRIPT_PATH:-}"
REPLACE_VM="${REPLACE_VM:-1}"

if [[ -z "${DATASTORE}" ]]; then
  echo "DATASTORE is required" >&2
  exit 1
fi

if [[ -z "${NETWORK}" ]]; then
  echo "NETWORK is required" >&2
  exit 1
fi

log() {
  printf '[deploy-ova] %s\n' "$*" >&2
}

wait_for_vm_power_state() {
  local vm_path="${1}"
  local expected_state="${2}"
  local deadline=$((SECONDS + 120))

  while (( SECONDS < deadline )); do
    local current_state
    current_state="$(govc object.collect -s "${vm_path}" runtime.powerState 2>/dev/null || true)"
    if [[ "${current_state}" == "${expected_state}" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for ${vm_path} to reach power state ${expected_state}" >&2
  return 1
}

EXISTING_VM_PATHS="$(govc find -type m -name "${VM_NAME}" 2>/dev/null || true)"
if [[ -n "${EXISTING_VM_PATHS}" ]]; then
  if [[ "${REPLACE_VM}" != "1" ]]; then
    echo "VM already exists: ${VM_NAME} (set REPLACE_VM=1 to replace it)" >&2
    exit 1
  fi
  log "existing VM ${VM_NAME} found, replacing it"
  govc vm.power -off -force "${VM_NAME}" >/dev/null 2>&1 || true
  while IFS= read -r vm_path; do
    [[ -z "${vm_path}" ]] && continue
    wait_for_vm_power_state "${vm_path}" "poweredOff" || true
    log "destroying existing VM ${vm_path}"
    govc object.destroy "${vm_path}"
  done <<< "${EXISTING_VM_PATHS}"
fi

SPEC_FILE="$(mktemp)"
trap 'rm -f "${SPEC_FILE}"' EXIT

log "generating import spec from ${OVA_PATH}"
govc import.spec "${OVA_PATH}" > "${SPEC_FILE}"

log "customizing import spec"
jq \
  --arg name "${VM_NAME}" \
  --arg network "${NETWORK}" \
  --arg disk_provisioning "${DISK_PROVISIONING}" \
  '
  .Name = $name
  | .DiskProvisioning = $disk_provisioning
  | .NetworkMapping |= map(.Network = $network)
  | .PropertyMapping |= map(.)
  | .Deployment = (.Deployment // "")
  | .MarkAsTemplate = false
  | .InjectOvfEnv = true
  | .PowerOn = false
  | .WaitForIP = false
  | .IPAllocationPolicy = (.IPAllocationPolicy // "dhcpPolicy")
  | .IPProtocol = (.IPProtocol // "IPv4")
  | .NetworkMapping |= map(.Network = $network)
  | .PropertyMapping |= map(.)
  ' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"

if [[ -n "${NETWORKS}" ]]; then
  IFS=',' read -r -a network_list <<< "${NETWORKS}"
  jq --argjson nets "$(printf '%s\n' "${network_list[@]}" | jq -R . | jq -s .)" '
    .NetworkMapping |= to_entries | map(
      if .key < ($nets | length) then
        .value.Network = ($nets[.key] | sub("^\\s+"; "") | sub("\\s+$"; ""))
      else
        .
      end
    ) | map(.value) // .
  ' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
  mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"
fi

if [[ -n "${RESOURCE_POOL}" ]]; then
  jq --arg rp "${RESOURCE_POOL}" '.ResourcePool = $rp' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
  mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"
fi

if [[ -n "${FOLDER}" ]]; then
  jq --arg folder "${FOLDER}" '.Folder = $folder' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
  mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"
fi

if [[ -n "${HOST_SYSTEM}" ]]; then
  jq --arg host "${HOST_SYSTEM}" '.HostSystem = $host' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
  mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"
fi

if [[ -n "${OVF_PROPERTIES_FILE}" ]]; then
  if [[ ! -f "${OVF_PROPERTIES_FILE}" ]]; then
    echo "OVF properties file not found: ${OVF_PROPERTIES_FILE}" >&2
    exit 1
  fi

  log "applying OVF properties from ${OVF_PROPERTIES_FILE}"
  jq --slurpfile props "${OVF_PROPERTIES_FILE}" '
    .PropertyMapping |= map(
      . as $item
      | ($props[0][] | select(.key == $item.Key) | .value) as $matched
      | if $matched == null then $item else ($item + {Value: $matched}) end
    )
  ' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
  mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"
fi

if [[ -n "${INIT_SCRIPT_PATH}" ]]; then
  if [[ ! -f "${INIT_SCRIPT_PATH}" ]]; then
    echo "init script not found: ${INIT_SCRIPT_PATH}" >&2
    exit 1
  fi

  log "injecting init script from ${INIT_SCRIPT_PATH}"
  INIT_SCRIPT_B64="$(base64 -w0 "${INIT_SCRIPT_PATH}")"
  jq --arg script "${INIT_SCRIPT_B64}" '
    if any(.PropertyMapping[]; .Key == "truenas.init_script") then
      .PropertyMapping |= map(if .Key == "truenas.init_script" then . + {Value: $script} else . end)
    else
      .PropertyMapping += [{"Key":"truenas.init_script","Value":$script}]
    end
  ' "${SPEC_FILE}" > "${SPEC_FILE}.tmp"
  mv "${SPEC_FILE}.tmp" "${SPEC_FILE}"
fi

log "importing OVA as ${VM_NAME}"
IMPORT_ARGS=(
  -options="${SPEC_FILE}"
  -name "${VM_NAME}"
  -ds "${DATASTORE}"
  -net "${NETWORK}"
)

if [[ -n "${RESOURCE_POOL}" ]]; then
  IMPORT_ARGS+=(-pool "${RESOURCE_POOL}")
fi

if [[ -n "${FOLDER}" ]]; then
  IMPORT_ARGS+=(-folder "${FOLDER}")
fi

if [[ -n "${HOST_SYSTEM}" ]]; then
  IMPORT_ARGS+=(-host "${HOST_SYSTEM}")
fi

govc import.ova "${IMPORT_ARGS[@]}" "${OVA_PATH}"

if [[ -n "${DATA_DISK_SIZES_GB}" ]]; then
  IFS=',' read -r -a disk_sizes <<< "${DATA_DISK_SIZES_GB}"
  disk_index=1
  for size_gb in "${disk_sizes[@]}"; do
    size_gb="$(printf '%s' "${size_gb}" | xargs)"
    [[ -z "${size_gb}" ]] && continue
    log "adding data disk ${size_gb}G to ${VM_NAME}"
    disk_name="${VM_NAME}/data-disk-${disk_index}.vmdk"
    govc vm.disk.create -vm "${VM_NAME}" -name "${disk_name}" -size "${size_gb}G" -ds "${DATASTORE}"
    disk_index=$((disk_index + 1))
  done
fi

if [[ "${POWER_ON}" == "1" ]]; then
  log "powering on ${VM_NAME}"
  govc vm.power -on "${VM_NAME}"
fi

log "deploy completed for ${VM_NAME}"
