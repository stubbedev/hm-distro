{
  description = "home-manager on non-NixOS distros: privileged /etc installs at activation time and GL/Vulkan wrapping against the host driver";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixgl = {
      url = "github:nix-community/nixgl";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixgl,
      home-manager,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeManagerModules = {
        privileged = ./modules/privileged.nix;
        gfx = import ./modules/gfx.nix { inherit nixgl; };
        default = {
          imports = [
            self.homeManagerModules.privileged
            self.homeManagerModules.gfx
          ];
        };
      };

      checks = forAllSystems (
        pkgs:
        import ./checks {
          inherit pkgs home-manager;
          module = self.homeManagerModules.default;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
