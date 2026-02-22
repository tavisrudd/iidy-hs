{
  description = "iidy-hs - Haskell port of iidy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hp = pkgs.haskellPackages;
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
        hpkgs.yaml
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
      ];
    in {
      packages.${system}.default = hp.callCabal2nix "iidy-hs" self {};

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          (hp.ghcWithPackages haskellDeps)
          hp.cabal-install
          pkgs.pkg-config
          pkgs.zlib
        ];
      };
    };
}
