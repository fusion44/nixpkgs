{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  lib,
}:

stdenv.mkDerivation rec {
  pname = "confluent-cli";
  version = "4.16.0";

  # To get the latest version:
  # curl -L https://cnfl.io/cli | sh -s -- -l | grep -v latest | sort -V | tail -n1
  src =
    {
      x86_64-linux = fetchurl {
        url = "https://s3-us-west-2.amazonaws.com/confluent.cloud/confluent-cli/archives/${version}/confluent_${version}_linux_amd64.tar.gz";
        hash = "sha256-OFmbIqyDnZxymutdObzPvyuHJnfW353e+ChjDLfhQvI=";
      };
      aarch64-linux = fetchurl {
        url = "https://s3-us-west-2.amazonaws.com/confluent.cloud/confluent-cli/archives/${version}/confluent_${version}_linux_arm64.tar.gz";
        hash = "sha256-EZ+3WYIkmP5Aw3yg4fKUs805W58OFrILjp+Z18G6jjQ=";
      };
      x86_64-darwin = fetchurl {
        url = "https://s3-us-west-2.amazonaws.com/confluent.cloud/confluent-cli/archives/${version}/confluent_${version}_darwin_amd64.tar.gz";
        hash = "sha256-ogqrGn0I34L+UIzA+9Q+3LlcVoDlYnPRUqkn9oasCG8=";
      };
      aarch64-darwin = fetchurl {
        url = "https://s3-us-west-2.amazonaws.com/confluent.cloud/confluent-cli/archives/${version}/confluent_${version}_darwin_arm64.tar.gz";
        hash = "sha256-CQNGs8tFSUH3okFufVPUQqHTrVB3kyrbbgT9mFGmkYc=";
      };
    }
    .${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  dontStrip = stdenv.hostPlatform.isDarwin;

  installPhase = ''
    mkdir -p $out/{bin,share/doc/confluent-cli}
    cp confluent $out/bin/
    cp LICENSE $out/share/doc/confluent-cli/
    cp -r legal $out/share/doc/confluent-cli/
  '';

  meta = with lib; {
    description = "Confluent CLI";
    homepage = "https://docs.confluent.io/confluent-cli/current/overview.html";
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    license = licenses.unfreeRedistributable;
    maintainers = with maintainers; [
      rguevara84
      autophagy
    ];

    # TODO: There's support for i686 systems but I do not have any such system
    # to build it locally on, it's also unfree so I cannot rely on ofborg to
    # build it. Get the list of supported system by looking at the list of
    # files in the S3 bucket:
    #
    #   https://s3-us-west-2.amazonaws.com/confluent.cloud?prefix=confluent-cli/archives/1.25.0/&delimiter=/%27
    platforms = platforms.unix;
  };
}
