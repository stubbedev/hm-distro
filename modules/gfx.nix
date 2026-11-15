{ nixgl }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.distro;
  unwrapped = !cfg.enable;
  isx86_64 = pkgs.stdenv.hostPlatform.isx86_64;
  multiarch = "/usr/lib/${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-gnu";

  nixGL = pkgs.callPackage "${nixgl}/nixGL.nix" (
    { enable32bits = isx86_64; } // lib.optionalAttrs (!isx86_64) { intel-media-driver = null; }
  );

  searchPath = lib.concatStringsSep ":";

  gbmBackendsPath = searchPath [
    "${multiarch}/gbm"
    "${multiarch}/nvidia/current"
    "/usr/lib64/gbm"
    "/usr/lib/gbm"
    "/run/opengl-driver/lib/gbm"
    "/run/opengl-driver-32/lib/gbm"
  ];

  libglDriversPath = searchPath [
    "${multiarch}/dri"
    "/usr/lib64/dri"
    "/usr/lib/dri"
    "/run/opengl-driver/lib/dri"
    "/run/opengl-driver-32/lib/dri"
  ];

  hostDriverLibs = searchPath [
    multiarch
    "${multiarch}/nvidia/current"
    "/usr/lib64/nvidia"
    "/usr/lib64"
    "/usr/lib"
  ];

  eglExternalPlatforms = searchPath [
    "/usr/share/egl/egl_external_platform.d"
    "${pkgs.egl-wayland}/share/egl/egl_external_platform.d/10_nvidia_wayland.json"
    "${pkgs.egl-gbm}/share/egl/egl_external_platform.d/15_nvidia_gbm.json"
  ];

  nvidiaVulkanIcds = searchPath [
    "/usr/share/vulkan/icd.d/nvidia_icd.json"
    "/etc/vulkan/icd.d/nvidia_icd.json"
  ];

  commonArgs = [
    "--suffix"
    "GBM_BACKENDS_PATH"
    ":"
    gbmBackendsPath
    "--suffix"
    "LIBGL_DRIVERS_PATH"
    ":"
    libglDriversPath
  ];

  makeGLWrapper =
    { vulkan }:
    name: programPath:
    let
      args =
        if cfg.gpu == "nvidia" then
          [
            programPath
            "${placeholder "out"}/bin/${name}"
            "--set"
            "__GLX_VENDOR_LIBRARY_NAME"
            "nvidia"
            "--suffix"
            "__EGL_VENDOR_LIBRARY_FILENAMES"
            ":"
            "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
            "--suffix"
            "__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES"
            ":"
            eglExternalPlatforms
            "--suffix"
            "LD_LIBRARY_PATH"
            ":"
            hostDriverLibs
          ]
          ++ commonArgs
          ++ lib.optionals vulkan [
            "--suffix"
            "VK_ADD_DRIVER_FILES"
            ":"
            nvidiaVulkanIcds
          ]
        else
          [
            "${nixGL.nixGLIntel}/bin/${nixGL.nixGLIntel.name}"
            "${placeholder "out"}/bin/${name}"
          ]
          ++ commonArgs
          ++ lib.optionals vulkan [
            "--add-flag"
            "${nixGL.nixVulkanIntel}/bin/${nixGL.nixVulkanIntel.name}"
          ]
          ++ [
            "--add-flag"
            programPath
          ];
    in
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      makeWrapper ${lib.escapeShellArgs args}
    '';

  glWrapper = makeGLWrapper { vulkan = false; };
  vulkanWrapper = makeGLWrapper { vulkan = true; };

  linkAs =
    name: exe:
    pkgs.runCommand name { } ''
      mkdir -p $out/bin
      ln -s ${lib.escapeShellArg exe} $out/bin/${lib.escapeShellArg name}
    '';

  wrapAs =
    wrapper: name: program:
    if unwrapped then linkAs name (lib.getExe program) else wrapper name (lib.getExe program);

  wrapExeWith =
    wrapper: exeName: program:
    if unwrapped then program else wrapper exeName (lib.getExe' program exeName);

  wrap =
    program:
    if unwrapped then
      program
    else
      let
        exe = lib.getExe program;
      in
      glWrapper (baseNameOf exe) exe;

  wrapExe = wrapExeWith glWrapper;

  withDriverLibs =
    program:
    let
      name = baseNameOf (lib.getExe program);
    in
    if unwrapped then
      pkgs.symlinkJoin {
        inherit name;
        paths = [ program ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/${lib.escapeShellArg name} \
            --suffix LD_LIBRARY_PATH : /run/opengl-driver/lib
        '';
      }
    else
      glWrapper name (lib.getExe program);

  bundle =
    {
      pkg,
      exes ? null,
      gfx ? true,
      vulkan ? false,
      flags ? [ ],
      env ? { },
      unset ? [ ],
      prefix ? { },
      run ? [ ],
      includeUpstream ? true,
    }:
    let
      exeList = if exes == null then [ (baseNameOf (lib.getExe pkg)) ] else exes;
      mainExe = builtins.head exeList;

      wrapper = if vulkan then vulkanWrapper else glWrapper;
      gfxOf = exe: if exe == mainExe then wrapAs wrapper exe pkg else wrapExeWith wrapper exe pkg;
      sourceFor = exe: if gfx then "${gfxOf exe}/bin/${exe}" else lib.getExe' pkg exe;

      wrapperArgs = lib.concatLists [
        (lib.concatMap (f: [
          "--add-flags"
          f
        ]) flags)
        (lib.concatLists (
          lib.mapAttrsToList (k: v: [
            "--set"
            k
            v
          ]) env
        ))
        (lib.concatMap (k: [
          "--unset"
          k
        ]) unset)
        (lib.concatLists (
          lib.mapAttrsToList (k: v: [
            "--prefix"
            k
            ":"
            v
          ]) prefix
        ))
        (lib.concatMap (c: [
          "--run"
          c
        ]) run)
      ];

      wrapOne =
        exe:
        if wrapperArgs != [ ] then
          pkgs.runCommand "${exe}-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
            makeWrapper ${
              lib.escapeShellArgs (
                [
                  (sourceFor exe)
                  "${placeholder "out"}/bin/${exe}"
                ]
                ++ wrapperArgs
              )
            }
          ''
        else if gfx then
          gfxOf exe
        else
          linkAs exe (lib.getExe' pkg exe);
    in
    pkgs.symlinkJoin {
      name = "${lib.getName pkg}-${pkg.version or "wrapped"}";
      paths = map wrapOne exeList ++ lib.optional includeUpstream pkg;
      meta = (pkg.meta or { }) // {
        mainProgram = mainExe;
        outputsToInstall = [ "out" ];
      };
    };

  fnOption =
    type: description:
    lib.mkOption {
      inherit type description;
      readOnly = true;
    };
  fn = lib.types.functionTo lib.types.package;
in
{
  imports = [ ./enable.nix ];

  options.distro = {
    gpu = lib.mkOption {
      type = lib.types.enum [
        "mesa"
        "nvidia"
      ];
      default = "mesa";
      description = ''
        The host's display driver stack. `nvidia` dispatches through glvnd to
        the vendor libraries the distro driver package installed; `mesa` runs
        programs under nixGLIntel (Mesa from nixpkgs).
      '';
    };

    gfx = {
      wrap = fnOption fn "`wrap pkg`: the package's mainProgram, wrapped for GL under its own name.";
      wrapExe = fnOption (lib.types.functionTo fn) "`wrapExe exeName pkg`: one named binary of a package, wrapped for GL.";
      withDriverLibs = fnOption fn "`withDriverLibs pkg`: let a non-GL tool dlopen GPU vendor libraries by soname.";
      bundle = fnOption fn "`bundle { pkg, ... }`: wrap selected binaries of a package and symlinkJoin them with upstream.";
    };
  };

  config.distro.gfx = {
    inherit
      wrap
      wrapExe
      withDriverLibs
      bundle
      ;
  };
}
