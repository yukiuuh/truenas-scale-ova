#!/usr/bin/env python3
import base64
import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path


STATE_DIR = Path("/var/lib/truenas-lab")
STAMP_FILE = STATE_DIR / "firstboot-complete"
LOG_FILE = STATE_DIR / "firstboot.log"
SCRIPT_FILE = STATE_DIR / "ovf-script.sh"


def log(message: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}"
    LOG_FILE.open("a", encoding="utf-8").write(line + "\n")
    print(line, flush=True)


def run(command, check=True, capture_output=True, text=True):
    log(f"run: {' '.join(command)}")
    return subprocess.run(
        command,
        check=check,
        capture_output=capture_output,
        text=text,
    )


def midclt(method, *params):
    command = ["midclt", "call", method]
    command.extend(json.dumps(param) for param in params)
    result = run(command)
    stdout = result.stdout.strip()
    if not stdout:
        return None
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return stdout


def wait_for_ready(timeout=900):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            state = midclt("system.state")
            if state == "READY":
                return
        except Exception as exc:
            log(f"system.state not ready yet: {exc}")
        time.sleep(5)
    raise RuntimeError("Timed out waiting for TrueNAS middleware to become ready")


def wait_for_job_chain(job_id, timeout=900):
    deadline = time.time() + timeout
    remaining = int(deadline - time.time())
    if remaining <= 0:
        raise RuntimeError(f"Timed out waiting for job {job_id}")

    result = midclt("core.job_wait", job_id)
    log(f"job_wait for {job_id} returned: {json.dumps(result, sort_keys=True)}")
    return result


def wait_for_pool_visibility(pool_name, timeout=120):
    deadline = time.time() + timeout
    last_zpool_list = ""

    while time.time() < deadline:
        pools = midclt("pool.query") or []
        created_pool = next((pool for pool in pools if pool.get("name") == pool_name), None)
        if created_pool is not None:
            return created_pool

        try:
            last_zpool_list = run(["zpool", "list"], check=False).stdout.strip()
        except Exception as exc:
            last_zpool_list = f"zpool list failed: {exc}"

        time.sleep(2)

    raise RuntimeError(
        f"pool {pool_name!r} is not visible after waiting {timeout}s. "
        f"Last zpool list output: {last_zpool_list}"
    )


def wait_for_resource(description, probe_fn, timeout=120, interval=2):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = probe_fn()
        if result:
            return result
        time.sleep(interval)
    raise RuntimeError(f"Timed out waiting for {description}")


def get_ovf_env():
    try:
        result = run(["vmtoolsd", "--cmd", "info-get guestinfo.ovfEnv"])
    except Exception as exc:
        log(f"vmtoolsd query failed: {exc}")
        return {}

    xml_text = result.stdout.strip()
    if not xml_text:
        return {}

    namespaces = {
        "oe": "http://schemas.dmtf.org/ovf/environment/1",
        "ovf": "http://schemas.dmtf.org/ovf/envelope/1",
    }
    root = ET.fromstring(xml_text)
    properties = {}
    for prop in root.findall(".//oe:Property", namespaces):
        key = (
            prop.attrib.get(f"{{{namespaces['oe']}}}key")
            or prop.attrib.get(f"{{{namespaces['ovf']}}}key")
            or prop.attrib.get("key")
        )
        value = (
            prop.attrib.get(f"{{{namespaces['oe']}}}value")
            or prop.attrib.get(f"{{{namespaces['ovf']}}}value")
            or prop.attrib.get("value")
            or ""
        )
        if key:
            properties[key] = value
    return properties


def bool_prop(properties, key, default=False):
    value = properties.get(key)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def str_prop(properties, key, default=""):
    return properties.get(key, default).strip()


def vlan_tag_prop(properties, key):
    value = str_prop(properties, key)
    if value in {"", "0"}:
        return None
    return int(value)


def get_primary_interface():
    return get_physical_interfaces()[0]["id"]


