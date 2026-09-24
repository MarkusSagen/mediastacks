{
  description = "mediastacks — biblio (books) + medias (media) organizer toolkit (Zig 0.16)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      # libmobi isn't in nixpkgs; build it from source so both the devShell and
      # any future package output can link biblio's MOBI/AZW3 support.
      packages = forAll (pkgs: rec {
        libmobi = pkgs.stdenv.mkDerivation {
          pname = "libmobi";
          version = "0.12";
          src = pkgs.fetchFromGitHub {
            owner = "bfabiszewski";
            repo = "libmobi";
            rev = "public/0.12";
            hash = "sha256-Xkk5H5Yss4O467d/19/xgztwpv51sJyEpoycTq8gzoA=";
          };
          nativeBuildInputs = [ pkgs.autoreconfHook pkgs.pkg-config ];
          buildInputs = [ pkgs.zlib pkgs.libxml2 ];
        };
        default = libmobi;
      });

      # `nix develop` — a reproducible build shell. Zig 0.16 + the C deps, with
      # C_INCLUDE_PATH / LIBRARY_PATH set the way build.zig discovers them.
      devShells = forAll (pkgs:
        let libmobi = self.packages.${pkgs.system}.libmobi; in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_16
              pkgs.pkg-config
              pkgs.libxml2.dev
              pkgs.sqlite.dev
              pkgs.zlib
              libmobi
            ];
            shellHook = ''
              export C_INCLUDE_PATH="${libmobi}/include:${pkgs.libxml2.dev}/include/libxml2:${pkgs.sqlite.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
              export LIBRARY_PATH="${libmobi}/lib:${pkgs.libxml2.out}/lib:${pkgs.sqlite.out}/lib:${pkgs.zlib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              echo "mediastacks dev shell — zig $(zig version); run: zig build"
            '';
          };
        });
    };
}
