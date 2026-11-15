{ pkgs }:
{
  name,
  probe,
  nvidia,
  mesa,
}:
pkgs.writeTextFile {
  inherit name;
  destination = "/bin/${name}";
  executable = true;
  text = ''
    #!${pkgs.runtimeShell}
    if [ -e ${pkgs.lib.escapeShellArg probe} ]; then
      exec -a "$0" ${nvidia} "$@"
    fi
    exec -a "$0" ${mesa} "$@"
  '';
  checkPhase = ''
    ${pkgs.stdenv.shellDryRun} "$target"
    ${pkgs.lib.getExe pkgs.shellcheck} "$target"
  '';
  meta.mainProgram = name;
}
