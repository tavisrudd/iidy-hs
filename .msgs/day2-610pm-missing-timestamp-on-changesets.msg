
> ./iidy-hs --region us-west-2 describe-stack iidy-demo-hello-world
Stack Details:
 Name:                    iidy-demo-hello-world
 Status:                  UPDATE_COMPLETE
 Capabilities:            None
 Service Role:            None
 Region:                  us-west-2
 Tags:                    environment=development, lifetime=short, project=iidy-demo, tmp=bar
 Parameters:              Name=world
 DisableRollback:         false
 TerminationProtection:   false
 Creation Time:           Mon Feb 23 2026 02:06:23
 Last Update Time:        Mon Feb 23 2026 02:09:28
 NotificationARNs:        None
 ARN:                     arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb
 Console URL:             https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/stackinfo?stackId=arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb

Previous Stack Events (max 50):
 Mon Feb 23 2026 02:06:23 REVIEW_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:06:33 CREATE_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:06:35 CREATE_IN_PROGRESS                  AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 02:06:35 CREATE_IN_PROGRESS                  AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 02:06:35 CREATE_COMPLETE                     AWS::CloudFormation::WaitConditionHandle TestWaitHandle (0s)
 Mon Feb 23 2026 02:06:36 CREATE_COMPLETE                     AWS::CloudFormation::Stack               iidy-demo-hello-world (3s)
 Mon Feb 23 2026 02:08:51 UPDATE_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:08:54 UPDATE_COMPLETE_CLEANUP_IN_PROGRESS AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:08:55 UPDATE_COMPLETE                     AWS::CloudFormation::Stack               iidy-demo-hello-world (0s)
 Mon Feb 23 2026 02:09:28 UPDATE_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:09:30 UPDATE_COMPLETE_CLEANUP_IN_PROGRESS AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:09:31 UPDATE_COMPLETE                     AWS::CloudFormation::Stack               iidy-demo-hello-world (0s)

Stack Resources:
 TestWaitHandle    AWS::CloudFormation::WaitConditionHandle https://cloudformation-waitcondition-us-west-2.s3-us-west-2.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-west-2%3A903405759226%3Astack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb/46b070c0-105c-11f1-8edd-024b7f948175/TestWaitHandle?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260223T020635Z&X-Amz-SignedHeaders=host&X-Amz-Expires=43199&X-Amz-Credential=AKIA54RCMT6SHHHS7Z75%2F20260223%2Fus-west-2%2Fs3%2Faws4_request&X-Amz-Signature=be54ae41d52269a0b26d8934e16c3a203ff3978733209454955eeefb0634d4e2

Stack Outputs: None

Current Stack Status: UPDATE_COMPLETE

Pending Changesets:
 Unknown                  iidy-create-or-update-21431c23 CREATE_COMPLETE
 ### HERE

## Also, we should so a minimum of 1s for op event durations not 0s like above. Rust does 1s below for the same stack.


> ./iidy-rs --region us-west-2 describe-stack iidy-demo-hello-world
Stack Details:
 Name:                    iidy-demo-hello-world
 Status:                  UPDATE_COMPLETE
 Capabilities:            None
 Service Role:            None
 Region:                  us-west-2
 Tags:                    environment=development, lifetime=short, project=iidy-demo, tmp=bar
 Parameters:              Name=world
 DisableRollback:         false
 TerminationProtection:   false
 Creation Time:           Mon Feb 23 2026 02:06:23
 Last Update Time:        Mon Feb 23 2026 02:09:28
 NotificationARNs:        None
 ARN:                     arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb
 Console URL:             https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/stackinfo?stackId=arn:aws:cloudformation:us-west-2:903405759226:stack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb

Previous Stack Events (max 50):
 Mon Feb 23 2026 02:06:23 REVIEW_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:06:33 CREATE_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:06:35 CREATE_COMPLETE                     AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 02:06:35 CREATE_IN_PROGRESS                  AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 02:06:35 CREATE_IN_PROGRESS                  AWS::CloudFormation::WaitConditionHandle TestWaitHandle
 Mon Feb 23 2026 02:06:36 CREATE_COMPLETE                     AWS::CloudFormation::Stack               iidy-demo-hello-world (3s)
 Mon Feb 23 2026 02:08:51 UPDATE_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:08:54 UPDATE_COMPLETE_CLEANUP_IN_PROGRESS AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:08:55 UPDATE_COMPLETE                     AWS::CloudFormation::Stack               iidy-demo-hello-world (1s)
 Mon Feb 23 2026 02:09:28 UPDATE_IN_PROGRESS                  AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:09:30 UPDATE_COMPLETE_CLEANUP_IN_PROGRESS AWS::CloudFormation::Stack               iidy-demo-hello-world
 Mon Feb 23 2026 02:09:31 UPDATE_COMPLETE                     AWS::CloudFormation::Stack               iidy-demo-hello-world (1s)

Stack Resources:
 TestWaitHandle    AWS::CloudFormation::WaitConditionHandle https://cloudformation-waitcondition-us-west-2.s3-us-west-2.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-west-2%3A903405759226%3Astack/iidy-demo-hello-world/40dff210-105c-11f1-99b4-02d3969b84fb/46b070c0-105c-11f1-8edd-024b7f948175/TestWaitHandle?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260223T020635Z&X-Amz-SignedHeaders=host&X-Amz-Expires=43199&X-Amz-Credential=AKIA54RCMT6SHHHS7Z75%2F20260223%2Fus-west-2%2Fs3%2Faws4_request&X-Amz-Signature=be54ae41d52269a0b26d8934e16c3a203ff3978733209454955eeefb0634d4e2

Stack Outputs: None

Current Stack Status: UPDATE_COMPLETE

Pending Changesets:
 Mon Feb 23 2026 02:09:55 iidy-create-or-update-21431c23 CREATE_COMPLETE
 # CORRECT HERE ^


