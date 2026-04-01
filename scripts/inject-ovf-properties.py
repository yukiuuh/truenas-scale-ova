#!/usr/bin/env python3
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


NS = {
    "ovf": "http://schemas.dmtf.org/ovf/envelope/1",
    "rasd": "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData",
    "vssd": "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData",
    "vmw": "http://www.vmware.com/schema/ovf",
}

ET.register_namespace("ovf", NS["ovf"])
ET.register_namespace("rasd", NS["rasd"])
ET.register_namespace("vssd", NS["vssd"])
ET.register_namespace("vmw", NS["vmw"])


PROPERTIES = [
    ("truenas.hostname", "Hostname", "Optional host name to set through TrueNAS middleware."),
    ("truenas.domain", "Domain", "Optional DNS search domain."),
    ("truenas.search_domains", "Search Domains", "Comma-separated DNS search domains."),
    ("truenas.nic0.ipv4.mode", "NIC0 IPv4 Mode", "Use dhcp or static for the management interface."),
    ("truenas.nic0.ipv4.address", "NIC0 IPv4 Address", "Static IPv4 address for NIC0."),
    ("truenas.nic0.ipv4.prefixlen", "NIC0 IPv4 Prefix Length", "CIDR prefix length for the static IPv4 address on NIC0."),
    ("truenas.nic0.mtu", "NIC0 MTU", "MTU for NIC0, e.g. 1500 or 9000."),
    ("truenas.nic0.vlan_tag", "NIC0 VLAN Tag", "Optional VLAN tag for NIC0. Leave empty or use 0 for untagged."),
    ("truenas.nic1.ipv4.mode", "NIC1 IPv4 Mode", "Use dhcp or static for the first storage interface."),
    ("truenas.nic1.ipv4.address", "NIC1 IPv4 Address", "Static IPv4 address for NIC1."),
    ("truenas.nic1.ipv4.prefixlen", "NIC1 IPv4 Prefix Length", "CIDR prefix length for the static IPv4 address on NIC1."),
    ("truenas.nic1.mtu", "NIC1 MTU", "MTU for NIC1, e.g. 1500 or 9000."),
    ("truenas.nic1.vlan_tag", "NIC1 VLAN Tag", "Optional VLAN tag for NIC1. Leave empty or use 0 for untagged."),
    ("truenas.nic2.ipv4.mode", "NIC2 IPv4 Mode", "Use dhcp or static for the second storage interface."),
    ("truenas.nic2.ipv4.address", "NIC2 IPv4 Address", "Static IPv4 address for NIC2."),
    ("truenas.nic2.ipv4.prefixlen", "NIC2 IPv4 Prefix Length", "CIDR prefix length for the static IPv4 address on NIC2."),
    ("truenas.nic2.mtu", "NIC2 MTU", "MTU for NIC2, e.g. 1500 or 9000."),
    ("truenas.nic2.vlan_tag", "NIC2 VLAN Tag", "Optional VLAN tag for NIC2. Leave empty or use 0 for untagged."),
    ("truenas.nic3.ipv4.mode", "NIC3 IPv4 Mode", "Use dhcp or static for the third storage interface."),
    ("truenas.nic3.ipv4.address", "NIC3 IPv4 Address", "Static IPv4 address for NIC3."),
    ("truenas.nic3.ipv4.prefixlen", "NIC3 IPv4 Prefix Length", "CIDR prefix length for the static IPv4 address on NIC3."),
    ("truenas.nic3.mtu", "NIC3 MTU", "MTU for NIC3, e.g. 1500 or 9000."),
    ("truenas.nic3.vlan_tag", "NIC3 VLAN Tag", "Optional VLAN tag for NIC3. Leave empty or use 0 for untagged."),
    ("truenas.ipv4.gateway", "IPv4 Gateway", "Default IPv4 gateway."),
    ("truenas.dns.1", "DNS Server 1", "Primary DNS server."),
    ("truenas.dns.2", "DNS Server 2", "Secondary DNS server."),
    ("truenas.dns.3", "DNS Server 3", "Tertiary DNS server."),
    ("truenas.admin.password", "Admin Password", "Optional password reset for the built-in admin/root accounts."),
    ("truenas.ssh.password_auth", "SSH Password Auth", "Enable password-based SSH access. Default true."),
    ("truenas.pool.auto_create", "Auto Create Pool", "When true, create a pool from all non-boot disks on first boot."),
    ("truenas.pool.name", "Pool Name", "Pool name to create when auto_create is true."),
    ("truenas.pool.layout", "Pool Layout", "stripe, mirror, raidz1, raidz2, or raidz3."),
    ("truenas.pool.compression", "Pool Compression", "Compression for the root dataset, e.g. LZ4, ZSTD, OFF."),
    ("truenas.pool.deduplication", "Pool Deduplication", "Deduplication for the root dataset, e.g. ON, VERIFY, OFF."),
    ("truenas.init_script", "Init Script", "Base64-encoded shell script payload executed on first boot."),
]


