# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    };
  };

  outputs =
    {
      nixpkgs,
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
              pkgs.zig_0_16
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
