2 issues: first our timeout for network connections to aws or to the metadata server maybe are different from the rs version. it never times out for hs below but after 5 sec or less for rs. Second when i control-c in hs i get a stack trace and then hang. it takes another c-c to exit:

> ./iidy-hs list-stacks
^Ciidy-hs: ExitFailure 130
HasCallStack backtrace:
  collectBacktraces, called at libraries/ghc-internal/src/GHC/Internal/Exception.hs:169:13 in ghc-internal:GHC.Internal.Exception
  toExceptionWithBacktrace, called at libraries/ghc-internal/src/GHC/Internal/IO.hs:260:11 in ghc-internal:GHC.Internal.IO
  throwIO, called at libraries/ghc-internal/src/GHC/Internal/System/Exit.hs:62:14 in ghc-internal:GHC.Internal.System.Exit


^C

> ./iidy-rs list-stacks
Stack List:

ERROR: No AWS region configured. Please specify a region via:
- CLI flag: --region us-east-1
- Stack args: Region: us-east-1
- Environment variable: AWS_REGION or AWS_DEFAULT_REGION
- AWS config file: ~/.aws/config
  • Check the AWS CloudFormation console for more details
