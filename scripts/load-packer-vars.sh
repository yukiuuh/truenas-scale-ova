#!/usr/bin/env bash
set -euo pipefail

: "${PKR_VAR_FILE:=packer/truenas.auto.pkrvars.hcl}"

if [[ ! -f "${PKR_VAR_FILE}" ]]; then
  echo "packer var file not found: ${PKR_VAR_FILE}" >&2
  exit 1
fi

get_pkr_var() {
  local key="$1"
  local line

  line="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$/\1/p" "${PKR_VAR_FILE}" | head -n 1)"
  if [[ -z "${line}" ]]; then
    return 1
  fi

  printf '%s\n' "${line}"
}

maybe_get_pkr_var() {
  local key="$1"
  get_pkr_var "${key}" 2>/dev/null || true
}

export_govc_from_pkrvars() {
  export GOVC_URL="${GOVC_URL:-https://$(get_pkr_var vcenter_server)}"
  export GOVC_USERNAME="${GOVC_USERNAME:-$(get_pkr_var vcenter_username)}"
  export GOVC_PASSWORD="${GOVC_PASSWORD:-$(get_pkr_var vcenter_password)}"
  export GOVC_DATACENTER="${GOVC_DATACENTER:-$(get_pkr_var vsphere_datacenter)}"
  export GOVC_INSECURE="${GOVC_INSECURE:-1}"
  export GOVC_DATASTORE="${GOVC_DATASTORE:-$(maybe_get_pkr_var vsphere_datastore)}"
  export GOVC_RESOURCE_POOL="${GOVC_RESOURCE_POOL:-$(maybe_get_pkr_var vsphere_resource_pool)}"
  export GOVC_FOLDER="${GOVC_FOLDER:-$(maybe_get_pkr_var vsphere_folder)}"
}

default_vm_name_from_pkrvars() {
  get_pkr_var vm_name
}
