There's some suble 'liveness' / time since UI polish in the text displayed next to timers. Do detailed case analysis, create a research doc, then add a review phase to validate it and add missing test cases and fix it if needed.

Do the same thing for the event duration timing displayed in the live and past events output.

E.g. from rust:
' Mon Feb 23 2026 00:40:44 CREATE_COMPLETE    AWS::CloudFormation::Stack               iidy-demo-hello-world (3s)' # 3s is how long the operation the event is related to took


We are missing that display completely. Same routine: case analysis doc, and review+fix+test-cases phase.
