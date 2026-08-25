{
  description = "Apple container — release build (bin/, libexec/)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    systems = [ "aarch64-darwin" "x86_64-darwin" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
    version = self.shortRev or self.dirtyShortRev or "dev";

    # The nixpkgs darwin stdenv injects env vars that point at its bundled
    # apple-sdk. We need the host Xcode toolchain to pick its own matching
    # SDK, so wipe them out at the top of every build phase.
    clearDarwinStdenvEnv = ''
      unset SDKROOT DEVELOPER_DIR MACOSX_DEPLOYMENT_TARGET
      unset NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_CFLAGS_LINK
      unset CC CXX LD AR NM RANLIB STRIP
    '';
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
    in rec {
      default = container;

      # Fixed-output derivation that pre-fetches every SwiftPM dependency
      # named in Package.resolved. The main build consumes this tree so
      # it doesn't need network access. The output hash only changes when
      # Package.resolved changes.
      swiftpm-deps = pkgs.stdenvNoCC.mkDerivation {
        pname = "container-spm-deps";
        inherit version;

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Package.swift
            ./Package.resolved
          ];
        };

        __noChroot = true;
        dontConfigure = true;
        dontFixup = true;

        buildPhase = ''
          runHook preBuild
          ${clearDarwinStdenvEnv}
          export HOME=$TMPDIR
          export PATH=/usr/bin:/bin:/usr/sbin:/sbin

          /usr/bin/swift package resolve \
            --disable-sandbox \
            --cache-path "$TMPDIR/cache" \
            --config-path "$TMPDIR/config" \
            --security-path "$TMPDIR/security"

          # Strip every per-checkout .git directory. They contain a reflog
          # with timestamps and the local user's name/email, a config that
          # hard-codes absolute paths into .build/repositories, an index
          # with mtimes, and pack files whose byte layout isn't reproducible
          # — all of which made this FOD's hash drift across machines and
          # runs. The main build uses `swift build --skip-update`, which
          # only needs the source trees plus Package.resolved and
          # workspace-state.json, so the .git dirs are dead weight.
          rm -rf .build/checkouts/*/.git
          # repositories/ is just a bare-repo cache that backs `git fetch`.
          # With --skip-update the main build never reads it.
          rm -rf .build/repositories

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a .build/checkouts $out/checkouts
          [ -d .build/artifacts ] && cp -a .build/artifacts $out/artifacts || true
          [ -f .build/workspace-state.json ] && cp .build/workspace-state.json $out/workspace-state.json || true
          runHook postInstall
        '';

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-oJaBNBV2YqJGjrmTdKHW2jsNBEO0rF6znnUxTleNfm8=";
      };

      container = pkgs.stdenvNoCC.mkDerivation {
        pname = "container";
        inherit version;
        src = ./.;

        # Still depends on /usr/bin/swift, /usr/bin/swiftc, /usr/bin/git,
        # and the macOS 26 SDK from Xcode. Network is not required: SPM
        # deps come from swiftpm-deps and signing uses rcodesign.
        __noChroot = true;
        preferLocalBuild = true;
        allowSubstitutes = false;

        nativeBuildInputs = [
          pkgs.rcodesign  # replaces /usr/bin/codesign for ad-hoc signing
        ];

        dontConfigure = true;
        dontFixup = true;

        buildPhase = ''
          runHook preBuild
          ${clearDarwinStdenvEnv}
          export HOME=$TMPDIR
          export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

          # Seed the SwiftPM workspace from the FOD so the build runs offline.
          mkdir -p .build
          cp -a ${swiftpm-deps}/checkouts .build/checkouts
          [ -d ${swiftpm-deps}/artifacts ] && cp -a ${swiftpm-deps}/artifacts .build/artifacts || true
          [ -f ${swiftpm-deps}/workspace-state.json ] && cp ${swiftpm-deps}/workspace-state.json .build/workspace-state.json || true
          chmod -R u+w .build

          spm_flags="--disable-sandbox --skip-update \
            --cache-path $TMPDIR/spm-cache \
            --config-path $TMPDIR/spm-config \
            --security-path $TMPDIR/spm-security"

          echo "==> swift build (release)"
          /usr/bin/swift build -c release $spm_flags -Xswiftc -warnings-as-errors

          BUILD_BIN=$(/usr/bin/swift build -c release $spm_flags --show-bin-path)

          echo "==> signing container (rcodesign, ad-hoc)"
          rcodesign sign \
            --binary-identifier com.apple.container \
            --entitlements-xml-file signing/container.entitlements \
            "$BUILD_BIN/container"

          runHook postBuild
        '';

        # Lay out the install tree the same way `make installer-pkg` does
        # inside the .pkg Payload: a single merged `container` binary with
        # symlinks pointing at it for the apiserver and each plugin.
        installPhase = ''
          runHook preInstall

          BUILD_BIN=$(/usr/bin/swift build -c release \
            --disable-sandbox --skip-update \
            --cache-path "$TMPDIR/spm-cache" \
            --config-path "$TMPDIR/spm-config" \
            --security-path "$TMPDIR/spm-security" \
            --show-bin-path)

          mkdir -p $out/bin
          mkdir -p $out/libexec/container/plugins/container-runtime-linux/bin
          mkdir -p $out/libexec/container/plugins/container-network-vmnet/bin
          mkdir -p $out/libexec/container/plugins/container-core-images/bin
          mkdir -p $out/libexec/container/plugins/machine-apiserver/bin
          mkdir -p $out/libexec/container/plugins/machine-apiserver/resources
          mkdir -p $out/libexec/container/plugins/k8s/bin
          mkdir -p $out/libexec/container/plugins/k8s/resources

          install "$BUILD_BIN/container" $out/bin/container
          ln -sf container $out/bin/container-apiserver

          ln -sf ../../../../../bin/container \
            $out/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux
          install Sources/Plugins/RuntimeLinux/config.toml \
            $out/libexec/container/plugins/container-runtime-linux/config.toml

          ln -sf ../../../../../bin/container \
            $out/libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet
          install Sources/Plugins/NetworkVmnet/config.toml \
            $out/libexec/container/plugins/container-network-vmnet/config.toml

          ln -sf ../../../../../bin/container \
            $out/libexec/container/plugins/container-core-images/bin/container-core-images
          install Sources/Plugins/CoreImages/config.toml \
            $out/libexec/container/plugins/container-core-images/config.toml

          ln -sf ../../../../../bin/container \
            $out/libexec/container/plugins/machine-apiserver/bin/machine-apiserver
          install Sources/Plugins/MachineAPIServer/config.toml \
            $out/libexec/container/plugins/machine-apiserver/config.toml
          install Sources/Plugins/MachineAPIServer/Resources/init \
            $out/libexec/container/plugins/machine-apiserver/resources/init
          install Sources/Plugins/MachineAPIServer/Resources/create-user.sh \
            $out/libexec/container/plugins/machine-apiserver/resources/create-user.sh

          install "$BUILD_BIN/k8s" $out/libexec/container/plugins/k8s/bin/k8s
          install Sources/Plugins/K8s/config.toml \
            $out/libexec/container/plugins/k8s/config.toml
          install Sources/Plugins/K8s/Resources/kindnet.yaml \
            $out/libexec/container/plugins/k8s/resources/kindnet.yaml

          install scripts/update-container.sh    $out/bin/update-container.sh
          install scripts/uninstall-container.sh $out/bin/uninstall-container.sh

          install -m 644 LICENSE   $out/LICENSE
          install -m 644 NOTICE.md $out/NOTICE.md

          runHook postInstall
        '';
      };
    });
  };
}
