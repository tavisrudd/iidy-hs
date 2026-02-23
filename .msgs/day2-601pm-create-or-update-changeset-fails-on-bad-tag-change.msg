If I pass an invalid TAG:

> ./iidy-hs --region us-west-2 create-or-update --changeset ../iidy/example-stacks/hello-world/stack-args.yaml
Command Metadata:
 iidy Environment:        development
 Region:                  us-west-2
 IAM Service Role:        None
 Current IAM Principal:   arn:aws:iam::903405759226:user/tavis-cli
 Credential Source:       environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN) (overriding profile 'default' (default))
 CLI Arguments:           region=us-west-2
 iidy Version:            0.1.0.0
 Client Req Token:        2e802df0-db0c-4d5c-92af-bed8c675bb9b (auto-generated)

Stack Details:
 Name:                    iidy-demo-hello-world
 Status:                  CREATE_COMPLETE
 Capabilities:            None
 Service Role:            None
 Region:                  us-west-2
 Tags:                    environment=development, lifetime=short, project=iidy-demo
 Parameters:              Name=world
 DisableRollback:         false
 TerminationProtection:   false
 Creation Time:           Mon Feb 23 2026 02:06:23
 Last Update Time:        Mon Feb 23 2026 02:06:33
 NotificationARNs:        None
 ARN:                     arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb
 Console URL:             https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/stackinfo?stackId=arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb

AWS Console URL for full changeset review: https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/changeset/detail?stackId=arn%3Aaws%3Acloudformation%3Aus-west-2%3A903405759226%3Astack%2Fiidy-demo-hello-world%2F40dff210-105c-11f1-99b4-02d3969b84fb&changeSetId=arn%3Aaws%3Acloudformation%3Aus-west-2%3A903405759226%3AchangeSet%2Fiidy-create-or-update-2e802df0%2Fa0458bc6-5fd1-4cfb-bc61-090fe381e9ce


Pending Changesets:
 Unknown time             iidy-create-or-update-2e802df0 FAILED

Your new stack is now in REVIEW_IN_PROGRESS state. To create the resources run the following
  iidy --region us-west-2 exec-changeset --stack-name iidy-demo-hello-world ../iidy/example-stacks/hello-world/stack-args.yaml iidy-create-or-update-2e802df0
Do you want to execute this changeset now? [y/N] y
ERROR: ChangeSet [arn:aws:cloudformation:us-west-2:903405759226:changeSet/iidy-create-or-update-2e802df0/a0458bc6-5fd1-4cfb-bc61-090fe381e9ce] cannot be executed in its current status of [FAILED]
  • Check the AWS CloudFormation console for more details



> ./iidy-rs --region us-west-2 create-or-update --changeset ../iidy/example-stacks/hello-world/stack-args.yaml
Command Metadata:

ERROR: invalid type: integer `1234`, expected a string
  • Check the AWS CloudFormation console for more details
