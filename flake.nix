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

          # SwiftPM clones each checkout with git alternates pointing into
          # .build/repositories. Repack each .git so the checkouts are
          # self-contained, then drop the alternates file. Without this the
          # main derivation can't relocate .build/checkouts.
          for d in .build/checkouts/*/; do
            /usr/bin/git -C "$d" repack -ad -q 2>/dev/null || true
            rm -f "$d/.git/objects/info/alternates"
          done

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a .build/checkouts $out/checkouts
          [ -d .build/repositories ] && cp -a .build/repositories $out/repositories || true
          [ -d .build/artifacts ] && cp -a .build/artifacts $out/artifacts || true
          [ -f .build/workspace-state.json ] && cp .build/workspace-state.json $out/workspace-state.json || true
          runHook postInstall
        '';

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-gqZ+x/q7gc0/Gvz0vugM8JL8o8qBChKu8gog+or3Hag=";
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
          [ -d ${swiftpm-deps}/repositories ] && cp -a ${swiftpm-deps}/repositories .build/repositories || true
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
