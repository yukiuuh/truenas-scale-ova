variable "vcenter_server" {
  type = string
}

variable "vcenter_username" {
  type = string
}

variable "vcenter_password" {
  type      = string
  sensitive = true
}

variable "insecure_connection" {
  type    = bool
  default = true
}

variable "vsphere_datacenter" {
  type = string
}

variable "vsphere_cluster" {
  type = string
}

variable "vsphere_datastore" {
  type = string
}

variable "vsphere_folder" {
  type    = string
  default = ""
}

variable "vsphere_network" {
  type = string
}

variable "vsphere_resource_pool" {
  type    = string
  default = ""
}

variable "vsphere_host" {
  type    = string
  default = ""
}

variable "vm_name" {
  type    = string
  default = "truenas-scale-25.10-lab"
}

variable "vm_version" {
  type    = number
  default = 20
}

variable "vm_guest_os_type" {
  type    = string
  default = "debian12_64Guest"
}

variable "vm_firmware" {
  type    = string
  default = "efi"
}

variable "vm_cpus" {
  type    = number
  default = 4
}

variable "vm_memory_mb" {
  type    = number
  default = 8192
}

variable "boot_disk_size_mb" {
  type    = number
  default = 20480
}

variable "iso_url" {
  type    = string
  default = "https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.2.1/TrueNAS-SCALE-25.10.2.1.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "boot_wait" {
  type    = string
  default = "60s"
}

variable "installer_disk_screen_wait" {
  type    = string
  default = "5s"
}

variable "installer_warning_wait" {
  type    = string
  default = "5s"
}

variable "installer_admin_user_wait" {
  type    = string
  default = "5s"
}

variable "installer_password_screen_wait" {
  type    = string
  default = "3s"
}

variable "installer_install_complete_wait" {
  type    = string
  default = "300s"
}

variable "installer_post_install_menu_wait" {
  type    = string
  default = "5s"
}

variable "shutdown_timeout" {
  type    = string
  default = "20m"
}

variable "packer_admin_password" {
  type      = string
  sensitive = true
}

variable "installer_boot_command" {
  type    = list(string)
  default = []
}

variable "ova_output_dir" {
  type    = string
  default = "dist"
}
