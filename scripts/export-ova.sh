#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT_DIR}/scripts/load-packer-vars.sh"
VM_NAME="${1:-${VM_NAME:-$(default_vm_name_from_pkrvars)}}"
OUTPUT_DIR="$(realpath -m "${2:-${OVA_OUTPUT_DIR:-dist}}")"
EXPORT_DIR="${OUTPUT_DIR}/${VM_NAME}.export"
OVA_PATH="${OUTPUT_DIR}/${VM_NAME}.ova"

mkdir -p "${OUTPUT_DIR}"
rm -rf "${EXPORT_DIR}"
rm -f "${OVA_PATH}"

echo "[export-ova] powering off ${VM_NAME}"
govc vm.power -off -force "${VM_NAME}" >/dev/null 2>&1 || true

echo "[export-ova] exporting OVF for ${VM_NAME}"
mkdir -p "${EXPORT_DIR}"
pushd "${EXPORT_DIR}" >/dev/null
govc export.ovf -vm "${VM_NAME}" .
popd >/dev/null

OVF_PATH="$(find "${EXPORT_DIR}" -type f -name '*.ovf' | head -n 1)"
if [[ -z "${OVF_PATH}" ]]; then
  echo "could not find exported OVF in ${EXPORT_DIR}" >&2
  exit 1
fi

cp "${OVF_PATH}" "${OVF_PATH}.original"

python3 "${ROOT_DIR}/scripts/inject-ovf-properties.py" "${OVF_PATH}"

OVF_DIR="$(dirname "${OVF_PATH}")"

pushd "${OVF_DIR}" >/dev/null
tar --format=ustar -cf "${OVA_PATH}" ./*.ovf ./*.vmdk 2>/dev/null || tar --format=ustar -cf "${OVA_PATH}" ./*.ovf ./*.nvram ./*.vmdk
popd >/dev/null

echo "OVA exported to ${OVA_PATH}"
