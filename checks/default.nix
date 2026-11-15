{
  pkgs,
  home-manager,
  module,
}:
let
  inherit (pkgs) lib;

  example =
    extra:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        ./example.nix
        extra
      ];
    };

  configs = {
    mesa = example { distro.gpu = "mesa"; };
    nvidia = example { distro.gpu = "nvidia"; };
    disabled = example { distro.enable = false; };
  };

  activation = name: configs.${name}.activationPackage;
  gfxOf = name: configs.${name}.config.distro.gfx;
  stepNames = lib.attrNames configs.mesa.config.distro.privileged;

  disabledPassesThrough =
    let
      gfx = gfxOf "disabled";
    in
    gfx.wrap pkgs.hello == pkgs.hello && gfx.wrapExe "hello" pkgs.hello == pkgs.hello;

  behaviour =
    assert lib.assertMsg disabledPassesThrough "distro.enable = false must leave wrap/wrapExe identity";
    pkgs.runCommand "hm-distro-behaviour" { } ''
      set -euo pipefail
      check() { grep -q -- "$2" "$1" || { echo "expected '$2' in $1" >&2; exit 1; }; }
      refute() { if grep -q -- "$2" "$1"; then echo "unexpected '$2' in $1" >&2; exit 1; fi; }

      check ${(gfxOf "nvidia").wrap pkgs.hello}/bin/hello __GLX_VENDOR_LIBRARY_NAME
      check ${
        (gfxOf "nvidia").bundle {
          pkg = pkgs.hello;
          vulkan = true;
        }
      }/bin/hello VK_ADD_DRIVER_FILES
      check ${(gfxOf "mesa").wrap pkgs.hello}/bin/hello nixGLIntel
      refute ${(gfxOf "mesa").wrap pkgs.hello}/bin/hello __GLX_VENDOR_LIBRARY_NAME
      check ${(gfxOf "disabled").withDriverLibs pkgs.hello}/bin/hello /run/opengl-driver/lib
      check ${
        (gfxOf "disabled").bundle {
          pkg = pkgs.hello;
          env.GREETING = "hi";
        }
      }/bin/hello GREETING

      ${lib.concatMapStrings (step: ''
        check ${activation "mesa"}/activate hm-distro-${step}
        refute ${activation "disabled"}/activate hm-distro-${step}
      '') stepNames}

      touch $out
    '';
in
lib.mapAttrs' (name: _: lib.nameValuePair "example-${name}" (activation name)) configs
// {
  inherit behaviour;
}
