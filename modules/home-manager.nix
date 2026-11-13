{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aws-emulator;
  types = lib.types;
  args = [
    "-b"
    cfg.bindAddress
    "-p"
    (toString cfg.port)
    "-a"
    (if cfg.auth then "on" else "off")
  ]
  ++ lib.optionals (cfg.idleTimeout != null) [
    "--idle-timeout"
    (toString cfg.idleTimeout)
  ]
  ++ cfg.extraArgs;
in
{
  options.services.aws-emulator = {
    enable = lib.mkEnableOption "AWS Emulator, a local emulator of the AWS APIs";
    package = lib.mkOption {
      type = types.package;
      default = pkgs.aws-emulator or (pkgs.callPackage ../pkgs/aws-emulator/package.nix { });
      defaultText = lib.literalExpression "pkgs.aws-emulator";
      description = "AWS Emulator package to run.";
    };
    bindAddress = lib.mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address on which AWS Emulator listens.";
    };
    port = lib.mkOption {
      type = types.ints.between 1024 65535;
      default = 9297;
      description = "Port on which AWS Emulator listens.";
    };
    telemetry = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Whether to enable AWS Emulator telemetry.";
    };
    auth = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to require authentication.";
    };
    idleTimeout = lib.mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Exit successfully after this many idle seconds and stay stopped.";
    };
    extraArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra command line arguments for AWS Emulator.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bindAddress != "localhost";
        message = "services.aws-emulator.bindAddress must be an IP address; the emulator rejects \"localhost\". Use \"127.0.0.1\".";
      }
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "services.aws-emulator is only supported on Linux";
      }
    ];
    home.packages = [ cfg.package ];
    systemd.user.services.aws-emulator = {
      Unit.Description = "AWS Emulator";
      Service = {
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs args}";
        Environment = [ "EMULATOR_TELEMETRY=${if cfg.telemetry then "on" else "off"}" ];
        Restart = "on-failure";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
