{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.lib) distro;
  inherit (config.distro) gfx;
in
{
  home = {
    username = "example";
    homeDirectory = "/home/example";
    stateVersion = "25.11";

    packages = [
      (gfx.wrap pkgs.alacritty)
      (gfx.wrapExe "eglinfo" pkgs.mesa-demos)
      (gfx.withDriverLibs pkgs.btop)
      (gfx.bundle {
        pkg = pkgs.mpv;
        vulkan = true;
        flags = [ "--hwdec=auto" ];
        env.MPV_HOME = "${config.xdg.configHome}/mpv";
        unset = [ "LD_PRELOAD" ];
        prefix.PATH = lib.makeBinPath [ pkgs.yt-dlp ];
        run = [ "true" ];
      })
    ];
  };

  distro.privileged = {
    udevRules = {
      body = "Lets the user's group access the example device.";
      preCheck = distro.requireCommand "udevadm";
      stateInputs = [ "/etc/udev/rules.d" ];
      script = ''
        ${distro.text {
          name = "70-example.rules";
          target = "/etc/udev/rules.d/70-example.rules";
          text = ''
            # managed-by: hm-distro udevRules
            SUBSYSTEM=="usb", ATTRS{idVendor}=="1234", TAG+="uaccess"
          '';
        }}
        ${distro.reloadUdev}
      '';
    };

    swayUnit = {
      after = [ "udevRules" ];
      preCheck = distro.requirePath "/etc/systemd/system";
      script = ''
        ${distro.hostPackage {
          detect = "swaylock";
          apt = [ "swaylock" ];
          dnf = [ "swaylock" ];
          pacman = [ "swaylock" ];
        }}
        ${distro.hostPackage {
          have = "[ -e /etc/pam.d/swaylock ]";
          apt = [ "swaylock" ];
          dnf = [ "swaylock" ];
          pacman = [ "swaylock" ];
        }}
        ${distro.file {
          source = pkgs.writeText "example.service" "[Service]\nExecStart=${lib.getExe pkgs.hello}\n";
          target = "/etc/systemd/system/example.service";
        }}
        ${distro.link {
          source = "/etc/systemd/system/example.service";
          target = "/etc/systemd/system/multi-user.target.wants/example.service";
        }}
        ${distro.polkitRule {
          source = pkgs.writeText "50-example.rules" "polkit.addRule(function () {});\n";
          target = "/etc/polkit-1/rules.d/50-example.rules";
        }}
        ${distro.reloadUnits}
      '';
    };

    mpvApparmor = distro.apparmor {
      appName = "mpv";
      profileName = "nix-mpv";
      programGlob = "/nix/store/*-mpv-*/bin/{mpv,.mpv-wrapped}";
    };
  };
}
