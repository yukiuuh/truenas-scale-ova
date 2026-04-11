#!/usr/bin/env bash
set -euo pipefail

# Tunables. Override via environment or edit these defaults before base64-encoding.
ENABLE_ISCSI="${ENABLE_ISCSI:-1}"
ENABLE_NFS="${ENABLE_NFS:-1}"
ENABLE_VCD_TRANSFER_NFS="${ENABLE_VCD_TRANSFER_NFS:-1}"
ENABLE_WEBUI_SESSION_TIMEOUT="${ENABLE_WEBUI_SESSION_TIMEOUT:-1}"

POOL_NAME="${POOL_NAME:-}"
NIC1_IP="${NIC1_IP:-}"
NIC2_IP="${NIC2_IP:-}"
SFTP_USER="${SFTP_USER:-truenas_admin}"

WEBUI_SESSION_TIMEOUT_SECONDS="${WEBUI_SESSION_TIMEOUT_SECONDS:-2147482}"
WEBUI_SESSION_TIMEOUT_USERS="${WEBUI_SESSION_TIMEOUT_USERS:-truenas_admin}"

ZVOL1_NAME="${ZVOL1_NAME:-iscsi01}"
ZVOL2_NAME="${ZVOL2_NAME:-iscsi02}"
ZVOL1_SIZE_GIB="${ZVOL1_SIZE_GIB:-}"
ZVOL2_SIZE_GIB="${ZVOL2_SIZE_GIB:-}"
ZVOL_DEFAULT_PERCENT="${ZVOL_DEFAULT_PERCENT:-100}"
ZVOL_VOLBLOCKSIZE="${ZVOL_VOLBLOCKSIZE:-128K}"
ZVOL_SPARSE="${ZVOL_SPARSE:-1}"
ZVOL_COMPRESSION="${ZVOL_COMPRESSION:-ZSTD}"
FORCE_SIZE="${FORCE_SIZE:-1}"

# ZVOL_VOLBLOCKSIZE is the ZFS backing allocation size. The iSCSI extent
# blocksize below is the initiator-facing logical sector size for ESXi/VMFS.
ISCSI_EXTENT_BLOCKSIZE="${ISCSI_EXTENT_BLOCKSIZE:-512}"
# Maps to the TrueNAS UI checkbox "Disable Physical Block Size Reporting".
ISCSI_EXTENT_DISABLE_PHYSICAL_BLOCKSIZE_REPORTING="${ISCSI_EXTENT_DISABLE_PHYSICAL_BLOCKSIZE_REPORTING:-1}"

NFS_DATASET_NAME="${NFS_DATASET_NAME:-share01}"
NFS_RECORDSIZE="${NFS_RECORDSIZE:-1M}"
NFS_COMPRESSION="${NFS_COMPRESSION:-ZSTD}"
NFS_NETWORKS="${NFS_NETWORKS:-}"
NFS_MAPROOT_USER="${NFS_MAPROOT_USER:-root}"
NFS_MAPROOT_GROUP="${NFS_MAPROOT_GROUP:-wheel}"
NFS_MAPALL_USER="${NFS_MAPALL_USER:-}"
NFS_MAPALL_GROUP="${NFS_MAPALL_GROUP:-}"

VCD_TRANSFER_DATASET_NAME="${VCD_TRANSFER_DATASET_NAME:-vcd}"
VCD_TRANSFER_NETWORKS="${VCD_TRANSFER_NETWORKS:-}"
VCD_TRANSFER_RECORDSIZE="${VCD_TRANSFER_RECORDSIZE:-1M}"
VCD_TRANSFER_COMPRESSION="${VCD_TRANSFER_COMPRESSION:-ZSTD}"
VCD_TRANSFER_MAPALL_USER="${VCD_TRANSFER_MAPALL_USER:-root}"
VCD_TRANSFER_MAPALL_GROUP="${VCD_TRANSFER_MAPALL_GROUP:-root}"

log() {
  printf '[init-script] %s\n' "$*" >&2
}

