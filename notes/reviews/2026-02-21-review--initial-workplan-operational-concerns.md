# Workplan Operational Review

**Date:** 2026-02-21
**Reviewer context:** Machine constraints (no sudo, no home-manager switch, YubiKey GPG, 28GB RAM / 24 cores, 5hr/week Claude Max, Nix-based dev)

---

## Nix Flake Plan

**Verdict: Feasible. iidy-hs needs its own flake.nix, not an extension of centaur-analysis.**

The centaur-analysis `flake.nix` provides Node.js and Zig dev shells -- completely unrelated to Haskell. iidy-hs should have its own `flake.nix` in `/home/tavis/src/iidy-hs/`. This is the correct Nix pattern: one flake per project.

**amazonka in nixpkgs: confirmed working.** Key findings from probing the current nixpkgs-unstable:

| Package | nixpkgs Version | Workplan Expects | Status |
|---------|----------------|-----------------|--------|
| amazonka | 2.0-unstable-2025-04-16 | 2.0 | OK (not marked broken) |
| amazonka-cloudformation | 2.0-unstable-2025-04-16 | 2.0 | OK |
| amazonka-s3 | 2.0-unstable-2025-04-16 | 2.0 | OK |
| amazonka-ssm | 2.0-unstable-2025-04-16 | 2.0 | OK |
| amazonka-sts | 2.0-unstable-2025-04-16 | 2.0 | OK |
| amazonka-kms | 2.0-unstable-2025-04-16 | 2.0 | OK |
| amazonka-sns | 2.0-unstable-2025-04-16 | 2.0 | OK |
| GHC | 9.10.3 | >= 8.10.7 | OK |
| cabal-install | 3.16.0.0 | any | OK |
| brick | 2.9 | 2.10 | MISMATCH (see below) |
| aeson | 2.2.3.0 | any | OK |
| lens | 5.3.5 | any | OK |
| HsYAML | 0.2.1.5 | any | OK |
| optparse-applicative | 0.18.1.0 | any | OK |

**brick version mismatch:** nixpkgs has 2.9, the ecosystem audit references 2.10. The workplan's architectural decision #5 says the interactive renderer does NOT actually use brick -- it uses raw `ansi-terminal` + `System.IO` for sequential ANSI output. This means brick is not load-bearing. It could be dropped from deps entirely, or 2.9 is fine since it would only be used for the spinner (chunk 3.4) if at all.

