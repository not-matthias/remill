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
            llvmPkgs.libllvm
            pkgs.glog
            pkgs.gflags
            pkgs.gtest
            pkgs.abseil-cpp
            xed-2022
          ] ++ pkgs.lib.optional (!pkgs.stdenv.isDarwin) pkgs.glibc_multi;

          outputs = [ "out" "dev" "lib" "deps" ];

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

          # Copy all build dependencies into the deps output
          postInstall = ''
            mkdir -p $deps/lib $deps/include $deps/share/ghidra
            mkdir -p $dev/share

            # Copy sleigh specfiles to dev output (required by sleigh CMake config)
            cp -r ${sleigh-patched ./. }/share/* $dev/share/ || true

            # Copy all dependencies to deps output
            cp -r ${llvmPkgs.llvm.lib}/lib/* $deps/lib/ || true
            cp -r ${llvmPkgs.llvm.dev}/include/* $deps/include/ || true
            cp -r ${pkgs.glog}/lib/* $deps/lib/ || true
            cp -r ${pkgs.glog}/include/* $deps/include/ || true
            cp -r ${pkgs.gflags}/lib/* $deps/lib/ || true
            cp -r ${pkgs.gflags}/include/* $deps/include/ || true
            cp -r ${pkgs.gtest}/lib/* $deps/lib/ || true
            cp -r ${pkgs.gtest}/include/* $deps/include/ || true
            cp -r ${pkgs.abseil-cpp}/lib/* $deps/lib/ || true
            cp -r ${pkgs.abseil-cpp}/include/* $deps/include/ || true
            cp -r ${xed-2022}/lib/* $deps/lib/ || true
            cp -r ${xed-2022}/include/* $deps/include/ || true
          '';

          # Fix CMake configs to use dev output for includes (multi-output fix)
          # When CMake generates the remill package config files, it embeds absolute paths
          # based on the build output paths. Since we use multi-output derivations, we need
          # to update these paths to point to the correct dev output instead of the main output.
          # This is critical for downstream packages (like RemillWorkshop) that depend on remill.
          postFixup = ''
            # Patch all remill CMake files to use $dev instead of $out
            chmod -R +w $dev/lib/cmake/remill

            # Fix _IMPORT_PREFIX - CMake uses this variable to locate the package
            find $dev/lib/cmake/remill -name "*.cmake" -exec sed -i \
              "s|set(_IMPORT_PREFIX \"[^\"]*\"|set(_IMPORT_PREFIX \"$dev\"|g" {} \;

            # Fix INTERFACE_INCLUDE_DIRECTORIES to use the patched _IMPORT_PREFIX
            find $dev/lib/cmake/remill -name "*.cmake" -exec sed -i \
              "s|INTERFACE_INCLUDE_DIRECTORIES \"\''${_IMPORT_PREFIX}/include\"|INTERFACE_INCLUDE_DIRECTORIES \"$dev/include\"|g" {} \;
          '';

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
        packages = rec {
          inherit sleigh remill xed-2022 sleigh-patched;
          default = remill;

          # Expose individual dependencies with CMake configs
          deps = {
            xed = pkgs.runCommand "xed-with-cmake" {} ''
              cp -r ${xed-2022} $out
              chmod -R +w $out
              mkdir -p $out/lib/cmake/xed
              cat > $out/lib/cmake/xed/XEDConfig.cmake <<'EOF'
if(XED_FOUND)
    return()
endif()

get_filename_component(PACKAGE_PREFIX_DIR "''${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)

find_library(XED_LIBRARY xed PATHS "''${PACKAGE_PREFIX_DIR}/lib" NO_CACHE REQUIRED NO_DEFAULT_PATH)
add_library(XED::XED STATIC IMPORTED)
set_target_properties(XED::XED PROPERTIES
    IMPORTED_CONFIGURATIONS "NOCONFIG"
    IMPORTED_LOCATION_NOCONFIG "''${XED_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "''${PACKAGE_PREFIX_DIR}/include"
)

find_library(ILD_LIBRARY xed-ild PATHS "''${PACKAGE_PREFIX_DIR}/lib" NO_CACHE REQUIRED NO_DEFAULT_PATH)
add_library(XED::ILD STATIC IMPORTED)
set_target_properties(XED::ILD PROPERTIES
    IMPORTED_CONFIGURATIONS "NOCONFIG"
    IMPORTED_LOCATION_NOCONFIG "''${ILD_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "''${PACKAGE_PREFIX_DIR}/include"
)

set(XED_FOUND ON)
EOF
            '';

            sleigh = sleigh-patched ./. ;
            llvm = llvmPkgs.llvm;
            glog = pkgs.glog;
            gtest = pkgs.gtest;
            abseil = pkgs.abseil-cpp;
            lief = pkgs.lief;
          };

          # Expose remill library output separately
          lib = remill.lib;

          # RemillWorkshop package
          workshop = pkgs.stdenv.mkDerivation {
            pname = "remill-workshop";
            version = "0.1.0";

            src = ./RemillWorkshop;

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.ninja
              llvmPkgs.clang
            ];

            buildInputs = [
              remill
              deps.llvm
              deps.sleigh
              deps.xed
              deps.lief
            ];

            cmakeFlags = [
              "-DCMAKE_PREFIX_PATH=${remill.dev};${deps.llvm};${deps.sleigh};${deps.xed};${deps.lief}"
            ];

            meta = with pkgs.lib; {
              description = "Workshop materials for learning Remill";
              homepage = "https://github.com/lifting-bits/remill";
              license = licenses.asl20;
              platforms = platforms.unix;
            };
          };
        };

        devShells = {
          default = pkgs.mkShell {
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

          # Workshop-specific dev shell with all dependencies for RemillWorkshop
          workshop = pkgs.mkShell {
          packages = with pkgs; [
            cmake
            ninja
            llvmPkgs.clang
            lief
          ];

          shellHook = ''
            echo "RemillWorkshop development environment"
            echo ""
            echo "Available dependencies:"
            echo "  remill: ${remill}"
            echo "  remill.dev: ${remill.dev}"
            echo "  XED: ${self.packages.${system}.deps.xed}"
            echo "  Sleigh: ${self.packages.${system}.deps.sleigh}"
            echo "  LLVM: ${self.packages.${system}.deps.llvm}"
            echo "  LIEF: ${self.packages.${system}.deps.lief}"
            echo ""
            echo "Build RemillWorkshop:"
            echo "  cd RemillWorkshop"
            echo "  cmake --preset clang \\"
            echo "    -DCMAKE_PREFIX_PATH=\"${remill};${remill.dev};${self.packages.${system}.deps.llvm};${self.packages.${system}.deps.sleigh};${self.packages.${system}.deps.xed};${self.packages.${system}.deps.lief}\""
            echo "  cmake --build build"
          '';
          };
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
