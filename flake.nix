{
  description = "Remill - Library for lifting machine code to LLVM bitcode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        llvmPkgs = pkgs.llvmPackages_18;

        # Override XED to use a version compatible with remill (2022 vintage)
        xed-2022 = pkgs.xed.overrideAttrs rec {
          version = "2022.08.11";
          src = pkgs.fetchFromGitHub {
            owner = "intelxed";
            repo = "xed";
            rev = "v${version}";
            hash = "sha256-Iil+dfjuWYPbzmSjgwKTKScSE/IsWuHEKQ5HsBJDqWM=";
          };
        };

        # Git shim for CMake - just returns success without doing anything
        git-am-shim = pkgs.writeShellScriptBin "git" ''
          exit 0
        '';

        # Sleigh disassembly framework from Ghidra
        sleigh = pkgs.stdenv.mkDerivation (self: {
          pname = "sleigh";
          version = "unstable-2023-05-03";

          src = pkgs.fetchFromGitHub {
            owner = "lifting-bits";
            repo = "sleigh";
            rev = "7c6b7424467d0382a1303c278633e99b0d094d5b";
            hash = "sha256-Di/maGPXHPSM/EUVTgNRsu7nJ0Of+tVRu+B4wr9OoBE=";
          };

          ghidra-src = pkgs.fetchFromGitHub {
            owner = "NationalSecurityAgency";
            repo = "ghidra";
            rev = "80ccdadeba79cd42fb0b85796b55952e0f79f323";
            hash = "sha256-7Iv1awZP5lU1LpGqC0nyiMxy0+3WOmM2NTdDYIzKmmk=";
          };

          nativeBuildInputs = [ pkgs.python3 pkgs.cmake ];

          preConfigure = ''
            ghidra=$(mktemp -d)
            cp -r --no-preserve=mode ${self.ghidra-src}/. $ghidra

            substituteInPlace src/setup-ghidra-source.cmake \
              --replace 'find_package(Git REQUIRED)' "set(GIT_EXECUTABLE ${git-am-shim}/bin/git)" \
              --replace 'GIT_REPOSITORY https://github.com/NationalSecurityAgency/ghidra' "SOURCE_DIR $ghidra"

            echo '
            if(NOT ''${ghidra_head_git_tag} EQUAL ${self.ghidra-src.rev})
              message(FATAL_ERROR "nix: ghidra hash mismatch (sleigh expected: ''${ghidra_head_git_tag}, nix provided: ${self.ghidra-src.rev})")
            endif()
            ' >> src/setup-ghidra-source.cmake
          '';

          sleigh_ADDITIONAL_PATCHES = [ ];

          cmakeFlags = [
            "-Dsleigh_RELEASE_TYPE=HEAD"
            "-Dsleigh_ADDITIONAL_PATCHES=${pkgs.lib.concatStringsSep ";" self.sleigh_ADDITIONAL_PATCHES}"
          ];

          meta = with pkgs.lib; {
            description = "Ghidra Sleigh disassembler library";
            homepage = "https://github.com/lifting-bits/sleigh";
            platforms = platforms.unix;
          };
        });

        # Sleigh with remill-specific patches
        sleigh-patched = remill-src: sleigh.overrideAttrs (old: {
          sleigh_ADDITIONAL_PATCHES = [
            "${remill-src}/patches/sleigh/0001-AARCH64base.patch"
            "${remill-src}/patches/sleigh/0001-AARCH64instructions.patch"
            "${remill-src}/patches/sleigh/0001-ARM.patch"
            "${remill-src}/patches/sleigh/0001-ARMTHUMBinstructions.patch"
            "${remill-src}/patches/sleigh/0001-ppc_common.patch"
            "${remill-src}/patches/sleigh/0001-ppc_instructions.patch"
            "${remill-src}/patches/sleigh/0001-ppc_isa.patch"
            "${remill-src}/patches/sleigh/0001-ppc_vle.patch"
            "${remill-src}/patches/sleigh/0001-quicciii.patch"
            "${remill-src}/patches/sleigh/x86-ia.patch"
          ];
        });

        # Main remill package
        remill = pkgs.stdenv.mkDerivation (self: rec {
          pname = "remill";
          version = "unstable-2024-11-15";

          src = ./.;

          sleigh-with-patches = sleigh-patched self.src;

          ghidra-fork-src = pkgs.fetchFromGitHub {
            owner = "trail-of-forks";
            repo = "ghidra";
            rev = "e7196d8b943519d3aa5eace6a988cda3aa6aca5c";
            hash = "sha256-uOaTY9dYVAyu5eU2tLKNJWRwN98OQkCVynwQvjeBQB8=";
          };

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
          ];

          buildInputs = [
            sleigh-with-patches
            llvmPkgs.llvm
            pkgs.glog
            pkgs.gtest
            pkgs.abseil-cpp
            xed-2022
          ] ++ pkgs.lib.optional (!pkgs.stdenv.isDarwin) pkgs.glibc_multi;

          outputs = [ "out" "dev" "lib" ];

          # Git version variables
          GIT_RETRIEVED_STATE = true;
          GIT_IS_DIRTY = false;
          GIT_AUTHOR_NAME = "nix";
          GIT_AUTHOR_EMAIL = "nix@localhost";
          GIT_HEAD_SHA1 = "0000000000000000000000000000000000000000";
          GIT_COMMIT_DATE_ISO8601 = "2024-11-15T00:00:00+00:00";
          GIT_COMMIT_SUBJECT = "Built with Nix";
          GIT_COMMIT_BODY = "";
          GIT_DESCRIBE = version;

          preConfigure = ''
            # Check dependency versions match CMake expectations
            function check-version() {
              repo="$1"; nixhash="$2"
              expected=$(grep "FetchContent_Declare($repo" --after-context=3 CMakeLists.txt | grep GIT_TAG | xargs echo | cut -d' ' -f2 || true)
              if [ -n "$expected" ]; then
                if ! (set -x; echo "nix $repo: $nixhash" | grep -q " $expected"); then
                  echo "WARNING: mismatched $repo rev. Expected: $expected, Got: $nixhash"
                fi
              fi
            }
            check-version ghidra-fork ${ghidra-fork-src.rev}
            check-version sleigh ${sleigh-with-patches.src.rev}

            # Embed ghidra-fork source
            ghidra=$(mktemp -d)
            cp -r --no-preserve=mode ${ghidra-fork-src}/. $ghidra

            substituteInPlace CMakeLists.txt \
              --replace 'GIT_REPOSITORY https://github.com/trail-of-forks/ghidra.git' "SOURCE_DIR $ghidra"

            substituteInPlace CMakeLists.txt \
              --replace "sleigh_compile(" "set(sleigh_BINARY_DIR $(mktemp -d))${"\n"}sleigh_compile("

            # Use nix-provided dependencies instead of FetchContent
            substituteInPlace CMakeLists.txt \
              --replace 'XED::XED' xed \
              --replace 'find_package(XED CONFIG REQUIRED)' "" \
              --replace 'find_package(Z3 CONFIG REQUIRED)' "" \
              --replace 'InstallExternalTarget(' 'message(STATUS '

            # Use nix-provided sleigh
            substituteInPlace CMakeLists.txt \
              --replace 'FetchContent_Declare(sleigh' 'find_package(sleigh REQUIRED COMPONENTS Support)${"\n"}message(STATUS "ignore FetchContent(Sleigh "' \
              --replace 'FetchContent_MakeAvailable(sleigh)' "" \
              --replace 'FetchContent_GetProperties(GhidraSource)' "set(ghidrasource_POPULATED TRUE)${"\n"}set(ghidrasource_SOURCE_DIR $ghidra)" \
              --replace 'if(NOT ghidrasource_POPULATED)' 'if(FALSE)'

            # Configure bitcode compiler
            BC_CXX=${llvmPkgs.libcxxClang}/bin/clang++
            BC_CXXFLAGS="-g0 $(cat ${llvmPkgs.libcxxClang}/nix-support/libcxx-cxxflags) -D_LIBCPP_HAS_NO_THREADS"
            BC_LD=$(command -v llvm-link)
            BC_LDFLAGS=""

            substituteInPlace cmake/BCCompiler.cmake \
              --replace 'find_package(Clang CONFIG REQUIRED)' "" \
              --replace 'get_target_property(CLANG_PATH clang LOCATION)' "" \
              --replace 'get_target_property(LLVMLINK_PATH llvm-link LOCATION)' "" \
              --replace 'find_program(CLANG_PATH NAMES clang++ clang PATHS ''${LLVMLINK_PATH_DIR} NO_DEFAULT_PATH REQUIRED)' "" \
              --replace '$'{CLANG_PATH} $BC_CXX \
              --replace '$'{LLVMLINK_PATH} $BC_LD \
              --replace '$'{source_file_option_list} '$'{source_file_option_list}" $BC_CXXFLAGS" \
              --replace '$'{linker_flag_list} '$'{linker_flag_list}" $BC_LDFLAGS"

            # Inject Git version info
            substituteInPlace lib/Version/Version.cpp.in \
              --subst-var GIT_RETRIEVED_STATE \
              --subst-var GIT_IS_DIRTY \
              --subst-var GIT_AUTHOR_NAME \
              --subst-var GIT_AUTHOR_EMAIL \
              --subst-var GIT_HEAD_SHA1 \
              --subst-var GIT_COMMIT_DATE_ISO8601 \
              --subst-var GIT_COMMIT_SUBJECT \
              --subst-var GIT_COMMIT_BODY \
              --subst-var GIT_DESCRIBE
          '';

          CXXFLAGS = "-include cstdint -g0 -Wno-error=return-type";

          cmakeFlags = [
            "-DCMAKE_C_COMPILER=${llvmPkgs.clang}/bin/clang"
            "-DCMAKE_CXX_COMPILER=${llvmPkgs.clang}/bin/clang++"
            "-DCMAKE_VERBOSE_MAKEFILE=OFF"
            "-DVCPKG_TARGET_TRIPLET=x64-linux-rel"
            "-DGIT_EXECUTABLE=${git-am-shim}/bin/git"
            "-DREMILL_ENABLE_TESTING=OFF"
          ];

          hardeningDisable = [ "zerocallusedregs" ];

          meta = with pkgs.lib; {
            description = "Library for lifting machine code to LLVM bitcode";
            homepage = "https://github.com/lifting-bits/remill";
            license = licenses.asl20;
            platforms = platforms.unix;
            broken = pkgs.stdenv.isDarwin && pkgs.stdenv.isAarch64;
          };
        });

      in
      {
        packages = {
          inherit sleigh remill xed-2022;
          default = remill;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ remill ];

          packages = with pkgs; [
            cmake
            ninja
            python3
            git
            llvmPkgs.clang
            llvmPkgs.llvm
            llvmPkgs.lld
            llvmPkgs.clang-tools
            ccache
            gdb
          ];

          shellHook = ''
            echo "Remill development environment (LLVM 18)"
            echo ""
            echo "Build remill:"
            echo "  nix build .#remill"
            echo ""
            echo "Enter development shell:"
            echo "  nix develop"
          '';
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
