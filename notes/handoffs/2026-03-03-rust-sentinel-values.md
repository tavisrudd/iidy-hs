# Implement --profile=no-profile and --assume-role-arn=no-role Sentinels in Rust iidy

**Date**: 2026-03-03
**Created by**: 2026-03-03--16 (`743385e5-2d9d-476b-9ea0-eac58d5c2178`)
**Purpose**: Implement the documented but unimplemented sentinel override values in the Rust iidy CLI.

---

## Context

The Rust iidy CLI documents two sentinel values in its help text:
- `--profile=no-profile` — intended to override any stack-args.yaml `Profile` and force use of `AWS_*` env vars
- `--assume-role-arn=no-role` — intended to override any stack-args.yaml `AssumeRoleArn` and skip role assumption

Neither is implemented. The literal strings `"no-profile"` and `"no-role"` pass through the config merge and reach the AWS SDK, which tries to use them as real profile/role names, causing auth failures.

## Scope

- **In scope**: Recognize sentinel values during config merge, suppress inherited values, add tests
- **Out of scope**: Haskell port (handled separately), CLI parser changes (help text already correct)

## Work Items

1. **Add sentinel recognition in config merge** (`src/cfn/stack_args.rs`)
   - In the settings merge logic (~line 214-243), when CLI profile is `"no-profile"`, set merged profile to `None`
   - When CLI assume_role_arn is `"no-role"`, set merged assume_role_arn to `None`
   - This ensures stack-args values are suppressed

2. **Guard against sentinels reaching AWS SDK** (`src/aws/mod.rs`)
   - In `config_from_merged_settings` (~line 104-142), add a defensive check
   - If profile is `"no-profile"` or role is `"no-role"` after merge, treat as `None`

3. **Add tests**
   - Test that `--profile=no-profile` overrides a stack-args `Profile: my-profile`
   - Test that `--assume-role-arn=no-role` overrides a stack-args `AssumeRoleArn`
   - Test that the sentinel values result in `None` in merged settings, not literal strings

## Codebase Reference

| What                        | Where                                    |
|-----------------------------|------------------------------------------|
| CLI arg definitions         | `src/cli.rs:143,152`                     |
| Settings merge              | `src/cfn/stack_args.rs:214-243`          |
| AWS config from settings    | `src/aws/mod.rs:104-142`                 |

## Principles / Constraints

- This is the Rust codebase at `~/src/iidy/`, not the Haskell port
- Keep the sentinel strings as constants, not magic literals scattered in code
- The Haskell port will implement the same feature independently

## Delegation

- **Can delegate to sub-agent?** Yes
- **Model**: Sonnet
- **Notes**: Straightforward pattern-match-and-clear logic, well-scoped
