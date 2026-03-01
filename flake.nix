{
  description = "iidy-hs - Haskell port of iidy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      haskellDeps = hpkgs: [
        hpkgs.aeson
        hpkgs.bytestring
        hpkgs.containers
        hpkgs.directory
        hpkgs.filepath
        hpkgs.HsYAML
        hpkgs.random
        hpkgs.scientific
        hpkgs.text
        hpkgs.time
        hpkgs.vector
        hpkgs.amazonka
        hpkgs.amazonka-cloudformation
        hpkgs.amazonka-s3
        hpkgs.amazonka-sts
        hpkgs.amazonka-ssm
        hpkgs.amazonka-sns
        hpkgs.aeson-pretty
        hpkgs.crypton
        hpkgs.memory
        hpkgs.lens
        hpkgs.conduit
        hpkgs.resourcet
        hpkgs.mtl
        hpkgs.transformers
        hpkgs.unliftio
        hpkgs.optparse-applicative
        hpkgs.http-conduit
        hpkgs.process
        hpkgs.tasty
        hpkgs.tasty-hunit
        hpkgs.tasty-quickcheck
        hpkgs.QuickCheck
      ];
    in {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in { default = pkgs.haskellPackages.callCabal2nix "iidy-hs" self {}; }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
            hp = pkgs.haskellPackages;
        in {
          default = pkgs.mkShell {
            buildInputs = [
              (hp.ghcWithPackages haskellDeps)
              hp.cabal-install
              pkgs.pkg-config
              pkgs.zlib
            ];
          };
        }
      );
    };
}
