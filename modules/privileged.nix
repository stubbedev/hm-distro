{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.distro;
  esc = lib.escapeShellArg;
  coreutils = lib.getBin pkgs.coreutils;
  lockDir = "${config.xdg.stateHome}/hm-distro";

  helpers = rec {
    file =
      {
        source,
        target,
        mode ? "0644",
        owner ? "root",
        group ? "root",
      }:
      ''
        sudo install -D -m ${esc mode} -o ${esc owner} -g ${esc group} ${esc "${source}"} ${esc target}
      '';

    link =
      { source, target }:
      ''
        sudo install -d -m 0755 ${esc (dirOf target)}
        sudo ln -sfT ${esc "${source}"} ${esc target}
      '';

    text =
      {
        name,
        text,
        ...
      }@args:
      file (
        removeAttrs args [
          "name"
          "text"
        ]
        // {
          source = pkgs.writeText name text;
        }
      );

    hostPackage =
      {
        detect ? null,
        have ? (
          assert lib.assertMsg (detect != null) "lib.distro.hostPackage: pass `detect` or `have`";
          "command -v ${esc detect} >/dev/null 2>&1"
        ),
        apt,
        dnf,
        pacman,
      }:
      ''
        if ! { ${have}; }; then
          if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y --no-install-recommends ${lib.escapeShellArgs apt}
          elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y --setopt=install_weak_deps=False ${lib.escapeShellArgs dnf}
          elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -S --needed --noconfirm ${lib.escapeShellArgs pacman}
          else
            echo "hm-distro: no supported package manager (apt-get, dnf, pacman) found" >&2
            exit 1
          fi
        fi
      '';

    reloadUnits = ''
      if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl daemon-reload
      fi
    '';

    reloadUdev = ''
      if command -v udevadm >/dev/null 2>&1; then
        sudo udevadm control --reload-rules
      fi
    '';

    polkitRule =
      { source, target }:
      ''
        ${file { inherit source target; }}
        if getent group polkitd >/dev/null 2>&1; then
          sudo chown root:polkitd ${esc target}
        fi
      '';

    requireCommand = cmd: ''
      if ! command -v ${esc cmd} >/dev/null 2>&1; then
        exit 0
      fi
    '';

    requirePath = path: ''
      if [ ! -e ${esc path} ]; then
        exit 0
      fi
    '';

    apparmor =
      {
        appName,
        profileName,
        programGlob,
      }:
      {
        preCheck = requireCommand "apparmor_status";
        title = "Installing AppArmor profile for Nix-installed ${appName}";
        body = ''
          Ubuntu 24.04+ only grants unprivileged user namespaces and clean
          AppArmor profile transitions to binaries with a named profile.
          Nix-store paths aren't covered by the stock profiles, so the
          Nix-store ${appName} runs as "unprivileged unconfined" and is
          restricted.

          This installs a named, otherwise unconfined AppArmor profile for
          the Nix-store ${appName} binaries.
        '';
        script = ''
          ${text {
            name = profileName;
            target = "/etc/apparmor.d/${profileName}";
            text = ''
              # managed-by: hm-distro ${profileName}
              abi <abi/4.0>,
              include <tunables/global>
              profile ${profileName} ${programGlob} flags=(unconfined) {
                userns,
                ${programGlob} mr,
                include if exists <local/${profileName}>
              }
            '';
          }}
          sudo apparmor_parser -r ${esc "/etc/apparmor.d/${profileName}"}
        '';
      };
  };

  stepScript =
    name: step:
    pkgs.writeShellApplication {
      name = "hm-distro-${name}";
      text = ''
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

        if (exec >/dev/tty) 2>/dev/null; then
          exec >/dev/tty 2>&1
        fi

        if ! command -v sudo >/dev/null 2>&1; then
          echo ${esc "hm-distro-${name}: sudo not found; this privileged step cannot run"} >&2
          exit 1
        fi

        stateInputs=(${lib.escapeShellArgs step.stateInputs})
        stateHash=$(
          for p in "''${stateInputs[@]}"; do
            if [ -e "$p" ]; then printf '%s:1\n' "$p"; else printf '%s:0\n' "$p"; fi
          done | ${coreutils}/bin/sha256sum | ${coreutils}/bin/cut -d' ' -f1
        )
        combinedHash=${builtins.hashString "sha256" step.script}:$stateHash

        lockFile=${esc "${lockDir}/${name}.sum"}
        if [ -f "$lockFile" ] && [ "$(< "$lockFile")" = "$combinedHash" ]; then
          exit 0
        fi

        ${step.preCheck}

        echo
        echo "--------------------------------------------------------------------"
        printf '%s\n' ${esc step.title}
        echo "--------------------------------------------------------------------"
        echo
        ${lib.optionalString (step.body != "") "printf '%s\\n' ${esc step.body}"}

        ${step.script}

        ${coreutils}/bin/mkdir -p ${esc lockDir}
        printf '%s' "$combinedHash" > "$lockFile.tmp"
        ${coreutils}/bin/mv -f "$lockFile.tmp" "$lockFile"
        echo
      '';
    };

  stepType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to run this step.";
        };

        script = lib.mkOption {
          type = lib.types.lines;
          description = ''
            The shell to run, under `set -euo pipefail`, with `sudo` on PATH.
            Must be idempotent; it re-runs whenever its text or the existence
            of a `stateInputs` path changes.
          '';
        };

        after = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra `home.activation` DAG nodes to order after, besides `writeBoundary`.";
        };

        title = lib.mkOption {
          type = lib.types.str;
          default = "Installing ${name}";
          defaultText = lib.literalMD "`Installing <name>`";
          description = "Banner shown before the sudo prompt.";
        };

        body = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "What the step is about to do and why, shown under the banner.";
        };

        preCheck = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            Guard run before the banner and the sudo prompt; `exit 0` skips the
            step. See `config.lib.distro.requireCommand` and `requirePath`.
          '';
        };

        stateInputs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Paths whose existence is part of the step's input: the lock is
            invalidated whenever one of them appears or disappears.
          '';
        };
      };
    }
  );
in
{
  imports = [ ./enable.nix ];

  options.distro.privileged = lib.mkOption {
    type = lib.types.attrsOf stepType;
    default = { };
    description = ''
      Activation steps that write host state outside $HOME through sudo,
      keyed by `home.activation` DAG node name. Skipped while their script
      and state inputs are unchanged since the last successful run.
    '';
  };

  config = {
    lib.distro = helpers;

    home.activation = lib.mkIf cfg.enable (
      lib.mapAttrs (
        name: step:
        lib.hm.dag.entryAfter ([ "writeBoundary" ] ++ step.after) "run ${lib.getExe (stepScript name step)}"
      ) (lib.filterAttrs (_: s: s.enable) cfg.privileged)
    );
  };
}
