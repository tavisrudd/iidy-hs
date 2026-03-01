# Demo Fixtures for CI Integration Testing

These fixtures support end-to-end testing via the `iidy demo` command.

## Usage

```bash
# Run the full demo (create, update, delete)
iidy-hs demo --stack-name iidy-hs-ci-demo

# Or use the stack-args file directly
iidy-hs create-stack fixtures/demo/stack-args.yaml
iidy-hs delete-stack fixtures/demo/stack-args.yaml
```

## IAM Policy

The `iam-policy.json` file contains the minimal IAM permissions needed to run
the demo in CI. Attach this policy to the CI runner's IAM role or user.

## Resources Created

- `AWS::CloudFormation::WaitConditionHandle` — free, no ongoing cost
- `AWS::SSM::Parameter` — free tier (standard parameters)
