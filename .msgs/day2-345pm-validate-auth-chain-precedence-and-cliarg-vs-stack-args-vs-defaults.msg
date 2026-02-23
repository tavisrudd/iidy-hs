There is significant complexity in the order of precedence and default handling in the rust version for the following:
- aws credentials pre and post stack args
- assume-role-arn
- profile
- region

You will need to do a careful case analysis and review both the code and docs from rust for each against what we do in this repo. Document your findings in a new reference doc in this repo and add a phase to verify / fix.