def get_physical_interfaces():
    interfaces = midclt("interface.query") or []
    physical = []
    for entry in interfaces:
        if entry.get("name") in {"lo", "docker0"}:
            continue
        if entry.get("state", {}).get("cloned"):
            continue
        if entry.get("type") in {None, "PHYSICAL"}:
            physical.append(entry)
    if not physical:
        raise RuntimeError("No suitable physical interfaces found")
    physical.sort(key=lambda item: item["id"])
    return physical


def get_service_identifier(name):
    services = midclt("service.query") or []
    for service in services:
        if service.get("service") == name:
            return service.get("id", name)
    return name


def get_vlan_interface(parent_id, vlan_tag):
    interfaces = midclt("interface.query") or []
    for entry in interfaces:
        if entry.get("type") != "VLAN":
            continue
        if entry.get("vlan_parent_interface") == parent_id and entry.get("vlan_tag") == vlan_tag:
            return entry
    return None


def ensure_admin_access(properties):
    users = midclt("user.query") or []
    candidates = [u for u in users if u.get("username") in {"admin", "root", "truenas_admin"}]
    target_password = str_prop(properties, "truenas.admin.password")
    for user in candidates:
        payload = {
            "password_disabled": False,
            "ssh_password_enabled": True,
            "locked": False,
        }
        if target_password:
            payload["password"] = target_password
        try:
            midclt("user.update", user["id"], payload)
            log(f"updated user access for {user['username']}")
        except Exception as exc:
            log(f"user.update failed for {user['username']}: {exc}")

    try:
        ssh_service = get_service_identifier("ssh")
        midclt("ssh.update", {"passwordauth": bool_prop(properties, "truenas.ssh.password_auth", True)})
        midclt("service.update", ssh_service, {"enable": True})
        midclt("service.control", "START", "ssh", {"silent": True, "timeout": 120})
    except Exception as exc:
        log(f"failed to ensure ssh service state: {exc}")


