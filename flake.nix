{
  description = "iidy-hs - Haskell port of iidy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.haskellPackages.ghc
          pkgs.haskellPackages.cabal-install
          pkgs.pkg-config
          pkgs.zlib
        ];
      };
    };
}
