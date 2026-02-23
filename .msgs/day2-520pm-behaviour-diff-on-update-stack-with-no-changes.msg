> ./iidy-hs --region us-west-2 update-stack ../iidy/example-stacks/hello-world/stack-args.yaml
Command Metadata:
 iidy Environment:        development
 Region:                  us-west-2
 IAM Service Role:        None
 Current IAM Principal:   arn:aws:iam::903405759226:user/tavis-cli
 Credential Source:       environment variables (temporary) (overrides: profile 'default' (default))
 CLI Arguments:           region=us-west-2, stack-name=iidy-demo-hello-world
 iidy Version:            0.1.0.0
 Client Req Token:        9727d0ca-dfac-49ab-adbe-611f05703d34 (auto-generated)

 Command Summary:         Success 👍
 tavis  grover  ~/src/iidy-hs  main  aws: dss 
> ./iidy-rs --region us-west-2 update-stack ../iidy/example-stacks/hello-world/stack-args.yaml
Command Metadata:
 CFN Operation:           update-stack
 iidy Environment:        development
 Region:                  us-west-2
 IAM Service Role:        None
 Current IAM Principal:   arn:aws:iam::903405759226:user/tavis-cli
 Credential Source:       environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN) (overriding profile 'default' (default))
 CLI Arguments:           region=us-west-2
 iidy Version:            1.0.0
 Client Req Token:        70c3149d-51b5-4d0e-bac5-4e0b30e37781 (auto-generated)

Stack Details:

ERROR: AWS error - Error { code: "ValidationError", message: "No updates are to be performed.", aws_request_id: "4cc97b7b-18a2-4609-8331-5fef2ba77bc6" }
  • Check the AWS CloudFormation console for more details
