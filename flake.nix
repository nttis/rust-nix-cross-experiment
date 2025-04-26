{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-utils = {
      url = "github:numtide/flake-utils";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import inputs.nixpkgs {
        system = system;
        overlays = [inputs.rust-overlay.overlays.default];
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      toolchain = pkgs.rust-bin.stable.latest.default.override {
        extensions = ["rust-analyzer" "rust-src"];
        targets = [
          "x86_64-unknown-linux-musl"
          "aarch64-unknown-linux-musl"

          "x86_64-pc-windows-gnu"
          "aarch64-pc-windows-gnullvm"

          "x86_64-apple-darwin"
          "aarch64-apple-darwin"

          "x86_64-linux-android"
          "aarch64-linux-android"
        ];
      };

      naersk = pkgs.callPackage inputs.naersk {
        cargo = toolchain;
        rustc = toolchain;
      };

      writeLua = filename: content:
        pkgs.writers.makeScriptWriter {
          interpreter = "${pkgs.bash}/bin/bash";
          makeWrapperArgs = [
            "--prefix"
            "PATH"
            ":"
            "${pkgs.lib.makeBinPath [pkgs.lune]}"
          ];
        } "/bin/${filename}" ''
          lune run ${pkgs.writeText "script.luau" content} -- "$@"
        '';

      windows-linker = writeLua "zcc" ''
        local process = require("@lune/process")
        local fs = require("@lune/fs")

        local filtered_args = {}

        for _, v in process.args do
          if v == "-lmsvcrt" then continue end
          if v == "-l:libpthread.a" then
            table.insert(filtered_args, "-lpthread")
            continue
          end

          table.insert(filtered_args, v)
        end

        table.insert(filtered_args, 1, "cc")
        table.insert(filtered_args, 2, "-target")
        table.insert(filtered_args, 3, process.env.ZIG_TARGET)

        local result = process.spawn("zig", filtered_args)
        if not result.ok then
          error(result.stdout.. "\n".. result.stderr)
        end
      '';

      androidPackages =
        (pkgs.androidenv.composeAndroidPackages {
          toolsVersion = null;
          buildToolsVersions = [];
          includeNDK = true;
        }).androidsdk;
    in {
      devShells.default = pkgs.mkShell {
        packages = [
          toolchain
        ];
      };

      packages = {
        x86_64-linux = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          nativeBuildInputs = with pkgs; [
            llvmPackages.bintools
          ];

          env = {
            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
            CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS = "-C target-feature=+crt-static -C linker-flavor=ld.lld";
          };
        };

        aarch64-linux = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          nativeBuildInputs = [
            pkgs.llvmPackages.bintools
          ];

          env = {
            CARGO_BUILD_TARGET = "aarch64-unknown-linux-musl";
            CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS = "-C target-feature=+crt-static -C linker-flavor=ld.lld";
          };
        };

        x86_64-windows = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          nativeBuildInputs = [
            windows-linker

            pkgs.writableTmpDirAsHomeHook
            pkgs.zig
          ];

          env = {
            CARGO_BUILD_TARGET = "x86_64-pc-windows-gnu";
            CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "zcc";
            ZIG_TARGET = "x86_64-windows-gnu";
          };
        };

        aarch64-windows = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          nativeBuildInputs = [
            windows-linker

            pkgs.writableTmpDirAsHomeHook
            pkgs.zig
          ];

          env = {
            CARGO_BUILD_TARGET = "aarch64-pc-windows-gnullvm";
            CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER = "zcc";
            ZIG_TARGET = "aarch64-windows-gnu";
          };
        };

        x86_64-darwin = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          nativeBuildInputs = [
            pkgs.zig
            pkgs.writableTmpDirAsHomeHook
          ];

          env = {
            CARGO_BUILD_TARGET = "x86_64-apple-darwin";
            CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER = "${pkgs.writers.writeBash "zcc" ''
              zig cc -target x86_64-macos "$@"
            ''}";
          };
        };

        aarch64-darwin = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          nativeBuildInputs = [
            pkgs.zig
            pkgs.writableTmpDirAsHomeHook
          ];

          env = {
            CARGO_BUILD_TARGET = "aarch64-apple-darwin";
            CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER = "${pkgs.writers.writeBash "zcc" ''
              zig cc -target aarch64-macos "$@"
            ''}";
          };
        };

        x86_64-android = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          env = {
            CARGO_BUILD_TARGET = "x86_64-linux-android";
            CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER = "${androidPackages}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android35-clang";
          };

          meta.broken = pkgs.stdenv.hostPlatform.isDarwin;
        };

        aarch64-android = naersk.buildPackage {
          src = ./.;
          strictDeps = true;

          env = {
            CARGO_BUILD_TARGET = "aarch64-linux-android";
            CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "${androidPackages}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang";
          };

          meta.broken = pkgs.stdenv.hostPlatform.isDarwin;
        };
      };
    });
}
