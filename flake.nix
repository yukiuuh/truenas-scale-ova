{
  description = "TrueNAS SCALE OVA build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        lib = nixpkgs.lib;
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [ "packer" ];
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            coreutils
            curl
            gnused
            gnutar
            govc
            jq
            packer
            python3
          ];
        };
      });
}
