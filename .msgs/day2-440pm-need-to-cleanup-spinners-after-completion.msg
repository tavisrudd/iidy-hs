# this next line from the spinner isn't being cleaned up properly
⠙ Loading live events...
Stack Resources:
 TestWaitHandle    AWS::CloudFormation::WaitConditionHandle https://cloudformation-waitcondition-us-west-2.s3-us-west-2.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-west-2%3A903405759226%3Astack/iidy-demo-hello-world/47d55f30-1050-11f1-80eb-06b0644a0239/47d5fb70-1050-11f1-80eb-06b0644a0239/TestWaitHandle?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260223T004043Z&X-Amz-SignedHeaders=host&X-Amz-Expires=43199&X-Amz-Credential=AKIA54RCMT6SHHHS7Z75%2F20260223%2Fus-west-2%2Fs3%2Faws4_request&X-Amz-Signature=a7b0db968d47833ba2afa12792808514834f6ce58072a754f8d92863de2edc63

Stack Outputs: None

Current Stack Status: CREATE_COMPLETE

 Command Summary:         Success 👍



Review the way spinners are cleaned up in the rust code and ensure we clean them up in all cases. No artifacts from them can be visible after they are done or canceled.
