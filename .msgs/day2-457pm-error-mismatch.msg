> ./iidy-rs --region us-west-2 describe-stack iidy-demo-hello-world
Stack Details:

ERROR The stack iidy-demo-hello-world is absent
      env = development
      region = us-west-2
      account = 903405759226
      auth_arn = arn:aws:iam::903405759226:user/tavis-cli.
 tavis  grover  ~/src/iidy-hs  main 2✎ aws: dss  1 
> ./iidy-hs --region us-west-2 describe-stack iidy-demo-hello-world
ERROR: ServiceError (ServiceError' {abbrev = Abbrev {fromAbbrev = "CloudFormation"}, status = Status {statusCode = 400, statusMessage = "Bad Request"}, headers = [("x-amzn-RequestId","ead20f5c-0592-4ad4-8837-3c45fad63302"),("Date","Mon, 23 Feb 2026 00:57:43 GMT"),("Content-Type","text/xml"),("Content-Length","307"),("connection","keep-alive")], code = ErrorCode "ValidationError", message = Just (ErrorMessage {fromErrorMessage = "Stack with id iidy-demo-hello-world does not exist"}), requestId = Just (RequestId {fromRequestId = "ead20f5c-0592-4ad4-8837-3c45fad63302"})})
  • Check the AWS CloudFormation console for more details



> ./iidy-hs --region us-west-2 create-stack ../iidy/example-stacks/hello-world/stack-args.yaml
Command Metadata:
 iidy Environment:        development
 Region:                  us-west-2
 IAM Service Role:        None
 Current IAM Principal:   arn:aws:iam::903405759226:user/tavis-cli
 Credential Source:       environment variables (temporary) (overrides: profile 'default' (default))
 CLI Arguments:           region=us-west-2, stack-name=iidy-demo-hello-world
 iidy Version:            0.1.0.0
 Client Req Token:        dbed2f56-fb16-44af-ae86-c98c3c7f4dd7 (auto-generated)
ERROR: ServiceError (ServiceError' {abbrev = Abbrev {fromAbbrev = "CloudFormation"}, status = Status {statusCode = 400, statusMessage = "Bad Request"}, headers = [("x-amzn-RequestId","502bbbc4-30ab-4607-9e90-ef0ce66c606a"),("Date","Mon, 23 Feb 2026 01:01:04 GMT"),("Content-Type","text/xml"),("Content-Length","308"),("connection","keep-alive")], code = ErrorCode "AlreadyExists", message = Just (ErrorMessage {fromErrorMessage = "Stack [iidy-demo-hello-world] already exists"}), requestId = Just (RequestId {fromRequestId = "502bbbc4-30ab-4607-9e90-ef0ce66c606a"})})
  • Check the AWS CloudFormation console for more details



Catch and properly format all such errors. Do a case analysis against the rust code -> research doc, add a phase
