#!/usr/bin/env python3
import re
import sys
from pathlib import Path


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
    ("truenas.pool.disk_wait_timeout", "Pool Disk Wait Timeout", "Seconds to wait for non-boot disks when auto_create is true. Default 600."),
    ("truenas.pool.name", "Pool Name", "Pool name to create when auto_create is true."),
    ("truenas.pool.layout", "Pool Layout", "stripe, mirror, raidz1, raidz2, or raidz3."),
    ("truenas.pool.compression", "Pool Compression", "Compression for the root dataset, e.g. LZ4, ZSTD, OFF."),
    ("truenas.pool.deduplication", "Pool Deduplication", "Deduplication for the root dataset, e.g. ON, VERIFY, OFF."),
    ("truenas.init_script", "Init Script", "Base64-encoded shell script payload executed on first boot."),
]


def xml_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def render_product_section(indent: str) -> str:
    lines = [
        f"{indent}<ProductSection>",
        f"{indent}  <Info>TrueNAS lab deployment properties</Info>",
        f"{indent}  <Product>TrueNAS CE</Product>",
        f"{indent}  <Vendor>TrueNAS</Vendor>",
        f"{indent}  <Version>25.10</Version>",
    ]
    for key, label, description in PROPERTIES:
        lines.extend(
            [
                f'{indent}  <Property ovf:key="{xml_escape(key)}" ovf:type="string" ovf:userConfigurable="true">',
                f"{indent}    <Label>{xml_escape(label)}</Label>",
                f"{indent}    <Description>{xml_escape(description)}</Description>",
                f"{indent}  </Property>",
            ]
        )
    lines.append(f"{indent}</ProductSection>")
    return "\n".join(lines)


def main(path_str: str) -> None:
    path = Path(path_str)
    text = path.read_text(encoding="utf-8")

    if "xmlns:ovf=" not in text:
        raise SystemExit("OVF namespace prefix declaration is required in the source OVF")

    text, count = re.subn(
        r"(<VirtualHardwareSection\b)(?![^>]*\bovf:transport=)([^>]*>)",
        r'\1 ovf:transport="com.vmware.guestInfo"\2',
        text,
        count=1,
    )
    if count == 0 and 'ovf:transport="com.vmware.guestInfo"' not in text:
        raise SystemExit("VirtualHardwareSection start tag not found")

    text, _ = re.subn(
        r"\n?[ \t]*<ProductSection>.*?</ProductSection>[ \t]*\n?",
        "\n",
        text,
        count=1,
        flags=re.DOTALL,
    )

    match = re.search(r"(?P<indent>[ \t]*)</VirtualSystem>", text)
    if match is None:
        raise SystemExit("VirtualSystem closing tag not found")

    section = render_product_section(match.group("indent"))
    insert_at = match.start()
    if insert_at > 0 and text[insert_at - 1] != "\n":
        section = "\n" + section
    text = text[:insert_at] + section + "\n" + text[insert_at:]

    path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: inject-ovf-properties.py <ovf-path>")
    main(sys.argv[1])
