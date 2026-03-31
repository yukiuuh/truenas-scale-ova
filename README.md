# TrueNAS SCALE Lab OVA

This repository builds a TrueNAS SCALE 25.10 lab template with `vsphere-iso` and `packer`, injects first-boot customization through VMware Tools guest operations in a `shell-local` post-processor, and then exports the VM as an OVA. The template includes only the boot disk. If you want a storage pool, add data disks after deployment and let first boot create the pool from those extra disks.

## What This Image Includes

- A TrueNAS SCALE base VM for vSphere built by Packer
- Guest customization injected immediately after the build completes
- First-boot pool creation based on extra data disks, not baked-in data disks
- Initial network configuration from OVF properties
- Password-based SSH enabled by default
- Local admin password authentication kept available for TrueNAS API usage
- `truenas.init_script` execution from OVF environment data

## Assumptions

- `packer` and `govc` can reach your vCenter or ESXi endpoint
- VMware Tools starts successfully in the built VM
- Post-build guest customization logs in with the same password that was set for `truenas_admin` during installation
- Post-build guest customization enables the `root` password through `midclt` and then installs the first-boot service as `root`
- The TrueNAS installer screens still match the default `installer_boot_command` in [packer/variables.pkr.hcl](/home/yh012243/Documents/truenas-scale-ova/packer/variables.pkr.hcl)

The last point matters. The TrueNAS ISO installer is a text UI, so key sequences can drift between releases. For the first run, watch the vSphere console and adjust `installer_boot_command` if needed.

The default flow for `25.10.2.1` assumes:

- `1` selects `Install/Upgrade`
- On the Destination Media screen, the first disk is selected with `Space`
- The warning prompt is confirmed with `Yes`
- `Administrative user (truenas_admin)` is selected
- The password prompt is filled
- The final confirmation screen is accepted

If your screen layout differs, override `installer_boot_command` in `packer/truenas.auto.pkrvars.hcl`.

On slow environments, increase the installer wait values.

```hcl
installer_disk_screen_wait        = "90s"
installer_warning_wait            = "8s"
installer_admin_user_wait         = "8s"
installer_install_complete_wait   = "900s"
installer_post_install_menu_wait  = "8s"
```

## Development Environment

```bash
make init
make fmt
```

`flake.nix` provides `packer`, `govc`, `jq`, and `python3`. Packer is expected to read the whole `packer/` directory, not a single file.

## 1. Build the Base VM

Create a variable file first.

```bash
cp packer/truenas.auto.pkrvars.hcl.example packer/truenas.auto.pkrvars.hcl
```

At minimum, fill in:

- `vcenter_server`
- `vcenter_username`
- `vcenter_password`
- `vsphere_datacenter`
- `vsphere_cluster`
- `vsphere_datastore`
- `vsphere_network`
- `packer_admin_password`

The default ISO URL is:

- `https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.2.1/TrueNAS-SCALE-25.10.2.1.iso`

Run the build:

```bash
make validate
make build
```

`make build` uses `packer build -force`, so an existing VM with the same name is destroyed and rebuilt. After the build completes, `scripts/customize-vm.sh` runs automatically as a post-processor and injects the first-boot service into the guest. The resulting lab template has baked-in `truenas_admin` and `root` credentials, and both initial passwords are set to the value of `packer_admin_password`.

## 2. Re-run Guest Customization Manually

This is usually unnecessary because `make build` already runs it automatically. It uses guest operations, so SSH is not required yet.

```bash
make customize
```

This customization flow uploads a payload into `/var/tmp`, enables the `root` password through `midclt` while logged in as `truenas_admin`, enables the writable developer environment when needed, and installs the first-boot service under `/opt/truenas-lab` and `/etc/systemd/system`.

## 3. Export the OVA

```bash
make export
```

By default, `make export` runs a guest-side boot disk zero-fill pass before powering off and exporting the VM. This now happens in a dedicated step instead of the build post-processor. Disable it only if needed:

```bash
make export ZERO_FILL_BOOT_DISK=0
```

## 4. Deploy the OVA

The repository includes a `govc`-based deployment script.

```bash
make deploy OVA_PATH=dist/truenas-scale-25.10-lab.ova
```

By default it reads these values from `PKR_VAR_FILE`:

- `vcenter_server`
- `vcenter_username`
- `vcenter_password`
- `vsphere_datacenter`
- `vsphere_datastore`
- `vsphere_network`
- `vm_name`

You can override them with environment variables:

```bash
make deploy \
  OVA_PATH=dist/truenas-scale-25.10-lab.ova \
  VM_NAME=tn-scale-01 \
  NETWORK='Lab VM Network' \
  DATA_DISK_SIZES_GB='200,200' \
  POWER_ON=1
```

OVF properties can be supplied from a JSON file. See [deploy/ovf-properties.example.json](/home/yh012243/Documents/truenas-scale-ova/deploy/ovf-properties.example.json).

