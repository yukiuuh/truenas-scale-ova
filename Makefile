SHELL := bash

PKR_VAR_FILE ?= packer/truenas.auto.pkrvars.hcl
OVA_OUTPUT_DIR ?= dist
REPLACE_VM ?= 1
NIX_DEV := NIXPKGS_ALLOW_UNFREE=1 nix develop --impure -c

.PHONY: init fmt validate build customize export deploy all

init:
	$(NIX_DEV) packer init packer

fmt:
	$(NIX_DEV) packer fmt -recursive .

validate:
	$(NIX_DEV) packer validate -var-file=$(PKR_VAR_FILE) packer

build:
	$(NIX_DEV) packer build -force -var-file=$(PKR_VAR_FILE) -var "ova_output_dir=$(OVA_OUTPUT_DIR)" packer

customize:
	PKR_VAR_FILE=$(PKR_VAR_FILE) VM_NAME="$(VM_NAME)" $(NIX_DEV) ./scripts/customize-vm.sh

export:
	PKR_VAR_FILE=$(PKR_VAR_FILE) VM_NAME="$(VM_NAME)" OVA_OUTPUT_DIR=$(OVA_OUTPUT_DIR) $(NIX_DEV) ./scripts/export-ova.sh

deploy:
	PKR_VAR_FILE=$(PKR_VAR_FILE) VM_NAME="$(VM_NAME)" REPLACE_VM=$(REPLACE_VM) INIT_SCRIPT_PATH="$(INIT_SCRIPT_PATH)" $(NIX_DEV) ./scripts/deploy-ova.sh $(OVA_PATH)

all: build
