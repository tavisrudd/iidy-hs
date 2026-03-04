module Iidy.Explain (
    explainErrors,
) where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (hPutStrLn, stderr)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Print detailed explanations for a list of error codes.
Codes may be given as \"ERR_2001\", \"err_2001\", or just \"2001\".
Prints to stdout for known codes, stderr for unknown codes.
-}
explainErrors :: [Text] -> IO ()
explainErrors [] = hPutStrLn stderr "Usage: iidy explain <CODE>..."
explainErrors codes = mapM_ explainOne codes

------------------------------------------------------------------------
-- Per-code dispatch
------------------------------------------------------------------------

explainOne :: Text -> IO ()
explainOne code =
    case lookupErrorCode code of
        Nothing -> TIO.hPutStrLn stderr $ "Unknown error code: " <> code
        Just entry -> do
            TIO.putStrLn $ "Error " <> ecCode entry
            TIO.putStrLn $ "Category: " <> ecCategory entry
            TIO.putStrLn $ "Description: " <> ecDescription entry
            TIO.putStrLn ""
            TIO.putStrLn (ecDetails entry)

------------------------------------------------------------------------
-- Error code lookup
------------------------------------------------------------------------

-- | Map from canonical error code to entry, built once from 'allErrors'.
errorMap :: Map.Map Text ErrorEntry
errorMap = Map.fromList [(ecCode e, e) | e <- allErrors]

lookupErrorCode :: Text -> Maybe ErrorEntry
lookupErrorCode raw = Map.lookup (normaliseCode raw) errorMap

-- | Normalise user input to the canonical \"ERR_NNNN\" form.
normaliseCode :: Text -> Text
normaliseCode t =
    let upper = T.toUpper t
        digits = fromMaybe upper (T.stripPrefix "ERR_" upper)
        padded = T.justifyRight 4 '0' digits
     in "ERR_" <> padded

------------------------------------------------------------------------
-- Error entry type
------------------------------------------------------------------------

data ErrorEntry = ErrorEntry
    { ecCode :: !Text
    , ecCategory :: !Text
    , ecDescription :: !Text
    , ecDetails :: !Text
    }
    deriving stock (Show, Eq)

mkEntry :: Text -> Text -> Text -> Text -> ErrorEntry
mkEntry = ErrorEntry

------------------------------------------------------------------------
-- Full error database (ported from Rust ids.rs)
------------------------------------------------------------------------