PS4='+ [init-script] ${LINENO}: '
set -x
trap 'rc=$?; echo "[init-script] failed at line ${LINENO}: ${BASH_COMMAND} (rc=${rc})" >&2; exit ${rc}' ERR

midclt_json_retry() {
  local timeout="${MIDCLT_JSON_TIMEOUT:-60}"
  local interval="${MIDCLT_JSON_INTERVAL:-2}"
  local deadline=$((SECONDS + timeout))
  local stdout_file=""
  local stderr_file=""
  local output=""
  local rc=0
  local stderr_text=""

  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  while (( SECONDS < deadline )); do
    if midclt call "$@" >"${stdout_file}" 2>"${stderr_file}"; then
      rc=0
    else
      rc=$?
    fi
    output="$(cat "${stdout_file}")"
    if [[ -n "${output}" ]]; then
      rm -f "${stdout_file}" "${stderr_file}"
      printf '%s\n' "${output}"
      return 0
    fi
    stderr_text="$(tr '\n' ' ' < "${stderr_file}")"
    if (( rc != 0 )); then
      log "midclt call $* failed rc=${rc}: ${stderr_text}"
    else
      log "midclt call $* returned empty stdout"
    fi
    sleep "${interval}"
  done

  stderr_text="$(tr '\n' ' ' < "${stderr_file}")"
  rm -f "${stdout_file}" "${stderr_file}"
  echo "timed out waiting for non-empty JSON output from midclt call $*: ${stderr_text}" >&2
  return 1
}

wait_for_job_chain() {
  local job_id="${1}"
  local timeout="${2:-900}"
  local _deadline=$((SECONDS + timeout))
  if (( SECONDS >= _deadline )); then
    echo "timed out waiting for job ${job_id}" >&2
    return 1
  fi

  local result
  result="$(midclt call core.job_wait "${job_id}")"
  log "job_wait for ${job_id} returned: ${result}"
  printf '%s\n' "${result}"
  return 0
}

wait_for_resource() {
  local description="${1}"
  local probe_cmd="${2}"
  local timeout="${3:-120}"
  local interval="${4:-2}"
  local deadline=$((SECONDS + timeout))

  while (( SECONDS < deadline )); do
    if eval "${probe_cmd}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
  done

  echo "timed out waiting for ${description}" >&2
  return 1
}

