{ config, lib, ... }:
{
  options.distro.enable = lib.mkOption {
    type = lib.types.bool;
    default = !config.submoduleSupport.enable;
    defaultText = lib.literalExpression "!config.submoduleSupport.enable";
    description = ''
      Whether this home-manager configuration runs on a foreign (non-NixOS)
      distro. When false, privileged steps are not rendered and the gfx
      wrappers pass programs through unchanged.
    '';
  };
}
