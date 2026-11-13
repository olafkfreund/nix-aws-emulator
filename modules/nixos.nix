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
  isLoopback = lib.elem cfg.bindAddress [
    "127.0.0.1"
    "::1"
  ];
  probeHost =
    if cfg.bindAddress == "0.0.0.0" then
      "127.0.0.1"
    else if cfg.bindAddress == "::" then
      "[::1]"
    else if lib.hasPrefix "[" cfg.bindAddress then
      cfg.bindAddress
    else if lib.hasInfix ":" cfg.bindAddress then
      "[${cfg.bindAddress}]"
    else
      cfg.bindAddress;
  portDir = "/run/aws-emulator/.aws/emulator/${toString cfg.port}";
  ready = pkgs.writeShellScript "aws-emulator-ready" ''
    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      code=$(${lib.getExe pkgs.curl} -skg --connect-timeout 2 --max-time 3 -o /dev/null -w '%{http_code}' "https://${probeHost}:${toString cfg.port}/__admin/health" || true)
      if [ "$code" = 200 ] && [ -e ${portDir}/config ]; then
        ${pkgs.coreutils}/bin/chmod -R g+rX /run/aws-emulator/.aws
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "aws-emulator not healthy after 30 s" >&2
    exit 1
  '';
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
    openFirewall = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Open the listening port in the firewall.";
    };
    group = lib.mkOption {
      type = types.str;
      default = "aws-emulator";
      description = "Group allowed to read AWS Emulator connection files.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bindAddress != "localhost";
        message = "services.aws-emulator.bindAddress must be an IP address; the emulator rejects \"localhost\". Use \"127.0.0.1\".";
      }
    ];
    users.users.aws-emulator = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups = lib.mkIf (cfg.group == "aws-emulator") { aws-emulator = { }; };

    systemd.services.aws-emulator = {
      description = "AWS Emulator";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        HOME = "/run/aws-emulator";
        EMULATOR_TELEMETRY = if cfg.telemetry then "on" else "off";
      };
      serviceConfig = {
        Type = "exec";
        User = "aws-emulator";
        Group = cfg.group;
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs args}";
        ExecStartPost = "${ready}";
        Restart = "on-failure";
        RestartSec = "5s";
        RuntimeDirectory = "aws-emulator";
        RuntimeDirectoryMode = "0750";
        UMask = "0027";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
    warnings =
      lib.optional (
        !isLoopback && cfg.auth
      ) "AWS Emulator listens on ${cfg.bindAddress}; anyone who can reach it and has the keys can use it"
      ++
        lib.optional (!isLoopback && !cfg.auth)
          "AWS Emulator listens on ${cfg.bindAddress} WITHOUT authentication; anyone who can reach the port can use it and exhaust memory"
      ++ lib.optional (
        cfg.openFirewall && isLoopback
      ) "AWS Emulator openFirewall has no effect while bindAddress is loopback";
  };
}
