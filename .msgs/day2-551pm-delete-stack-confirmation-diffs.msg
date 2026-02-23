1) formating discrepancies around conf. prompt and 2) incorrect error reporting if user says 'n', 3) credentials display is also different

# iidy-hs errors if I say no, also should be a blank line before prompt and red fg text
...
 Credential Source:       environment variables (temporary) (overrides: profile 'default' (default)) ## Note this display is different
...
Current Stack Status: CREATE_COMPLETE # missing blank line after this
Are you sure you want to DELETE the stack iidy-demo-hello-world? [y/N] n # white fg text for prompt

 Command Summary:         Failure (╯°□°）╯︵ ┻━┻
Fix and try again.



> ./iidy-rs --region us-west-2 delete-stack iidy-demo-hello-world
Command Metadata:
 CFN Operation:           delete-stack
 iidy Environment:        development
 Region:                  us-west-2
 IAM Service Role:        None
 Current IAM Principal:   arn:aws:iam::903405759226:user/tavis-cli
 Credential Source:       environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN) (overriding profile 'default' (default)) # correct display
 CLI Arguments:           region=us-west-2
 iidy Version:            1.0.0
 Client Req Token:        bfb4a1b3-cd99-4a54-8ceb-a911d16bf396 (auto-generated)

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
 Creation Time:           Mon Feb 23 2026 01:19:38
 NotificationARNs:        None
 ARN:                     arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/b8f62640-1055-11f1-bb1f-0a45596dc34d
 Console URL:             https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/stackinfo?stackId=arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/b8f62640-1055-11f1-bb1f-0a45596dc34d

Previous Stack Events (max 10):
 Mon Feb 23 2026 01:19:38 CREATE_IN_PROGRESS AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 01:19:40 CREATE_IN_PROGRESS AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 01:19:40 CREATE_IN_PROGRESS AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 01:19:40 CREATE_COMPLETE    AWS::CloudFormation::WaitConditionHandle TestWaitHandle (0s)
 Mon Feb 23 2026 01:19:41 CREATE_COMPLETE    AWS::CloudFormation::Stack               iidy-demo-hello-world (3s)

Stack Resources:
 TestWaitHandle    AWS::CloudFormation::WaitConditionHandle https://cloudformation-waitcondition-us-west-2.s3-us-west-2.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-west-2%3A903405759226%3Astack/iidy-demo-hello-world/b8f62640-1055-11f1-bb1f-0a45596dc34d/b8f69b70-1055-11f1-bb1f-0a45596dc34d/TestWaitHandle?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260223T011940Z&X-Amz-SignedHeaders=host&X-Amz-Expires=43199&X-Amz-Credential=AKIA54RCMT6SHHHS7Z75%2F20260223%2Fus-west-2%2Fs3%2Faws4_request&X-Amz-Signature=8bf102278a3ed51c0228eab73dee9b4f5139805220cabb97123c5e708e8c589f

Stack Outputs: None

Current Stack Status: CREATE_COMPLETE

? Are you sure you want to DELETE the stack iidy-demo-hello-world? (y/N) n # red fg text on prompt, leads with "? "

 Command Summary:         Success 👍