**Recommended flake.nix structure:**

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    hsPkgs = pkgs.haskellPackages;
  in {
    devShells.x86_64-linux.default = hsPkgs.shellFor {
      packages = p: [ ];  # will use cabal for local package
      nativeBuildInputs = [
        hsPkgs.cabal-install
        hsPkgs.ghc
        pkgs.pkg-config  # for C library discovery
        pkgs.zlib        # transitive dep of many Haskell packages
      ];
    };
  };
}
```

The agent should use `haskellPackages.shellFor` rather than raw `mkShell` because `shellFor` properly sets up GHC with access to Nix-provided Haskell packages. However, for a cabal-based project, a simpler approach is a `mkShell` with `ghcWithPackages` providing the system-level Haskell deps and letting cabal handle the rest. Both approaches work without sudo.

**No system modification needed.** `nix develop` creates an isolated shell. No `/etc` changes, no home-manager switch, no sudo.

---

## Build Resource Limits

**Current state: 18GB used, 8.5GB available, 6.3GB swap in use. The machine is already under memory pressure.**

The workplan says `jobs: 4`. Analysis:

- **GHC per-module peak memory:** Typical modules use 500MB-1.5GB. amazonka-cloudformation modules are auto-generated and contain massive record types with dozens of lens definitions -- these are the worst case and can peak at 2-3GB per compilation unit.
- **With `-j4`:** 4 simultaneous compilations could require 4 x 2GB = 8GB in the worst case. Given only 8.5GB available (and swap already under pressure), this is borderline dangerous.
- **Recommendation: `-j2` not `-j4` for the first build.** After the dependency graph stabilizes and amazonka modules are compiled (they come from nixpkgs as prebuilt packages, not built locally), bump to `-j3` or `-j4` for the project's own modules which will be much smaller.

**Critical insight: amazonka is prebuilt in nixpkgs.** The agent will NOT compile amazonka from source. When using `nix develop` with a proper `shellFor`, the amazonka packages come as prebuilt binaries from the Nix binary cache (cache.nixos.org). The memory concern is only for compiling iidy-hs's own modules. For those, `-j4` is safe because individual modules will be small (few hundred LOC each).

**But if cabal decides to rebuild amazonka from source** (e.g., due to a version constraint mismatch forcing a different version than nixpkgs provides), then OOM is a real risk. This is why the first-build de-risk strategy below is critical.

**cabal.project should contain:**

```
jobs: 2
ghc-options: -O0
```

The `-O0` flag eliminates optimization during development, cutting compile times by 50-70% and reducing peak memory. Only use `-O1` for final release builds.

**Linking:** amazonka-cloudformation produces large object files. If the linker runs out of memory, use `ghc-options: -split-sections` in cabal.project to reduce linker memory pressure. This is a GHC flag, not a system change.

---

## C Library Dependencies

**Verdict: All C dependencies are handled by Nix. No system-level packages needed.**

Detailed analysis of each package with C FFI:

| Package | C Dependency | How Nix Handles It | Risk |
|---------|-------------|-------------------|------|
| `yaml` | libyaml (C library) | nixpkgs builds `libyaml-0.1.4` Haskell binding which bundles the C code. Uses `-fsystem-libyaml` flag to link Nix-provided libyaml. | None -- fully handled by Nix |
| `HsYAML` | **None** (pure Haskell) | N/A | None |
| `crypton` | **None** (pure Haskell) | Uses Haskell `memory` package for low-level ops. No C crypto backend (unlike `cryptonite` which optionally uses C). | None |
| `vty` | **No direct C deps** | Uses POSIX terminal APIs via Haskell's FFI to libc, which is always available. No ncurses/terminfo dependency. | None |
| `brick` | No direct C deps (built on vty) | N/A | None |
| `amazonka` | **None** (pure Haskell HTTP/TLS) | Uses Haskell `tls-2.1.8` (pure Haskell TLS, no OpenSSL). HTTP via `http-conduit` -> `http-client` -> `connection` -> `tls`. | None |
| `zlib` (transitive) | zlib C library | nixpkgs provides `zlib-1.3.1` in the Nix store. The Haskell `zlib-0.7.1.1` links to it. | None -- `pkg-config` in nativeBuildInputs discovers it |
| `regex-tdfa` | **None** (pure Haskell) | N/A | None |

**The `yaml` package is the only one with a C dependency that matters**, and it is fully handled by Nix. The workplan includes both `yaml` and `HsYAML` in the dep list. Since the architectural decision is to use HsYAML (pure Haskell) for parsing, the `yaml` package may only be needed for its aeson integration (YAML-to-JSON conversion via `Data.Yaml`). If so, that is fine -- libyaml is bundled by Nix.

**Important: include `pkg-config` and `zlib` in flake.nix nativeBuildInputs.** Some Haskell packages use pkg-config to find C libraries. Without it in the dev shell, `cabal configure` may fail to find zlib headers. This is a Nix dev shell concern, not a system package concern.

---

## Dependency Resolution Risks

**Primary risk: version constraint conflicts between amazonka 2.0 and other packages.**

amazonka 2.0 pins specific versions of its dependencies:

| amazonka 2.0 pins | Version | Also used by |
|-------------------|---------|-------------|
| aeson | 2.2.x | yaml, mustache, req |
| lens | 5.3.x | brick (if used) |
| http-conduit | 2.3.x | req |
| http-types | 0.12.x | req, amazonka |
| conduit | 1.3.x | yaml, http-conduit |

The good news: **nixpkgs resolves all of these consistently.** The Haskell package set in nixpkgs is tested together. As long as the project uses the same versions as nixpkgs provides, there will be no conflicts.

**The risk emerges if the cabal file specifies version bounds that conflict with nixpkgs.** For example:
- The ecosystem audit says `optparse-applicative 0.19.0.0` but nixpkgs has `0.18.1.0`. If the cabal file says `>= 0.19`, it will fail. **Do not pin minimum versions above what nixpkgs provides.**
- Similarly, if cabal says `brick >= 2.10` but nixpkgs has 2.9, resolution fails.

**Recommendation:** The cabal file should use loose lower bounds matching what nixpkgs provides:

```
  , optparse-applicative >= 0.18
  , brick >= 2.9            -- or drop if not actually needed
