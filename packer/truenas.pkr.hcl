locals {
  installer_disk_screen_wait_token       = format("<wait%s>", trimsuffix(var.installer_disk_screen_wait, "s"))
  installer_warning_wait_token           = format("<wait%s>", trimsuffix(var.installer_warning_wait, "s"))
  installer_admin_user_wait_token        = format("<wait%s>", trimsuffix(var.installer_admin_user_wait, "s"))
  installer_password_screen_wait_token   = format("<wait%s>", trimsuffix(var.installer_password_screen_wait, "s"))
  installer_install_complete_wait_token  = format("<wait%s>", trimsuffix(var.installer_install_complete_wait, "s"))
  installer_post_install_menu_wait_token = format("<wait%s>", trimsuffix(var.installer_post_install_menu_wait, "s"))
}

packer {
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = ">= 1.4.2"
    }
  }
}

source "vsphere-iso" "truenas_scale" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.insecure_connection

  datacenter    = var.vsphere_datacenter
  cluster       = var.vsphere_cluster
  datastore     = var.vsphere_datastore
  folder        = var.vsphere_folder
  resource_pool = var.vsphere_resource_pool != "" ? var.vsphere_resource_pool : null
  host          = var.vsphere_host != "" ? var.vsphere_host : null

  vm_name       = var.vm_name
  vm_version    = var.vm_version
  guest_os_type = var.vm_guest_os_type
  firmware      = var.vm_firmware

  CPUs                 = var.vm_cpus
  RAM                  = var.vm_memory_mb
  RAM_reserve_all      = false
  disk_controller_type = ["pvscsi"]
  remove_cdrom         = false
  NestedHV             = true

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  storage {
    disk_size             = var.boot_disk_size_mb
    disk_thin_provisioned = true
  }

  iso_urls     = [var.iso_url]
  iso_checksum = var.iso_checksum

  boot_wait = var.boot_wait
  boot_command = length(var.installer_boot_command) > 0 ? var.installer_boot_command : concat(
    [
      "1<enter>",
      local.installer_disk_screen_wait_token,
      "<spacebar>",
      "<wait2>",
      "<enter>",
      local.installer_warning_wait_token,
      "<enter>",
      local.installer_admin_user_wait_token,
      "<enter>",
      local.installer_password_screen_wait_token,
    ],
    [format("%s<tab>%s<tab><enter>", var.packer_admin_password, var.packer_admin_password)],
    [
      local.installer_install_complete_wait_token,
      "<enter>",
      local.installer_post_install_menu_wait_token,
      "4<enter>",
    ],
  )

  communicator     = "none"
  shutdown_timeout = var.shutdown_timeout

  notes = <<-EOT
    TrueNAS SCALE lab template.
    truenas_admin password: ${var.packer_admin_password}
    root password: ${var.packer_admin_password}
  EOT
}

build {
  name    = "truenas-scale-base"
  sources = ["source.vsphere-iso.truenas_scale"]

  post-processor "shell-local" {
    inline = [
      "bash ./scripts/customize-vm.sh '${var.vm_name}'",
    ]

    environment_vars = [
      format("GOVC_URL=https://%s", var.vcenter_server),
      "GOVC_USERNAME=${var.vcenter_username}",
      "GOVC_PASSWORD=${var.vcenter_password}",
      format("GOVC_INSECURE=%s", var.insecure_connection ? "1" : "0"),
      "GOVC_DATACENTER=${var.vsphere_datacenter}",
      "GUEST_PASSWORD=${var.packer_admin_password}",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "bash ./scripts/zerofill-vm.sh '${var.vm_name}'",
    ]

    environment_vars = [
      format("GOVC_URL=https://%s", var.vcenter_server),
      "GOVC_USERNAME=${var.vcenter_username}",
      "GOVC_PASSWORD=${var.vcenter_password}",
      format("GOVC_INSECURE=%s", var.insecure_connection ? "1" : "0"),
      "GOVC_DATACENTER=${var.vsphere_datacenter}",
      "GUEST_PASSWORD=${var.packer_admin_password}",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "bash ./scripts/export-ova.sh '${var.vm_name}' '${var.ova_output_dir}'",
    ]

    environment_vars = [
      format("GOVC_URL=https://%s", var.vcenter_server),
      "GOVC_USERNAME=${var.vcenter_username}",
      "GOVC_PASSWORD=${var.vcenter_password}",
      format("GOVC_INSECURE=%s", var.insecure_connection ? "1" : "0"),
      "GOVC_DATACENTER=${var.vsphere_datacenter}",
    ]
  }
}
