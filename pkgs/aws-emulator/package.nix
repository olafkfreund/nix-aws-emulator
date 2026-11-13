{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
}:
let
  sources = lib.importJSON ./sources.json;
  system = stdenv.hostPlatform.system;
  src = sources.${system} or (throw "aws-emulator: unsupported system ${system}");
in
stdenv.mkDerivation {
  pname = "aws-emulator";
  inherit (sources) version;

  src = fetchurl { inherit (src) url hash; };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];
  runtimeDependencies = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 opt/aws-emulator/bin/aws-emulator $out/libexec/aws-emulator/aws-emulator
    install -Dm644 opt/aws-emulator/THIRD_PARTY_LICENSES $out/share/doc/aws-emulator/THIRD_PARTY_LICENSES
    makeWrapper $out/libexec/aws-emulator/aws-emulator $out/bin/aws-emulator \
      --set-default EMULATOR_TELEMETRY off
    runHook postInstall
  '';

  passthru.updateScript = ../../scripts/update.sh;

  meta = {
    description = "Local emulator of the AWS APIs";
    homepage = "https://github.com/aws/aws-emulator";
    changelog = "https://github.com/aws/aws-emulator/releases/tag/v${sources.version}";
    mainProgram = "aws-emulator";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = with lib.licenses; [
      cc0
      mit
      asl20
      bsd0
      bsd2
      bsd3
      isc
      zlib
      unicode-30
      boost
      unlicense
      mit0
      lgpl3Only
      psfl
      bzip2
      blueOak100
    ];
  };
}
