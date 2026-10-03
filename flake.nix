# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    };
    # The toolchain is the official 0.17.0 release binary, packaged by the
    # overlay, rather than nixpkgs' Zig.
    zig = {
      url = "git+https://git.jcollie.dev/jeff/zig-overlay.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      zig,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      linuxSystems = builtins.filter (
        system: (lib.systems.elaborate system).isLinux
      ) lib.systems.flakeExposed;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      zigFor = system: zig.packages.${system}."0.17.0";
      forAllSystems = lib.genAttrs linuxSystems;
    in
    {

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zregex";
            nativeBuildInputs = [
              pkgs.git-pages-cli
              # Pins GitHub Actions references to commit hashes.
              pkgs.pinact
              # Runs the aarch64 test suite via `zig build test -fqemu`.
              pkgs.qemu
              pkgs.kcov
              pkgs.radicle-node
              pkgs.reuse
              (zigFor system)
            ];
            # The oracle builds its own PCRE2 (pinned in build.zig.zon);
            # these exports exist for -Dpcre2-include/-Dpcre2-lib override
            # experiments against nixpkgs' build, such as diagnosing
            # reference version drift.
            PCRE2_INCLUDE = "${pkgs.pcre2.dev}/include";
            PCRE2_LIB = "${pkgs.pcre2.out}/lib";
          };
        }
      );
    };
}
