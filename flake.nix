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
        hpkgs.edit-distance
        hpkgs.filepath
        hpkgs.HsYAML
        hpkgs.random
        hpkgs.scientific
        hpkgs.text
        hpkgs.time
        hpkgs.vector
        hpkgs.amazonka
        hpkgs.amazonka-cloudformation
        hpkgs.amazonka-core
        hpkgs.amazonka-s3
        hpkgs.amazonka-sts
        hpkgs.amazonka-ssm
        hpkgs.aeson-pretty
        hpkgs.crypton
        hpkgs.memory
        hpkgs.microlens
        hpkgs.regex-tdfa
        hpkgs.conduit
        hpkgs.resourcet
        hpkgs.transformers
        hpkgs.ansi-terminal
        hpkgs.terminal-size
        hpkgs.network
        hpkgs.optparse-applicative
        hpkgs.prettyprinter
        hpkgs.stm
        hpkgs.uuid
        hpkgs.http-client
        hpkgs.http-client-tls
        hpkgs.http-conduit
        hpkgs.http-types
        hpkgs.process
        hpkgs.temporary
        hpkgs.tasty
        hpkgs.tasty-hunit
        hpkgs.tasty-quickcheck
        hpkgs.tasty-bench
        hpkgs.deepseq
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
              hp.hlint
              hp.fourmolu
              hp.haskell-language-server
              pkgs.pkg-config
              pkgs.zlib
            ];
          };
        }
      );
    };
}