def apply_network(properties):
    network_keys = {
        "truenas.hostname",
        "truenas.domain",
        "truenas.search_domains",
        "truenas.nic0.ipv4.mode",
        "truenas.nic0.ipv4.address",
        "truenas.nic0.ipv4.prefixlen",
        "truenas.nic0.mtu",
        "truenas.nic0.vlan_tag",
        "truenas.nic1.ipv4.mode",
        "truenas.nic1.ipv4.address",
        "truenas.nic1.ipv4.prefixlen",
        "truenas.nic1.mtu",
        "truenas.nic1.vlan_tag",
        "truenas.nic2.ipv4.mode",
        "truenas.nic2.ipv4.address",
        "truenas.nic2.ipv4.prefixlen",
        "truenas.nic2.mtu",
        "truenas.nic2.vlan_tag",
        "truenas.nic3.ipv4.mode",
        "truenas.nic3.ipv4.address",
        "truenas.nic3.ipv4.prefixlen",
        "truenas.nic3.mtu",
        "truenas.nic3.vlan_tag",
        "truenas.ipv4.gateway",
        "truenas.dns.1",
        "truenas.dns.2",
        "truenas.dns.3",
    }
    if not any(key in properties for key in network_keys):
        log("no OVF network properties found, leaving current network configuration unchanged")
        return

    hostname = str_prop(properties, "truenas.hostname")
    domain = str_prop(properties, "truenas.domain")
    search_domains = [item for item in str_prop(properties, "truenas.search_domains").split(",") if item]

    network_payload = {}
    if hostname:
        network_payload["hostname"] = hostname
    if domain:
        network_payload["domain"] = domain
    if str_prop(properties, "truenas.ipv4.gateway"):
        network_payload["ipv4gateway"] = str_prop(properties, "truenas.ipv4.gateway")
    for index in (1, 2, 3):
        value = str_prop(properties, f"truenas.dns.{index}")
        if value:
            network_payload[f"nameserver{index}"] = value
    if search_domains:
        network_payload["domains"] = search_domains

    if network_payload:
        midclt("network.configuration.update", network_payload)

    interfaces = get_physical_interfaces()
    pending_changes = False

    for idx, iface in enumerate(interfaces[:4]):
        mode_key = f"truenas.nic{idx}.ipv4.mode"
        address_key = f"truenas.nic{idx}.ipv4.address"
        prefix_key = f"truenas.nic{idx}.ipv4.prefixlen"
        mtu_key = f"truenas.nic{idx}.mtu"
        vlan_key = f"truenas.nic{idx}.vlan_tag"

        if idx == 0 and mode_key not in properties and "truenas.ipv4.mode" in properties:
            mode_value = str_prop(properties, "truenas.ipv4.mode", "dhcp").lower()
            address_value = str_prop(properties, "truenas.ipv4.address")
            prefix_value = str_prop(properties, "truenas.ipv4.prefixlen", "24")
            mtu_value = str_prop(properties, mtu_key)
            vlan_value = vlan_tag_prop(properties, vlan_key)
        else:
            mode_value = str_prop(properties, mode_key).lower()
            address_value = str_prop(properties, address_key)
            prefix_value = str_prop(properties, prefix_key, "24")
            mtu_value = str_prop(properties, mtu_key)
            vlan_value = vlan_tag_prop(properties, vlan_key)

        if not mode_value:
            continue

        if mode_value == "static":
            if not address_value:
                raise RuntimeError(f"{address_key} is required when {mode_key}=static")
            payload = {
                "ipv4_dhcp": False,
                "aliases": [
                    {
                        "type": "INET",
                        "address": address_value,
                        "netmask": int(prefix_value),
                    }
                ],
            }
        elif mode_value == "dhcp":
            payload = {
                "ipv4_dhcp": True,
                "aliases": [],
            }
        else:
            raise RuntimeError(f"unsupported mode {mode_value} for {mode_key}")

        target_interface_id = iface["id"]
        if mtu_value:
            payload["mtu"] = int(mtu_value)

        if vlan_value is not None:
            vlan_tag = vlan_value
            parent_update = {"aliases": [], "ipv4_dhcp": False}
            if mtu_value:
                parent_update["mtu"] = int(mtu_value)
            midclt("interface.update", iface["id"], parent_update)

            existing_vlan = get_vlan_interface(iface["id"], vlan_tag)
            if existing_vlan:
                target_interface_id = existing_vlan["id"]
                midclt("interface.update", target_interface_id, payload)
                log(f"staged {mode_value} VLAN config for {target_interface_id} on parent {iface['id']} tag {vlan_tag}")
            else:
                create_payload = {
                    "name": f"vlan{idx}",
                    "type": "VLAN",
                    "vlan_parent_interface": iface["id"],
                    "vlan_tag": vlan_tag,
                    **payload,
                }
                if mtu_value:
                    create_payload["mtu"] = int(mtu_value)
                created = midclt("interface.create", create_payload)
                target_interface_id = created["id"]
                log(f"created and staged VLAN interface {target_interface_id} on parent {iface['id']} tag {vlan_tag}")
        else:
            midclt("interface.update", iface["id"], payload)
            log(f"staged {mode_value} network config for {iface['id']}")

        pending_changes = True

    if not pending_changes:
        return

    if network_payload.get("ipv4gateway"):
        midclt(
            "interface.save_network_config",
            {
                "ipv4gateway": network_payload["ipv4gateway"],
                "nameserver1": network_payload.get("nameserver1", ""),
                "nameserver2": network_payload.get("nameserver2", ""),
                "nameserver3": network_payload.get("nameserver3", ""),
            },
        )
        log("saved gateway and nameserver config for network commit")

    midclt("interface.commit", {"rollback": True, "checkin_timeout": 60})
    midclt("interface.checkin")
    log("committed and checked in network configuration")


def boot_pool_disks():
    try:
        result = run(["zpool", "status", "-P", "boot-pool"])
    except Exception:
        return set()
    disks = set()
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("/dev/"):
            device_name = Path(line.split()[0]).name
            try:
                parent = run(["lsblk", "-ndo", "PKNAME", f"/dev/{device_name}"]).stdout.strip()
            except Exception:
                parent = ""
            disks.add(parent or device_name)
    return disks


