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
      # GHC 9.12 package set. Only leaf packages (nothing else in the set
      # depends on them) are moved past the nixpkgs default version; see
      # notes/C3/index.org for the packages held back and why.
      hpkgsFor = pkgs: pkgs.haskell.packages.ghc912.override {
        overrides = hself: _hsuper: {
          tasty-bench = hself.tasty-bench_0_5;
        };
      };
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
        in {
          default = ((hpkgsFor pkgs).callCabal2nix "iidy-hs" self {}).overrideAttrs (old: {
            nativeCheckInputs = (old.nativeCheckInputs or []) ++ [ pkgs.git ];
            # The Git import test needs a local commit; flake sources omit .git.
            preCheck = (old.preCheck or "") + ''
              git -c init.defaultBranch=main init
              git -c user.name=iidy-test -c user.email=iidy-test@example.invalid \
                -c commit.gpgsign=false commit --allow-empty -m "Test fixture"
            '';
          });
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
            hp = hpkgsFor pkgs;
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
