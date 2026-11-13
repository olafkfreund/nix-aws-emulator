{
  description = "AWS Emulator packaged for NixOS, with NixOS and Home Manager modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: prev: {
        aws-emulator = final.callPackage ./pkgs/aws-emulator/package.nix { };
      };

      packages = forAllSystems (pkgs: rec {
        aws-emulator = pkgs.callPackage ./pkgs/aws-emulator/package.nix { };
        default = aws-emulator;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          meta.description = "Run AWS Emulator";
        };
      });

      nixosModules = {
        aws-emulator = ./modules/nixos.nix;
        default = self.nixosModules.aws-emulator;
      };

      homeManagerModules = {
        aws-emulator = ./modules/home-manager.nix;
        default = self.homeManagerModules.aws-emulator;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      checks = forAllSystems (
        pkgs:
        {
          smoke = import ./tests/smoke.nix {
            inherit pkgs;
            package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          };
          format = pkgs.runCommand "format-check" {
            nativeBuildInputs = [
              pkgs.nixfmt
              pkgs.findutils
            ];
          } "cd ${self} && find . -name '*.nix' -exec nixfmt --check {} + && touch $out";
        }
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          nixos = import ./tests/nixos.nix { inherit pkgs self home-manager; };
        }
      );
    };
}
