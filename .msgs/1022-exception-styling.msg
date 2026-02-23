we need to verify that when bad arguments, missing files, or missing aws creds etc. are passed to iidy command
that our reporting back the user is the same as the rust version. See the special handling the rust version has for AWS connection errors, auth errors, etc. Add a new phase to the plan for this. As a quick example compare 'iidy-hs render 404' to iidy-rs.

> ./iidy-rs create-stack -
Command Metadata:

ERROR: No such file or directory (os error 2)
  • Check the AWS CloudFormation console for more details

> ./iidy-hs create-stack -
iidy-hs: -: openBinaryFile: does not exist (No such file or directory)
HasCallStack backtrace:  collectBacktraces, called at libraries/ghc-internal/src/GHC/Internal/Exception.hs:169:13 in ghc-internal:GHC.Internal.Exception  toExceptionWithBacktrace, called at libraries/ghc-internal/src/GHC/Internal/IO.hs:260:11 in ghc-internal:GHC.Internal.IO  throwIO, called at libraries/ghc-internal/src/GHC/Internal/IO/Exception.hs:315:19 in ghc-internal:GHC.Internal.IO.Exception  ioException, called at libraries/ghc-internal/src/GHC/Internal/IO/Exception.hs:319:20 in ghc-internal:GHC.Internal.IO.Exception
