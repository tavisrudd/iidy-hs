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
          (pkgs.haskellPackages.ghcWithPackages (hp: [
            hp.aeson
            hp.bytestring
            hp.containers
            hp.directory
            hp.filepath
            hp.HsYAML
            hp.random
            hp.scientific
            hp.text
            hp.time
            hp.vector
            hp.amazonka
            hp.amazonka-cloudformation
            hp.amazonka-s3
            hp.amazonka-sts
            hp.amazonka-ssm
            hp.amazonka-sns
            hp.crypton
            hp.memory
            hp.lens
            hp.conduit
            hp.resourcet
            hp.mtl
            hp.transformers
            hp.unliftio
            hp.optparse-applicative
            hp.http-conduit
          ]))
          pkgs.haskellPackages.cabal-install
          pkgs.pkg-config
          pkgs.zlib
        ];
      };
    };
}