```bash
make deploy \
  OVA_PATH=dist/truenas-scale-25.10-lab.ova \
  OVF_PROPERTIES_FILE=deploy/ovf-properties.example.json
```

To inject the current init script file directly instead of relying on the base64 already embedded in the OVF properties JSON, pass `INIT_SCRIPT_PATH`:

```bash
make deploy \
  OVA_PATH=dist/truenas-scale-25.10-lab.ova \
  OVF_PROPERTIES_FILE=deploy/ovf-properties.example.json \
  INIT_SCRIPT_PATH=./deploy/init-script.storage-services.example.sh
```

If you set `DATA_DISK_SIZES_GB='200,200,500'`, those data disks are attached in addition to the OVA boot disk.

Run the full pipeline with:

```bash
make all
```

`customize` and `export` read `vm_name` and vCenter connection details from `PKR_VAR_FILE` by default. Override them with environment variables if needed.

```bash
make build PKR_VAR_FILE=packer/lab.auto.pkrvars.hcl
make customize VM_NAME=truenas-scale-lab-01
make export VM_NAME=truenas-scale-lab-01 OVA_OUTPUT_DIR=output/
```

If you want each NIC mapped to a different port group, use `NETWORKS` at deploy time.

```bash
make deploy \
  OVA_PATH=dist/truenas-scale-25.10-lab.ova \
  NETWORKS='Mgmt,Storage-01,Storage-02,Storage-03'
```

`make export` always recreates `dist/<vm_name>.export/` and overwrites `dist/<vm_name>.ova`. `make deploy` replaces an existing VM with the same name by default. Set `REPLACE_VM=0` only if you want it to fail instead.

The export flow does the following:

- Powers off the VM
- Uses `govc export.ovf` to fetch the OVF and VMDKs
- Injects a `PropertySection` into the OVF descriptor
- Packs the result into an `.ova`

## OVF Properties Available at Deploy Time

- `truenas.hostname`
- `truenas.domain`
- `truenas.search_domains`
- `truenas.nic0.ipv4.mode`
- `truenas.nic0.ipv4.address`
- `truenas.nic0.ipv4.prefixlen`
- `truenas.nic0.mtu`
- `truenas.nic0.vlan_tag`
- `truenas.nic1.ipv4.mode`
- `truenas.nic1.ipv4.address`
- `truenas.nic1.ipv4.prefixlen`
- `truenas.nic1.mtu`
- `truenas.nic1.vlan_tag`
- `truenas.nic2.ipv4.mode`
- `truenas.nic2.ipv4.address`
- `truenas.nic2.ipv4.prefixlen`
- `truenas.nic2.mtu`
- `truenas.nic2.vlan_tag`
- `truenas.nic3.ipv4.mode`
- `truenas.nic3.ipv4.address`
- `truenas.nic3.ipv4.prefixlen`
- `truenas.nic3.mtu`
- `truenas.nic3.vlan_tag`
- `truenas.ipv4.gateway`
- `truenas.dns.1`
- `truenas.dns.2`
- `truenas.dns.3`
- `truenas.admin.password`
- `truenas.ssh.password_auth`
- `truenas.pool.auto_create`
- `truenas.pool.name`
- `truenas.pool.layout`
- `truenas.pool.compression`
- `truenas.pool.deduplication`
- `truenas.init_script`

### Network Example

```text
truenas.hostname = tn-scale-01
truenas.domain = lab.local
truenas.nic0.ipv4.mode = static
truenas.nic0.ipv4.address = 192.168.10.50
truenas.nic0.ipv4.prefixlen = 24
truenas.nic0.mtu = 1500
truenas.ipv4.gateway = 192.168.10.1
truenas.dns.1 = 192.168.10.10
truenas.dns.2 = 1.1.1.1
truenas.nic1.ipv4.mode = static
truenas.nic1.ipv4.address = 10.10.10.50
truenas.nic1.ipv4.prefixlen = 24
truenas.nic1.mtu = 9000
truenas.nic1.vlan_tag = 110
truenas.nic2.ipv4.mode = static
truenas.nic2.ipv4.address = 10.10.20.50
truenas.nic2.ipv4.prefixlen = 24
truenas.nic2.mtu = 9000
truenas.nic2.vlan_tag = 120
truenas.nic3.ipv4.mode = static
truenas.nic3.ipv4.address = 10.10.30.50
truenas.nic3.ipv4.prefixlen = 24
truenas.nic3.mtu = 9000
truenas.nic3.vlan_tag = 130
```

`truenas.nicX.vlan_tag` stays untagged if left empty, omitted, or set to `0`. `truenas.nicX.mtu` stays at the TrueNAS default if omitted.

### Automatic Pool Creation Example

```text
truenas.pool.auto_create = true
truenas.pool.name = vol0
truenas.pool.layout = stripe
truenas.pool.compression = ZSTD
truenas.pool.deduplication = OFF
```