def available_data_disks():
    used = boot_pool_disks()
    result = run(["lsblk", "-dn", "-o", "NAME,TYPE"])
    disks = []
    for line in result.stdout.splitlines():
        name, dev_type = line.split()
        if dev_type != "disk":
            continue
        if name in used:
            continue
        disks.append(name)
    return disks


def maybe_create_pool(properties):
    if not bool_prop(properties, "truenas.pool.auto_create", False):
        return

    pool_name = str_prop(properties, "truenas.pool.name", "vol0")
    layout = str_prop(properties, "truenas.pool.layout", "stripe").upper()
    disks = available_data_disks()

    if not disks:
        log("no extra data disks found, skipping pool creation")
        return

    existing = midclt("pool.query") or []
    if any(pool.get("name") == pool_name for pool in existing):
        log(f"pool {pool_name} already exists, skipping creation")
        return

    valid_layout = {
        "STRIPE": 1,
        "MIRROR": 2,
        "RAIDZ1": 2,
        "RAIDZ2": 3,
        "RAIDZ3": 4,
    }
    minimum = valid_layout.get(layout, 1)
    if len(disks) < minimum:
        log(f"pool layout {layout} needs at least {minimum} disks, found {len(disks)}")
        return

    payload = {
        "name": pool_name,
        "allow_duplicate_serials": True,
        "topology": {
            "data": [
                {
                    "type": layout,
                    "disks": disks,
                }
            ]
        },
    }
    job_id = midclt("pool.create", payload)
    log(f"submitted pool.create job {job_id} for pool {pool_name} on disks {', '.join(disks)}")
    job_result = wait_for_job_chain(job_id)
    log(f"pool.create job {job_id} completed: {json.dumps(job_result, sort_keys=True)}")

    created_pool = wait_for_resource(
        f"pool {pool_name}",
        lambda: next((pool for pool in (midclt("pool.query") or []) if pool.get("name") == pool_name), None),
        timeout=120,
    )

    log(f"verified pool {pool_name} exists with id {created_pool.get('id')}")

    dataset_payload = {}
    compression = str_prop(properties, "truenas.pool.compression").upper()
    deduplication = str_prop(properties, "truenas.pool.deduplication").upper()
    if compression:
        dataset_payload["compression"] = compression
    if deduplication:
        dataset_payload["deduplication"] = deduplication

    if dataset_payload:
        dataset_result = midclt("pool.dataset.update", pool_name, dataset_payload)
        log(
            "updated root dataset properties for "
            f"{pool_name}: {json.dumps(dataset_payload, sort_keys=True)} result={json.dumps(dataset_result, sort_keys=True)}"
        )


def handle_init_script(properties):
    raw = str_prop(properties, "truenas.init_script")
    if not raw:
        return

    content = base64.b64decode(raw).decode("utf-8")

    SCRIPT_FILE.write_text(content, encoding="utf-8")
    SCRIPT_FILE.chmod(0o700)
    log(f"stored OVF init script at {SCRIPT_FILE}")

    if not content.startswith("#!"):
        raise RuntimeError("OVF init script must start with a shebang")

    result = subprocess.run(
        [str(SCRIPT_FILE)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip():
        log(f"init script stdout:\n{result.stdout.rstrip()}")
    if result.stderr.strip():
        log(f"init script stderr:\n{result.stderr.rstrip()}")
    if result.returncode != 0:
        raise RuntimeError(f"OVF init script failed with exit status {result.returncode}")
    log("executed OVF init script")


def main():
    if STAMP_FILE.exists():
        log("firstboot already completed")
        return 0

    try:
        wait_for_ready()
        properties = get_ovf_env()
        if not properties:
            log("no OVF environment data found")
        else:
            log(f"loaded OVF properties: {', '.join(sorted(properties.keys()))}")

        ensure_admin_access(properties)
        apply_network(properties)
        maybe_create_pool(properties)
        handle_init_script(properties)

        STAMP_FILE.write_text(time.strftime("%Y-%m-%dT%H:%M:%S%z"), encoding="utf-8")
        log("firstboot customization completed")
        return 0
    except Exception as exc:
        log(f"firstboot customization failed: {exc}")
        raise


if __name__ == "__main__":
    sys.exit(main())
