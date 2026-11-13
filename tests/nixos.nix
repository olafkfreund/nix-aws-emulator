{
  pkgs,
  self,
  home-manager,
}:
pkgs.testers.runNixOSTest {
  name = "aws-emulator";
  node.pkgsReadOnly = false;

  nodes.machine = {
    imports = [
      self.nixosModules.default
      home-manager.nixosModules.home-manager
    ];
    nixpkgs.overlays = [ self.overlays.default ];
    virtualisation.memorySize = 2048;

    services.aws-emulator.enable = true;

    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "aws-emulator" ];
    };
    users.users.carol.isNormalUser = true;
    users.users.bob = {
      isNormalUser = true;
      linger = true;
    };

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.bob = {
      imports = [ self.homeManagerModules.default ];
      services.aws-emulator = {
        enable = true;
        port = 9298;
      };
      home.stateVersion = "25.11";
    };

    environment.systemPackages = [
      pkgs.awscli2
      pkgs.curl
    ];
  };

  testScript = ''
    d = "/run/aws-emulator/.aws/emulator/9297"
    env = f"AWS_CONFIG_FILE={d}/config AWS_SHARED_CREDENTIALS_FILE={d}/emulator_credentials"
    machine.wait_for_unit("aws-emulator.service")
    machine.succeed("curl -sfk https://127.0.0.1:9297/__admin/health")
    machine.succeed(f"su - alice -c 'cat {d}/emulator_credentials >/dev/null'")
    machine.succeed(f"su - alice -c '{env} aws s3 mb s3://emulator-test'")
    machine.succeed(f"su - alice -c '{env} aws s3 ls' | grep emulator-test")
    machine.fail(f"su - carol -c 'cat {d}/emulator_credentials'")
    machine.succeed("journalctl -u aws-emulator | grep -q 'telemetry: disabled'")
    uid = machine.succeed("id -u bob").strip()
    machine.wait_for_unit("home-manager-bob.service")
    machine.wait_for_unit(f"user@{uid}.service")
    bob = f"su - bob -c 'XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user"
    machine.wait_until_succeeds(f"{bob} is-active aws-emulator'")
    machine.wait_until_succeeds("curl -sfk https://127.0.0.1:9298/__admin/health")
    machine.succeed(f"{bob} stop aws-emulator'")
    machine.fail("test -e /home/bob/.aws/emulator/9298/config")
  '';
}