This creates `vol0` from all disks that are not part of the boot pool, then applies compression and deduplication settings to the root dataset.

### Init Script Example

```bash
base64 -w0 init-script.sh
```

Set the resulting value as `truenas.init_script`. The script runs as `root` on first boot and must start with a `#!` shebang.

A practical example is provided in [deploy/init-script.storage-services.example.sh](/home/yh012243/Documents/truenas-scale-ova/deploy/init-script.storage-services.example.sh). It is a single script that can enable iSCSI, regular NFS/SFTP, and VMware Cloud Director transfer storage through:

- `ENABLE_ISCSI`
- `ENABLE_NFS`
- `ENABLE_VCD_TRANSFER_NFS`

The main tunables are:

- `POOL_NAME`
- `NIC1_IP`
- `NIC2_IP`
- `ZVOL1_NAME`
- `ZVOL2_NAME`
- `ZVOL1_SIZE_GIB`
- `ZVOL2_SIZE_GIB`
- `ZVOL_DEFAULT_PERCENT`
- `ZVOL_SPARSE`
- `ZVOL_COMPRESSION`
- `FORCE_SIZE`
- `NFS_DATASET_NAME`
- `NFS_NETWORKS`
- `VCD_TRANSFER_DATASET_NAME`
- `VCD_TRANSFER_NETWORKS`

If left empty, `POOL_NAME` is inferred from `midclt call pool.query`, and `NIC1_IP` / `NIC2_IP` are inferred from `midclt call interface.query`.

The sample uses these defaults:

- zvols are thin-provisioned with `ZVOL_SPARSE=1`
- zvol compression defaults to `ZSTD`
- `FORCE_SIZE=1` enables the UI-equivalent `Force size` behavior
- `sparse` and `force_size` are independent toggles
- if `ZVOL1_SIZE_GIB` and `ZVOL2_SIZE_GIB` are empty, each LUN defaults to `ZVOL_DEFAULT_PERCENT` of total pool size, which is `90` by default
- the regular NFS share defaults to `NFS_MAPROOT_USER=root`, `NFS_MAPROOT_GROUP=wheel`, and `security=["SYS"]` so it can be used as a vSphere NFS datastore
- `mapall` is empty by default for the regular NFS share
- filesystem datasets do not need an extra thin-provisioning setting
- iSCSI zvols use `sync=STANDARD` and `snapdev=HIDDEN`
- the regular NFS/SFTP dataset uses `recordsize=1M`, `atime=OFF`, `compression=ZSTD`, and `sync=DISABLED`
- when `ENABLE_VCD_TRANSFER_NFS=1`, a dedicated VMware Cloud Director transfer share is created with `root:root`, mode `0750`, and `mapall root:root` to match the Linux `no_root_squash` requirement as closely as TrueNAS allows

`truenas.init_script` is an OVF string property, so it has a size limit. This OVA injects `MaxLen(65535)` into the OVF descriptor, which means roughly 64 KiB for the base64 string and about 48 KiB of original script content after base64 overhead. For anything larger, use a short bootstrap script that fetches the real payload over HTTP, SFTP, or another transport.

The Broadcom VMware Cloud Director installation guide shows the transfer share as a Linux NFS export with root read/write and `no_root_squash`. TrueNAS does not expose that exact knob, so the `ENABLE_VCD_TRANSFER_NFS=1` path uses `mapall root:root` instead.

## Implementation Notes

- There is no confirmed built-in TrueNAS mechanism for directly applying OVF properties to network configuration and init scripts, so this project installs a custom first-boot service inside the OVA.
- Guest-side package installation and first-boot service placement happen during `packer build` in a post-processor. Only OVF descriptor editing is left for the export phase.
- SSH enablement uses `ssh.update` and `service.update` / `service.control`, and password-based SSH user settings use `user.update`.
- Pool creation uses `pool.create`, and the boot pool disks are excluded by parsing `zpool status -P boot-pool`.
- Do not commit `packer/truenas.auto.pkrvars.hcl`, `dist/`, or other local build artifacts. The repository should only contain the example var file and source files.

## References

- TrueNAS API `ssh.update`: https://api.truenas.com/v25.10/api_methods_ssh.update.html
- TrueNAS API `service.update`: https://api.truenas.com/v25.10/api_methods_service.update.html
- TrueNAS API `service.control`: https://api.truenas.com/v25.10/api_methods_service.control.html
- TrueNAS API `user.update`: https://api.truenas.com/v25.10/api_methods_user.update.html
- TrueNAS API `network.configuration.update`: https://api.truenas.com/v25.10/api_methods_network.configuration.update.html
- TrueNAS API `interface.update`: https://api.truenas.com/v25.10/api_methods_interface.update.html
- TrueNAS API `pool.create`: https://api.truenas.com/v25.10.0/api_methods_pool.create.html