service_id() {
  local service_name="${1}"
  local json_input
  json_input="$(midclt_json_retry service.query)"
  printf '%s\n' "${json_input}" | jq -er --arg service_name "${service_name}" '
    map(select(.service == $service_name) | (.id // $service_name)) | first
  '
}

require_value() {
  local description="${1}"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    echo "missing required value: ${description}" >&2
    return 1
  fi
}

json_id() {
  jq -er '.id'
}

default_pool_name() {
  local json_input
  json_input="$(midclt_json_retry pool.query)"
  local pool_count
  pool_count="$(printf '%s\n' "${json_input}" | jq '[.[] | select(.name != "boot-pool")] | length')"
  if [[ "${pool_count}" == "1" ]]; then
    printf '%s\n' "${json_input}" | jq -r '.[] | select(.name != "boot-pool") | .name'
    return 0
  fi
  if [[ "${pool_count}" == "0" ]]; then
    echo "no non-boot pool found; set POOL_NAME explicitly" >&2
    return 1
  fi
  local names
  names="$(printf '%s\n' "${json_input}" | jq -r '[.[] | select(.name != "boot-pool") | .name] | join(", ")')"
  echo "multiple non-boot pools found (${names}); set POOL_NAME explicitly" >&2
  return 1
}

default_portal_ips() {
  local json_input
  json_input="$(midclt_json_retry interface.query)"
  local -a candidates=()
  mapfile -t candidates < <(
    printf '%s\n' "${json_input}" | jq -r '
      sort_by(.id // "")[]
      | select((.name // "") != "lo" and (.name // "") != "docker0")
      | (.state.aliases // [])
      | map(select(.type == "INET") | .address)
      | .[0] // empty
    '
  )
  if (( ${#candidates[@]} >= 3 )); then
    printf '%s\n%s\n' "${candidates[1]}" "${candidates[2]}"
    return 0
  fi
  if (( ${#candidates[@]} == 2 )); then
    printf '%s\n%s\n' "${candidates[0]}" "${candidates[1]}"
    return 0
  fi
  echo "could not infer two portal IPs; set NIC1_IP and NIC2_IP explicitly" >&2
  return 1
}

default_zvol_size_gib() {
  local pool_name="${1}"
  local percent="${2}"
  local size_bytes
  size_bytes="$(zpool list -Hp -o size "${pool_name}")"
  local size_gib=$(( (size_bytes * percent / 100) / (1024 * 1024 * 1024) ))
  if (( size_gib < 1 )); then
    size_gib=1
  fi
  printf '%s\n' "${size_gib}"
}

ensure_service_started() {
  local service_name="${1}"
  local sid
  sid="$(service_id "${service_name}")"
  midclt call service.update "${sid}" "{\"enable\": true}" >/dev/null
  midclt call service.control "START" "${service_name}" '{"silent": true, "timeout": 120}' >/dev/null
}

effective_webui_session_timeout() {
  local requested_seconds="${1}"
  local max_seconds=2147482
  local aal_json=""
  local aal=""
  local security_json=""
  local enable_gpos_stig=""

  # Middleware caps reconnect-token TTL by the current authenticator assurance
  # level. Keep the UI timeout at or below that cap to avoid early token expiry.
  aal_json="$(midclt call auth.get_authenticator_assurance_level 2>/dev/null || true)"
  aal="$(printf '%s\n' "${aal_json}" | jq -r 'if type == "string" then . else empty end' 2>/dev/null || true)"

  if [[ -z "${aal}" ]]; then
    security_json="$(midclt call system.security.config 2>/dev/null || true)"
    enable_gpos_stig="$(printf '%s\n' "${security_json}" | jq -r '.enable_gpos_stig // empty' 2>/dev/null || true)"
    if [[ "${enable_gpos_stig}" == "true" ]]; then
      aal="LEVEL_2"
    fi
  fi

  case "${aal}" in
    LEVEL_1)
      max_seconds=2147482
      ;;
    LEVEL_2)
      max_seconds=43200
      ;;
    LEVEL_3)
      max_seconds=780
      ;;
  esac

  if (( requested_seconds > max_seconds )); then
    log "capping Web UI session timeout from ${requested_seconds} to ${max_seconds} seconds for ${aal:-unknown AAL}"
    printf '%s\n' "${max_seconds}"
    return
  fi

  printf '%s\n' "${requested_seconds}"
}

ensure_webui_session_timeout() {
  local timeout_seconds="${1}"
  local users_csv="${2}"

  if ! [[ "${timeout_seconds}" =~ ^[0-9]+$ ]]; then
    echo "WEBUI_SESSION_TIMEOUT_SECONDS must be an integer number of seconds" >&2
    return 1
  fi
  if (( timeout_seconds < 30 || timeout_seconds > 2147482 )); then
    echo "WEBUI_SESSION_TIMEOUT_SECONDS must be between 30 and 2147482 seconds" >&2
    return 1
  fi

  timeout_seconds="$(effective_webui_session_timeout "${timeout_seconds}")"

  local users_json
  users_json="$(midclt_json_retry user.query)"

  local -a usernames=()
  mapfile -t usernames < <(
    printf '%s\n' "${users_csv}" |
      tr ',' '\n' |
      awk '{$1=$1}; NF {print}'
  )

  local username
  for username in "${usernames[@]}"; do
    local uid
    uid="$(printf '%s\n' "${users_json}" | jq -er --arg username "${username}" '
      first(.[] | select(.username == $username) | .uid) // empty
    ' 2>/dev/null || true)"
    if [[ -z "${uid}" ]]; then
      log "skipping Web UI session timeout for missing user ${username}"
      continue
    fi

    # auth.set_attribute updates the session owner. This root init script has no
    # browser session, so update the WebUI preference row for the configured login.
    local attribute_rows
    attribute_rows="$(midclt_json_retry datastore.query account.bsdusers_webui_attribute "[[\"uid\",\"=\",${uid}]]")"

    local existing_id
    existing_id="$(printf '%s\n' "${attribute_rows}" | jq -r '.[0].id // empty')"

    local updated_attributes
    updated_attributes="$(printf '%s\n' "${attribute_rows}" | jq --argjson lifetime "${timeout_seconds}" '
      (.[0].attributes // {}) as $attributes
      | $attributes + {
          preferences: (
            (($attributes.preferences // {}) | if type == "object" then . else {} end)
            + {lifetime: $lifetime}
          )
        }
    ')"

    if [[ -n "${existing_id}" ]]; then
      midclt call datastore.update account.bsdusers_webui_attribute "${existing_id}" \
        "$(jq -cn --argjson attributes "${updated_attributes}" '{attributes: $attributes}')" >/dev/null
    else
      midclt call datastore.insert account.bsdusers_webui_attribute \
        "$(jq -cn --argjson uid "${uid}" --argjson attributes "${updated_attributes}" '{uid: $uid, attributes: $attributes}')" >/dev/null
    fi

    log "set Web UI session timeout for ${username} to ${timeout_seconds} seconds"
  done
}

ensure_filesystem_dataset() {
  local dataset="${1}"
  local share_type="${2}"
  local sync_mode="${3}"
  local recordsize="${4}"
  local compression="${5}"
  if zfs list -H "${dataset}" >/dev/null 2>&1; then
    log "dataset already exists: ${dataset}"
    return
  fi

  local create_result
  create_result="$(midclt call pool.dataset.create "$(cat <<JSON
{"name":"${dataset}","type":"FILESYSTEM","share_type":"${share_type}","sync":"${sync_mode}","recordsize":"${recordsize}","compression":"${compression}","atime":"OFF","create_ancestors":true}
JSON
)"
  )"
  local maybe_job
  maybe_job="$(printf '%s\n' "${create_result}" | jq -r 'if type == "number" then . else empty end')"
  if [[ -n "${maybe_job}" ]]; then
    wait_for_job_chain "${maybe_job}" >/dev/null
  fi
  wait_for_resource "dataset ${dataset}" "zfs list -H '${dataset}'"
  log "created filesystem dataset ${dataset}"
}

ensure_zvol() {
  local dataset="${1}"
  local size_gib="${2}"
  local volblocksize="${3:-128K}"
  local bytes=$((size_gib * 1024 * 1024 * 1024))
  local sparse=false
  local force_size=false

  if zfs list -H "${dataset}" >/dev/null 2>&1; then
    log "zvol already exists: ${dataset}"
    return
  fi

  if [[ "${ZVOL_SPARSE}" == "1" ]]; then
    sparse=true
  fi

  if [[ "${FORCE_SIZE}" == "1" ]]; then
    force_size=true
  fi

  local create_result
  create_result="$(midclt call pool.dataset.create "$(cat <<JSON
{"name":"${dataset}","type":"VOLUME","volsize":${bytes},"volblocksize":"${volblocksize}","force_size":${force_size},"sparse":${sparse},"compression":"${ZVOL_COMPRESSION}","sync":"STANDARD","snapdev":"HIDDEN","create_ancestors":true}
JSON
)"
  )"
  local maybe_job
  maybe_job="$(printf '%s\n' "${create_result}" | jq -r 'if type == "number" then . else empty end')"
  if [[ -n "${maybe_job}" ]]; then
    wait_for_job_chain "${maybe_job}" >/dev/null
  fi
  wait_for_resource "zvol ${dataset}" "zfs list -H '${dataset}'"
  log "created zvol ${dataset} (${size_gib} GiB, volblocksize=${volblocksize}, sparse=${sparse}, force_size=${force_size}, compression=${ZVOL_COMPRESSION})"
}

find_iscsi_disk_choice() {
  local dataset="${1}"
  local json_input
  json_input="$(midclt_json_retry iscsi.extent.disk_choices)"
  printf '%s\n' "${json_input}" | jq -r --arg dataset "${dataset}" '
    to_entries[]
    | select(
        (.key | contains("zvol/" + $dataset) or contains("/dev/zvol/" + $dataset) or contains($dataset))
        or
        (.value | tostring | contains("zvol/" + $dataset) or contains("/dev/zvol/" + $dataset) or contains($dataset))
      )
    | .key
  ' | head -n1 | awk 'NF {print; found=1} END {exit(found ? 0 : 1)}'
}

iscsi_portal_id_by_ips() {
  local ip_a="${1}"
  local ip_b="${2}"
  local json_input
  json_input="$(midclt_json_retry iscsi.portal.query)"
  printf '%s\n' "${json_input}" | jq -er --arg ip_a "${ip_a}" --arg ip_b "${ip_b}" '
    first(.[] | select((((.listen // []) | map(.ip) | sort) == ([$ip_a, $ip_b] | sort))) | .id)
  '
}

iscsi_target_id_by_name() {
  local name="${1}"
  local json_input
  json_input="$(midclt_json_retry iscsi.target.query)"
  printf '%s\n' "${json_input}" | jq -er --arg name "${name}" 'first(.[] | select(.name == $name) | .id)'
}

iscsi_extent_id_by_name() {
  local name="${1}"
  local json_input
  json_input="$(midclt_json_retry iscsi.extent.query)"
  printf '%s\n' "${json_input}" | jq -er --arg name "${name}" 'first(.[] | select(.name == $name) | .id)'
}

iscsi_targetextent_exists() {
  local target_id="${1}"
  local extent_id="${2}"
  local json_input
  json_input="$(midclt_json_retry iscsi.targetextent.query)"
  printf '%s\n' "${json_input}" | jq -e --argjson target_id "${target_id}" --argjson extent_id "${extent_id}" '
    any(.[]; .target == $target_id and .extent == $extent_id)
  ' >/dev/null
}

nfs_share_id_by_path() {
  local share_path="${1}"
  local json_input
  json_input="$(midclt_json_retry sharing.nfs.query)"
  printf '%s\n' "${json_input}" | jq -er --arg share_path "${share_path}" 'first(.[] | select(.path == $share_path) | .id)'
}

nfs_share_exists_by_path() {
  local share_path="${1}"
  nfs_share_id_by_path "${share_path}" >/dev/null 2>&1
}

ensure_iscsi_portal() {
  local ip_a="${1}"
  local ip_b="${2}"

  local existing
  existing="$(iscsi_portal_id_by_ips "${ip_a}" "${ip_b}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    printf '%s\n' "${existing}"
    return
  fi

  local create_result
  create_result="$(midclt call iscsi.portal.create "$(cat <<JSON
{"listen":[{"ip":"${ip_a}"},{"ip":"${ip_b}"}]}
JSON
)"
  )"
  local created_id
  created_id="$(printf '%s\n' "${create_result}" | json_id)"
  require_value "created iSCSI portal id" "${created_id}"
  wait_for_resource "iSCSI portal ${ip_a},${ip_b}" "iscsi_portal_id_by_ips '${ip_a}' '${ip_b}'"
  printf '%s\n' "${created_id}"
}

ensure_iscsi_target() {
  local name="${1}"
  local alias="${2}"
  local portal_id="${3}"

  local existing
  existing="$(iscsi_target_id_by_name "${name}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    printf '%s\n' "${existing}"
    return
  fi

  local create_result
  create_result="$(midclt call iscsi.target.create "$(cat <<JSON
{"name":"${name}","alias":"${alias}","groups":[{"portal":${portal_id},"initiator":null,"authmethod":"NONE","auth":null}]}
JSON
)"
  )"
  local created_id
  created_id="$(printf '%s\n' "${create_result}" | json_id)"
  require_value "created iSCSI target id for ${name}" "${created_id}"
  wait_for_resource "iSCSI target ${name}" "iscsi_target_id_by_name '${name}'"
  printf '%s\n' "${created_id}"
}

ensure_iscsi_extent() {
  local name="${1}"
  local disk_choice="${2}"
  local blocksize="${3:-512}"
  local pblocksize=true

  local existing
  existing="$(iscsi_extent_id_by_name "${name}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    printf '%s\n' "${existing}"
    return
  fi

  case "${ISCSI_EXTENT_DISABLE_PHYSICAL_BLOCKSIZE_REPORTING,,}" in
    1|true|yes|on)
      pblocksize=true
      ;;
    0|false|no|off)
      pblocksize=false
      ;;
    *)
      echo "ISCSI_EXTENT_DISABLE_PHYSICAL_BLOCKSIZE_REPORTING must be 1/0 or true/false" >&2
      return 1
      ;;
  esac

  local create_result
  create_result="$(midclt call iscsi.extent.create "$(cat <<JSON
{"name":"${name}","type":"DISK","disk":"${disk_choice}","blocksize":${blocksize},"pblocksize":${pblocksize},"enabled":true}
JSON
)"
  )"
  local created_id
  created_id="$(printf '%s\n' "${create_result}" | json_id)"
  require_value "created iSCSI extent id for ${name}" "${created_id}"
  wait_for_resource "iSCSI extent ${name}" "iscsi_extent_id_by_name '${name}'"
  log "created iSCSI extent ${name} (blocksize=${blocksize}, disable_physical_block_size_reporting=${pblocksize})"
  printf '%s\n' "${created_id}"
}

ensure_target_extent() {
  local target_id="${1}"
  local extent_id="${2}"
  local lun_id="${3}"

  local existing
  existing="$(iscsi_targetextent_exists "${target_id}" "${extent_id}" && printf yes || true)"
  if [[ -n "${existing}" ]]; then
    log "target/extent association already exists: target=${target_id} extent=${extent_id}"
    return
  fi

  local create_result
  create_result="$(midclt call iscsi.targetextent.create "$(cat <<JSON
{"target":${target_id},"extent":${extent_id},"lunid":${lun_id}}
JSON
)"
  )"
  require_value "created iSCSI target/extent association" "$(printf '%s\n' "${create_result}" | json_id)"
  wait_for_resource "target/extent association ${target_id}/${extent_id}" "iscsi_targetextent_exists '${target_id}' '${extent_id}'"
  log "associated target ${target_id} with extent ${extent_id} as LUN ${lun_id}"
}

ensure_nfs_share() {
  local share_path="${1}"
  local comment="${2}"
  local networks_csv="${3}"

  local existing
  existing="$(nfs_share_id_by_path "${share_path}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    log "NFS share already exists for ${share_path}"
    return
  fi

  local networks_json
  networks_json="$(jq -Rn --arg raw "${networks_csv}" '$raw | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

  local maproot_user_json="null"
  local maproot_group_json="null"
  local mapall_user_json="null"
  local mapall_group_json="null"

  if [[ -n "${NFS_MAPROOT_USER}" ]]; then
    maproot_user_json="$(jq -Rn --arg v "${NFS_MAPROOT_USER}" '$v')"
  fi
  if [[ -n "${NFS_MAPROOT_GROUP}" ]]; then
    maproot_group_json="$(jq -Rn --arg v "${NFS_MAPROOT_GROUP}" '$v')"
  fi
  if [[ -n "${NFS_MAPALL_USER}" ]]; then
    mapall_user_json="$(jq -Rn --arg v "${NFS_MAPALL_USER}" '$v')"
  fi
  if [[ -n "${NFS_MAPALL_GROUP}" ]]; then
    mapall_group_json="$(jq -Rn --arg v "${NFS_MAPALL_GROUP}" '$v')"
  fi

  local create_result
  create_result="$(midclt call sharing.nfs.create "$(cat <<JSON
{"path":"${share_path}","comment":"${comment}","networks":${networks_json},"maproot_user":${maproot_user_json},"maproot_group":${maproot_group_json},"mapall_user":${mapall_user_json},"mapall_group":${mapall_group_json},"security":["SYS"],"enabled":true}
JSON
)"
  )"
  require_value "created NFS share id for ${share_path}" "$(printf '%s\n' "${create_result}" | json_id)"
  wait_for_resource "NFS share ${share_path}" "nfs_share_exists_by_path '${share_path}'"
  log "created NFS share for ${share_path}"
}

ensure_vcd_transfer_nfs_share() {
  local share_path="${1}"
  local networks_csv="${2}"

  local existing
  existing="$(nfs_share_id_by_path "${share_path}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    log "vCD transfer NFS share already exists for ${share_path}"
    return
  fi

  local networks_json
  networks_json="$(jq -Rn --arg raw "${networks_csv}" '$raw | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

  local mapall_user_json="null"
  local mapall_group_json="null"
  if [[ -n "${VCD_TRANSFER_MAPALL_USER}" ]]; then
    mapall_user_json="$(jq -Rn --arg v "${VCD_TRANSFER_MAPALL_USER}" '$v')"
  fi
  if [[ -n "${VCD_TRANSFER_MAPALL_GROUP}" ]]; then
    mapall_group_json="$(jq -Rn --arg v "${VCD_TRANSFER_MAPALL_GROUP}" '$v')"
  fi

  local create_result
  create_result="$(midclt call sharing.nfs.create "$(cat <<JSON
{"path":"${share_path}","comment":"VMware Cloud Director transfer share","networks":${networks_json},"mapall_user":${mapall_user_json},"mapall_group":${mapall_group_json},"security":["SYS"],"enabled":true}
JSON
)"
  )"
  require_value "created vCD transfer NFS share id for ${share_path}" "$(printf '%s\n' "${create_result}" | json_id)"
  wait_for_resource "vCD transfer NFS share ${share_path}" "nfs_share_exists_by_path '${share_path}'"
  log "created vCD transfer NFS share for ${share_path}"
}

POOL_NAME="${POOL_NAME:-$(default_pool_name)}"

if [[ -z "${NIC1_IP}" || -z "${NIC2_IP}" ]]; then
  mapfile -t DEFAULT_PORTAL_IPS < <(default_portal_ips)
  NIC1_IP="${NIC1_IP:-${DEFAULT_PORTAL_IPS[0]:-}}"
  NIC2_IP="${NIC2_IP:-${DEFAULT_PORTAL_IPS[1]:-}}"
fi

ZVOL1_SIZE_GIB="${ZVOL1_SIZE_GIB:-$(default_zvol_size_gib "${POOL_NAME}" "${ZVOL_DEFAULT_PERCENT}")}"
ZVOL2_SIZE_GIB="${ZVOL2_SIZE_GIB:-$(default_zvol_size_gib "${POOL_NAME}" "${ZVOL_DEFAULT_PERCENT}")}"

if [[ -z "${NIC1_IP}" || -z "${NIC2_IP}" ]]; then
  log "could not determine two portal IPs; set NIC1_IP and NIC2_IP explicitly"
  exit 1
fi

if ! zpool list -H "${POOL_NAME}" >/dev/null 2>&1; then
  log "pool does not exist: ${POOL_NAME}"
  exit 1
fi

log "using pool ${POOL_NAME} and iSCSI portal IPs ${NIC1_IP}, ${NIC2_IP}"

NEED_START_ISCSI=0
NEED_START_NFS=0
NEED_START_SSH=0

if [[ "${ENABLE_WEBUI_SESSION_TIMEOUT}" == "1" ]]; then
  ensure_webui_session_timeout "${WEBUI_SESSION_TIMEOUT_SECONDS}" "${WEBUI_SESSION_TIMEOUT_USERS}"
fi

if [[ "${ENABLE_ISCSI}" == "1" ]]; then
  ZVOL1_DATASET="${POOL_NAME}/${ZVOL1_NAME}"
  ZVOL2_DATASET="${POOL_NAME}/${ZVOL2_NAME}"

  ensure_zvol "${ZVOL1_DATASET}" "${ZVOL1_SIZE_GIB}" "${ZVOL_VOLBLOCKSIZE}"
  ensure_zvol "${ZVOL2_DATASET}" "${ZVOL2_SIZE_GIB}" "${ZVOL_VOLBLOCKSIZE}"

  PORTAL_ID="$(ensure_iscsi_portal "${NIC1_IP}" "${NIC2_IP}")"
  require_value "iSCSI portal id" "${PORTAL_ID}"
  log "using iSCSI portal id ${PORTAL_ID}"

  DISK1_CHOICE="$(find_iscsi_disk_choice "${ZVOL1_DATASET}")"
  DISK2_CHOICE="$(find_iscsi_disk_choice "${ZVOL2_DATASET}")"
  require_value "disk choice for ${ZVOL1_DATASET}" "${DISK1_CHOICE}"
  require_value "disk choice for ${ZVOL2_DATASET}" "${DISK2_CHOICE}"

  TARGET_PREFIX="${POOL_NAME//[^a-zA-Z0-9]/}"
  TARGET1_ID="$(ensure_iscsi_target "${TARGET_PREFIX}lun01" "${POOL_NAME}-lun01" "${PORTAL_ID}")"
  TARGET2_ID="$(ensure_iscsi_target "${TARGET_PREFIX}lun02" "${POOL_NAME}-lun02" "${PORTAL_ID}")"
  EXTENT1_ID="$(ensure_iscsi_extent "${TARGET_PREFIX}lun01" "${DISK1_CHOICE}" "${ISCSI_EXTENT_BLOCKSIZE}")"
  EXTENT2_ID="$(ensure_iscsi_extent "${TARGET_PREFIX}lun02" "${DISK2_CHOICE}" "${ISCSI_EXTENT_BLOCKSIZE}")"
  require_value "iSCSI target id ${TARGET_PREFIX}lun01" "${TARGET1_ID}"
  require_value "iSCSI target id ${TARGET_PREFIX}lun02" "${TARGET2_ID}"
  require_value "iSCSI extent id ${TARGET_PREFIX}lun01" "${EXTENT1_ID}"
  require_value "iSCSI extent id ${TARGET_PREFIX}lun02" "${EXTENT2_ID}"

  ensure_target_extent "${TARGET1_ID}" "${EXTENT1_ID}" 0
  ensure_target_extent "${TARGET2_ID}" "${EXTENT2_ID}" 1

  NEED_START_ISCSI=1
fi

if [[ "${ENABLE_NFS}" == "1" ]]; then
  ensure_filesystem_dataset "${POOL_NAME}/${NFS_DATASET_NAME}" NFS DISABLED "${NFS_RECORDSIZE}" "${NFS_COMPRESSION}"
  NFS_PATH="/mnt/${POOL_NAME}/${NFS_DATASET_NAME}"
  SFTP_GROUP="$(id -gn "${SFTP_USER}")"
  chown "${SFTP_USER}:${SFTP_GROUP}" "${NFS_PATH}"
  chmod 0770 "${NFS_PATH}"
  log "prepared ${NFS_PATH} for NFS and SFTP access by ${SFTP_USER}"

  ensure_nfs_share "${NFS_PATH}" "Lab NFS share backed by ${POOL_NAME}/${NFS_DATASET_NAME}" "${NFS_NETWORKS}"

  NEED_START_NFS=1
  NEED_START_SSH=1
fi

if [[ "${ENABLE_VCD_TRANSFER_NFS}" == "1" ]]; then
  ensure_filesystem_dataset "${POOL_NAME}/${VCD_TRANSFER_DATASET_NAME}" GENERIC STANDARD "${VCD_TRANSFER_RECORDSIZE}" "${VCD_TRANSFER_COMPRESSION}"
  VCD_TRANSFER_PATH="/mnt/${POOL_NAME}/${VCD_TRANSFER_DATASET_NAME}"
  chown root:root "${VCD_TRANSFER_PATH}"
  chmod 0750 "${VCD_TRANSFER_PATH}"
  log "prepared ${VCD_TRANSFER_PATH} for VMware Cloud Director transfer storage"

  ensure_vcd_transfer_nfs_share "${VCD_TRANSFER_PATH}" "${VCD_TRANSFER_NETWORKS}"

  NEED_START_NFS=1
fi

if [[ "${NEED_START_ISCSI}" == "1" ]]; then
  ensure_service_started iscsitarget
fi

if [[ "${NEED_START_NFS}" == "1" ]]; then
  ensure_service_started nfs
fi

if [[ "${NEED_START_SSH}" == "1" ]]; then
  ensure_service_started ssh
fi

log "storage service initialization completed"