def ensure_product_section(virtual_system):
    section = virtual_system.find("ovf:ProductSection", NS)
    if section is None:
        section = ET.SubElement(virtual_system, f"{{{NS['ovf']}}}ProductSection")
        info = ET.SubElement(section, f"{{{NS['ovf']}}}Info")
        info.text = "TrueNAS SCALE lab deployment properties"
        product = ET.SubElement(section, f"{{{NS['ovf']}}}Product")
        product.text = "TrueNAS SCALE Lab OVA"
    return section


def add_properties(section):
    for key, label, description in PROPERTIES:
        prop = ET.SubElement(section, f"{{{NS['ovf']}}}Property")
        prop.set(f"{{{NS['ovf']}}}key", key)
        prop.set(f"{{{NS['ovf']}}}type", "string")
        prop.set(f"{{{NS['ovf']}}}userConfigurable", "true")
        prop.set(f"{{{NS['ovf']}}}qualifiers", "MaxLen(65535)")
        prop.set(f"{{{NS['ovf']}}}label", label)
        prop.set(f"{{{NS['ovf']}}}description", description)


def move_attr_to_ns(elem, attr_name, namespace):
    value = elem.attrib.pop(attr_name, None)
    if value is not None:
        elem.set(f"{{{namespace}}}{attr_name}", value)


def normalize_common_ovf_attributes(root):
    ovf_attr_map = {
        "File": ["id", "href", "size", "compression"],
        "Disk": ["diskId", "capacity", "capacityAllocationUnits", "fileRef", "format", "populatedSize"],
        "Network": ["name"],
        "VirtualSystem": ["id"],
        "OperatingSystemSection": ["id", "version"],
        "AnnotationSection": ["required"],
        "Item": ["required"],
        "Property": ["key", "type", "userConfigurable", "qualifiers", "label", "description", "value"],
    }
    for local_name, attrs in ovf_attr_map.items():
        for elem in root.findall(f".//ovf:{local_name}", NS):
            for attr_name in attrs:
                move_attr_to_ns(elem, attr_name, NS["ovf"])

    for elem in root.findall(".//vmw:Config", NS) + root.findall(".//vmw:ExtraConfig", NS):
        move_attr_to_ns(elem, "required", NS["vmw"])


def main(path_str):
    path = Path(path_str)
    tree = ET.parse(path)
    root = tree.getroot()
    normalize_common_ovf_attributes(root)
    virtual_system = root.find("ovf:VirtualSystem", NS)
    if virtual_system is None:
      raise SystemExit("VirtualSystem element not found")

    section = ensure_product_section(virtual_system)
    for existing in list(section.findall("ovf:Property", NS)):
        section.remove(existing)
    add_properties(section)
    tree.write(path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: inject-ovf-properties.py <ovf-path>")
    main(sys.argv[1])
