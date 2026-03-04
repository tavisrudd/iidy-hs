.PHONY: build build-strict test clean run help ci ci-act check-unused-deps dev-setup spec snapshot lint lint-stan format format-check

build:
	cabal build

build-strict:
	cabal build all --enable-tests --ghc-options="-Wall -Wcompat -Werror"

test:
	cabal test all --test-show-details=direct

run:
	cabal run iidy-hs -- $(ARGS)

clean:
	cabal clean

help:
	cabal run iidy-hs -- --help

loc:
	@find src app -name '*.hs' | xargs wc -l | tail -1

modules:
	@find src -name '*.hs' | wc -l

check-unused-deps:
	scripts/check-unused-deps.sh

dev-setup:
	git config --local core.hooksPath .githooks

ci:
	$(MAKE) build-strict
	$(MAKE) test
	$(MAKE) check-unused-deps
	cabal run iidy-hs -- --help
	cabal run iidy-hs -- --version

# Run PLT Redex spec tests (requires: cd spec && nix develop)
spec:
	cd spec && nix develop --command racket tests/run-all.rkt

# Regenerate spec/snapshot.json from the Redex spec.
# Run this after changing spec behavior to update conformance vectors.
snapshot:
	cd spec && nix develop --command racket snapshot.rkt

lint:
	hlint src/ app/ test/

lint-stan:
	stan --hiedir=.hie

format:
	fourmolu --mode inplace src/ app/ test/

format-check:
	fourmolu --mode check src/ app/ test/

ci-act:
	nix run nixpkgs#act -- -j build
