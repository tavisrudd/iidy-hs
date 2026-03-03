{
  description = "PLT Redex formal semantics for iidy preprocessing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in {
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.racket  # full racket needed for redex
            ];
            shellHook = ''
              echo "iidy-spec: Racket $(racket --version 2>/dev/null | head -1)"
              echo "Run: racket tests/run-all.rkt"
            '';
          };
        }
      );
    };
}
