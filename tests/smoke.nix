{ pkgs, package }:
pkgs.runCommand "aws-emulator-smoke"
  {
    nativeBuildInputs = [
      package
      pkgs.curl
    ];
  }
  ''
    aws-emulator -v | grep -F "Version: ${package.version}"
    export HOME=$TMPDIR
    aws-emulator -b 127.0.0.1 -p 19297 > log 2>&1 &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true' EXIT
    code=000
    for _ in $(seq 1 30); do
      code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:19297/__admin/health || true)
      [ "$code" = 200 ] && break
      sleep 1
    done
    [ "$code" = 200 ] || { cat log; exit 1; }
    grep -q 'telemetry: disabled' log
    touch $out
  ''