allErrors :: [ErrorEntry]
allErrors =
    -- 1xxx: YAML Syntax & Parsing
    [ mkEntry
        "ERR_1001"
        "YAML Syntax & Parsing"
        "Invalid YAML syntax"
        "The input is not valid YAML. Check for incorrect indentation, missing colons,\n\
        \unbalanced quotes, or other structural problems."
    , mkEntry
        "ERR_1002"
        "YAML Syntax & Parsing"
        "YAML version mismatch"
        "The YAML document declares a version directive that is not supported.\n\
        \iidy supports YAML 1.1 and 1.2."
    , mkEntry
        "ERR_1003"
        "YAML Syntax & Parsing"
        "Unsupported YAML feature"
        "The YAML document uses a feature that iidy does not support, such as\n\
        \complex keys or multi-document streams."
    , mkEntry
        "ERR_1004"
        "YAML Syntax & Parsing"
        "Malformed YAML structure"
        "The overall structure of the YAML document is incorrect for an iidy template.\n\
        \The top-level value must be a mapping."
    , mkEntry
        "ERR_1005"
        "YAML Syntax & Parsing"
        "YAML merge key not supported in 1.2"
        "The '<<' merge key is a YAML 1.1 extension. Either switch to YAML 1.1 mode\n\
        \(--yaml-spec 1.1) or rewrite the template to use explicit keys."
    , -- 2xxx: Variable & Scope Errors
      mkEntry
        "ERR_2001"
        "Variable & Scope"
        "Variable not found"
        "A !$ or {{...}} reference names a variable that is not defined in $defs or\n\
        \$imports. Check spelling and that the variable is defined before it is used."
    , mkEntry
        "ERR_2002"
        "Variable & Scope"
        "Variable name collision"
        "A variable is defined more than once in the same scope. Rename one of the\n\
        \definitions to resolve the conflict."
    , mkEntry
        "ERR_2003"
        "Variable & Scope"
        "Invalid variable name"
        "A variable name contains characters that are not allowed. Variable names must\n\
        \start with a letter or underscore and contain only alphanumeric characters,\n\
        \underscores, and hyphens."
    , mkEntry
        "ERR_2004"
        "Variable & Scope"
        "Circular variable reference"
        "Two or more $defs entries reference each other, forming a cycle. Restructure\n\
        \the definitions so that each variable depends only on previously defined ones."
    , mkEntry
        "ERR_2005"
        "Variable & Scope"
        "Variable access out of scope"
        "A variable is referenced outside the scope where it was defined, for example\n\
        \after the !$let block that introduced it has ended."
    , mkEntry
        "ERR_2006"
        "Variable & Scope"
        "Lookup query failed"
        "A JMESPath or query expression applied to a variable produced no result.\n\
        \Verify that the path exists and the structure matches expectations."
    , -- 3xxx: Import & Loading Errors
      mkEntry
        "ERR_3001"
        "Import & Loading"
        "Import file not found"
        "The file referenced in $imports does not exist at the given path.\n\
        \Paths are resolved relative to the current template file."
    , mkEntry
        "ERR_3002"
        "Import & Loading"
        "Import URL unreachable"
        "An HTTP/HTTPS import could not be reached. Check network connectivity and\n\
        \that the URL is correct."
    , mkEntry
        "ERR_3003"
        "Import & Loading"
        "Import authentication failure"
        "Credentials were rejected when loading an import. Check AWS credentials,\n\
        \IAM permissions, or HTTP authentication headers."
    , mkEntry
        "ERR_3004"
        "Import & Loading"
        "Import circular dependency"
        "File A imports file B which (directly or indirectly) imports file A again.\n\
        \Restructure imports to remove the cycle."
    , mkEntry
        "ERR_3005"
        "Import & Loading"
        "Import format not supported"
        "The imported file has an extension that iidy does not know how to parse.\n\
        \Supported formats are .yaml, .yml, and .json."
    , mkEntry
        "ERR_3006"
        "Import & Loading"
        "Environment variable not found"
        "An !$env reference names an environment variable that is not set.\n\
        \Set the variable in the shell before running iidy, or provide a default."
    , mkEntry
        "ERR_3007"
        "Import & Loading"
        "Git command failure"
        "A git:// import failed because the git command could not be executed or\n\
        \returned a non-zero exit code. Ensure git is on PATH and the repository is\n\
        \accessible."
    , mkEntry
        "ERR_3008"
        "Import & Loading"
        "S3 access denied"
        "An s3:// import was rejected due to insufficient IAM permissions.\n\
        \Check the bucket policy and the IAM role or user associated with your\n\
        \AWS credentials."
    , mkEntry
        "ERR_3009"
        "Import & Loading"
        "SSM parameter not found"
        "An ssm:// import references a Parameter Store path that does not exist\n\
        \in the target region and account."
    , mkEntry
        "ERR_3010"
        "Import & Loading"
        "CloudFormation stack not found"
        "A cfn:// import references a CloudFormation stack that does not exist\n\
        \or is in a region different from the one configured."
    , -- 4xxx: Tag Syntax & Structure Errors
      mkEntry
        "ERR_4001"
        "Tag Syntax & Structure"
        "Unknown preprocessing tag"
        "The template uses a !$ tag that iidy does not recognise. Check the spelling\n\
        \and consult the iidy documentation for the list of supported tags."
    , mkEntry
        "ERR_4002"
        "Tag Syntax & Structure"
        "Missing required tag field"
        "A preprocessing tag is missing a field that it requires. For example,\n\
        \!$map requires both 'items' and 'template' fields."
    , mkEntry
        "ERR_4003"
        "Tag Syntax & Structure"
        "Invalid tag field value"
        "A field within a preprocessing tag has a value of the wrong type or an\n\
        \out-of-range value. Consult the tag's documentation for the expected type."
    , mkEntry
        "ERR_4004"
        "Tag Syntax & Structure"
        "Incompatible tag combination"
        "Two preprocessing tags are used together in a way that is not allowed.\n\
        \See the documentation for restrictions on tag combinations."
    , mkEntry
        "ERR_4005"
        "Tag Syntax & Structure"
        "Tag syntax error"
        "The value attached to a preprocessing tag is structurally incorrect.\n\
        \For example, a tag that expects a sequence received a mapping."
    , -- 5xxx: Type & Validation Errors
      mkEntry
        "ERR_5001"
        "Type & Validation"
        "Type mismatch in operation"
        "An operation was applied to a value of an incompatible type. For example,\n\
        \arithmetic on a string, or a string operation on a number."
    , mkEntry
        "ERR_5002"
        "Type & Validation"
        "Invalid array operation"
        "An array operation (e.g., !$map, !$concat) was applied to a value that is\n\
        \not an array."
    , mkEntry
        "ERR_5003"
        "Type & Validation"
        "Invalid object operation"
        "A mapping operation was applied to a value that is not a mapping."
    , mkEntry
        "ERR_5004"
        "Type & Validation"
        "Division by zero"
        "A numeric expression attempted to divide by zero."
    , mkEntry
        "ERR_5005"
        "Type & Validation"
        "Invalid comparison"
        "A comparison operator was applied to values of incompatible types, for\n\
        \example comparing a number to a list."
    , mkEntry
        "ERR_5006"
        "Type & Validation"
        "String operation on non-string"
        "A string function (e.g., upper, lower, trim) received a non-string argument."
    , -- 6xxx: Template & Handlebars Errors
      mkEntry
        "ERR_6001"
        "Template & Handlebars"
        "Handlebars syntax error"
        "A {{...}} expression contains invalid Handlebars syntax. Check for unmatched\n\
        \braces, missing helper arguments, or unsupported constructs."
    , mkEntry
        "ERR_6002"
        "Template & Handlebars"
        "Unknown Handlebars helper"
        "The Handlebars template references a helper function that iidy does not\n\
        \provide. Check the helper name spelling against the documented helpers."
    , mkEntry
        "ERR_6003"
        "Template & Handlebars"
        "Handlebars helper argument error"
        "A Handlebars helper was called with the wrong number or type of arguments.\n\
        \Consult the helper's documentation for the expected signature."
    , mkEntry
        "ERR_6004"
        "Template & Handlebars"
        "Template compilation failure"
        "The Handlebars template could not be compiled. This usually indicates a\n\
        \syntax error deeper than a simple parse failure."
    , mkEntry
        "ERR_6005"
        "Template & Handlebars"
        "Template execution error"
        "An error occurred while rendering a Handlebars template at runtime,\n\
        \for example when a helper function throws."
    , -- 7xxx: CloudFormation Specific
      mkEntry
        "ERR_7001"
        "CloudFormation Specific"
        "Invalid CloudFormation intrinsic function"
        "A CloudFormation intrinsic (e.g., !Ref, !Sub) was used with incorrect\n\
        \arguments or in a context where it is not allowed."
    , mkEntry
        "ERR_7002"
        "CloudFormation Specific"
        "CloudFormation reference error"
        "A !Ref or !GetAtt targets a logical resource ID that does not exist in\n\
        \the template's Resources section."
    , mkEntry
        "ERR_7003"
        "CloudFormation Specific"
        "CloudFormation dependency issue"
        "A DependsOn or implicit dependency creates a problem such as a cycle in\n\
        \the resource dependency graph."
    , mkEntry
        "ERR_7004"
        "CloudFormation Specific"
        "CloudFormation template size limit"
        "The rendered template exceeds the CloudFormation limit (51,200 bytes for\n\
        \direct upload; 460,800 bytes via S3). Reduce the template size or split\n\
        \it into nested stacks."
    , -- 8xxx: Configuration & Setup
      mkEntry
        "ERR_8001"
        "Configuration & Setup"
        "Invalid command line argument"
        "A command line option has an unrecognised value or format. Run\n\
        \'iidy --help' for usage information."
    , mkEntry
        "ERR_8002"
        "Configuration & Setup"
        "Missing required configuration"
        "A required configuration value was not provided either on the command\n\
        \line or in the stack args file."
    , mkEntry
        "ERR_8003"
        "Configuration & Setup"
        "Configuration file not found"
        "The specified stack args file or configuration file does not exist at\n\
        \the given path."
    , mkEntry
        "ERR_8004"
        "Configuration & Setup"
        "AWS credentials not configured"
        "No AWS credentials could be found. Configure credentials via environment\n\
        \variables (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), an AWS profile\n\
        \(~/.aws/credentials), or an IAM instance role."
    , mkEntry
        "ERR_8005"
        "Configuration & Setup"
        "Unsupported file format"
        "The input file has an extension that iidy cannot process. Use .yaml,\n\
        \.yml, or .json."
    , -- 9xxx: Internal & System Errors
      mkEntry
        "ERR_9001"
        "Internal & System"
        "Internal processing error"
        "iidy encountered an unexpected internal error. This is likely a bug.\n\
        \Please report it with the full error output."
    , mkEntry
        "ERR_9002"
        "Internal & System"
        "Memory allocation failure"
        "The process ran out of memory while processing the template. Try splitting\n\
        \large templates into smaller files."
    , mkEntry
        "ERR_9003"
        "Internal & System"
        "File system permission denied"
        "iidy does not have permission to read an input file or write an output\n\
        \file. Check file and directory permissions."
    , mkEntry
        "ERR_9004"
        "Internal & System"
        "Network connectivity issue"
        "A network operation failed due to connectivity problems. Check your network\n\
        \connection and any proxy or firewall settings."
    , mkEntry
        "ERR_9005"
        "Internal & System"
        "Unexpected system error"
        "An unclassified system-level error occurred. See the accompanying error\n\
        \message for details."
    ]
