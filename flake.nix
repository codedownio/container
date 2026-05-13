{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    packages = nixpkgs.lib.genAttrs [ "aarch64-darwin" ] (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      version = self.shortRev or self.dirtyShortRev or "dev";
    in
      {
        default = self.packages.${system}.installer-pkg;

        installer-pkg = pkgs.stdenvNoCC.mkDerivation {
          pname = "container-installer-pkg";
          inherit version;
          src = ./.;

          # The build shells out to /usr/bin/swift (Xcode toolchain),
          # /usr/bin/pkgbuild, and /usr/bin/codesign — none of which are in
          # nixpkgs — and SPM fetches dependencies from GitHub. Disable the
          # build sandbox so the build can reach the host toolchain and the
          # network. Requires `sandbox = relaxed` (the default on macOS).
          __noChroot = true;
          preferLocalBuild = true;
          allowSubstitutes = false;

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            runHook preBuild

            # Drop nixpkgs's darwin-stdenv env vars that point at the bundled
            # apple-sdk; let Xcode's swiftc pick its own SDK and toolchain.
            unset SDKROOT DEVELOPER_DIR MACOSX_DEPLOYMENT_TARGET
            unset NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_CFLAGS_LINK
            unset CC CXX LD AR NM RANLIB STRIP

            export HOME=$TMPDIR
            export PATH=/usr/bin:/bin:/usr/sbin:/sbin
            export RELEASE_VERSION=${version}

            # SwiftPM normally wraps manifest evaluation and build steps in
            # sandbox-exec, but nixbld users can't call sandbox_apply. Disable
            # the sandbox and point SwiftPM at writable cache/config/security
            # paths so it doesn't try to use $HOME (which it derives from
            # getpwuid rather than $HOME).
            spm_flags="--disable-sandbox \
              --cache-path $TMPDIR/spm-cache \
              --config-path $TMPDIR/spm-config \
              --security-path $TMPDIR/spm-security"
            swift_cfg="$spm_flags -Xswiftc -warnings-as-errors"

            make BUILD_CONFIGURATION=release SWIFT_CONFIGURATION="$swift_cfg" build
            make BUILD_CONFIGURATION=release SWIFT_CONFIGURATION="$swift_cfg" installer-pkg

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp bin/release/container-installer-unsigned.pkg $out/
            runHook postInstall
          '';
        };
      });
  };
}