```

**req + http-conduit coexistence:** The dep list includes both `req` and `http-conduit`. These can coexist but both transitively depend on `http-client`. In nixpkgs they share the same version, so no conflict. However, this is redundant -- pick one. `http-conduit` alone is sufficient (amazonka already pulls it in). Using `req` adds an unnecessary dependency. Consider dropping `req` and using `http-conduit` directly for HTTP import loaders.

**mustache package:** nixpkgs has `mustache-2.4.3.1`. No known conflicts with the rest of the dep set. Verified.

---

## Runtime Requirements

### AWS Credentials

**Current state: `~/.aws/config` exists but is empty (0 bytes). No `~/.aws/credentials` file.**

This means:
- Phase 4 (AWS/CloudFormation integration) **cannot be tested against real AWS** without credential setup.
- The agent cannot set up AWS credentials -- that requires human intervention (running `aws configure` or populating credential files).
- Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) could be set in `.envrc` but this contains secrets and should never be committed.

**Action required from human:** Before Phase 4:
1. Configure AWS credentials (via `aws configure`, environment variables, or SSO)
2. Specify which AWS account/region to use for testing
3. Decide whether to use real AWS or localstack

### Localstack for Testing

- Docker and Podman are both available on the system.
- Localstack is **not installed** but could be run via Docker: `docker run -d localstack/localstack`.
- The agent can run Docker commands without sudo (Docker socket is presumably configured for the user).
- **However:** localstack does not perfectly emulate CloudFormation. Stack operations, changesets, and drift detection may behave differently. Some Phase 4 tests may only be validatable against real AWS.

**Recommendation:** Use localstack for basic smoke tests (create-stack, describe-stack) but plan for real AWS validation as a human-assisted step.

### No Other Runtime System Dependencies

- No databases, no message queues, no external services beyond AWS.
- Terminal capabilities: detected at runtime via standard POSIX APIs, no setup needed.
- File system: standard read/write to working directory, no special mounts.

---

## First-Build De-Risk Strategy

The first `cabal build` is the single highest-risk moment for budget. If it fails, the agent enters a debug loop that can consume an entire session.

**Strategy: validate dependency resolution BEFORE writing any code.**

### Step 1: Minimal flake.nix + cabal file (no source code)

Create `flake.nix` and `iidy-hs.cabal` with ALL dependencies listed but only a trivial `Main.hs`:

```haskell
module Main where
main :: IO ()
main = putStrLn "iidy-hs skeleton"
```

The cabal file should list every dependency from the workplan. If `cabal build` succeeds with this skeleton, dependency resolution is proven safe.

### Step 2: Enter nix shell and run `cabal build --dry-run`

```bash
nix develop
cabal update
cabal build --dry-run
```

`--dry-run` resolves the dependency graph and reports what would be built **without compiling anything**. This costs zero RAM and takes seconds. If it fails, the constraint conflict is identified immediately.

### Step 3: Build the skeleton

```bash
cabal build -j2 -O0
```

This compiles only Main.hs but links all dependencies, proving they are available and compatible.

### Step 4: Proceed with Phase 1 types

Only after steps 1-3 succeed should the agent start writing actual type modules.

**Budget impact:** Steps 1-3 should take < 10 minutes of agent time. If step 2 fails, the error message from cabal's solver is precise and actionable. This turns a potential 2-hour debug session into a 15-minute fix.

### Fallback if resolution fails

If `cabal build --dry-run` shows a conflict:
1. Check which package is conflicting and what version nixpkgs provides
2. Adjust the cabal file bounds to match nixpkgs versions
3. If a package is simply not in nixpkgs, add it as a `source-repository-package` in `cabal.project`
4. If amazonka version in nixpkgs is incompatible with some other dep, use `allow-newer` in `cabal.project` as a temporary escape hatch (but document it)

---

## Git Workflow Notes

### GPG Signing: CRITICAL BLOCKER

**Global git config has `commit.gpgsign = true` and `tag.gpgSign = true`.** This is loaded via `~/.config/git/signing.gitconfig` which is included by `~/.gitconfig`.

The agent MUST use `--no-gpg-sign` on every commit. There are two ways to handle this:

**Option A (per-commit):** Every `git commit` command includes `--no-gpg-sign`. This is error-prone -- if the agent forgets once, the commit hangs waiting for YubiKey touch and the session stalls.

**Option B (repo-local config, recommended):** At project setup, run:
```bash
git -C /home/tavis/src/iidy-hs config --local commit.gpgsign false
```
This overrides the global setting for this repo only. No sudo, no home-manager, no global config change. The agent can then commit normally without `--no-gpg-sign` on every invocation.

**Recommendation: Option B.** Set this in the very first session before any commits. This is a repo-local config change stored in `.git/config`, not a system modification.

### Other Git Workflow Concerns

1. **No force-push:** The workplan doesn't mention branches. If working on `main`, force-push is never needed. If the human creates feature branches, the agent should push with simple `git push`, never `--force`.

2. **Small frequent commits:** The workplan's chunk structure (1.1, 1.2, ...) maps naturally to one commit per chunk. Each chunk should be committed after its gate passes. This gives clean rollback points.

3. **Commit message convention:** Follow whatever pattern exists in the repo. Currently only 1 commit in the repo (initial). Suggest: `Phase X.Y: <description>` format, e.g., `Phase 1.1: Add nix flake and cabal project skeleton`.

4. **No pre-commit hooks are configured** (no `.pre-commit-config.yaml` in the repo). This simplifies the workflow -- no hook failures to debug.

5. **.gitignore:** The agent should create a `.gitignore` in chunk 1.1 that excludes:
   ```
   dist-newstyle/
   *.hi
   *.o
   *.dyn_hi
   *.dyn_o
   result
   .envrc.local
   ```
   The `dist-newstyle/` exclusion is essential -- cabal's build directory can be gigabytes.

---

## Summary of Human Interventions Required

| When | What | Why |
|------|------|-----|
| Before Session 1 | Set `commit.gpgsign = false` in repo-local git config (or instruct agent to do it) | YubiKey requires physical touch |
| Before Phase 4 | Configure AWS credentials | Agent cannot create/manage AWS credentials |
| Before Phase 4 | Decide: real AWS vs localstack for testing | Cost and permission implications |
| If OOM occurs | Reduce `-j` or add swap | Agent can adjust cabal.project but cannot modify system swap |
| If nixpkgs package is broken | Override in flake.nix or wait for fix | Agent can write the override but may need guidance |

## Summary of Things the Agent CAN Do Without Help

- Create `flake.nix` in `/home/tavis/src/iidy-hs/` (no system modification)
- Run `nix develop` to enter dev shell
- Run `cabal build`, `cabal test` within the dev shell
- Set repo-local git config (`commit.gpgsign = false`)
- Run Docker for localstack (if Docker socket permissions allow)
- All code writing, testing, and committing within the constraints above
