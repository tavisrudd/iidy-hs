{- | Escaping of terminal control characters in text that comes from outside
the tool (template text, AWS strings, exception text).

Untrusted text is passed through 'escapeControl' before the renderer adds its
own colour codes and before any width calculation, so a value cannot rewrite
or hide lines on the reviewer's terminal. Each escaped character becomes
@\\uNNNN@ (four lower-case hex digits), the spelling the YAML emitter also
uses for control characters.

Deliberately not applied to document output (@OdRawOutput@ and the template
body of @OdStackTemplate@): those bytes must stay exact.
-}
module Iidy.Output.Sanitize (
    escapeControl,
    needsEscape,
    escapeOutputData,
) where

import Data.Bifunctor (bimap)
import Data.Char (ord)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)

import Iidy.Aws.ClientReqToken (TokenInfo (..))
import Iidy.Output.Types

{- | Whether a character is escaped unconditionally: C0 controls except
newline and tab (a carriage return is handled by 'escapeControl', since it is
kept before a newline), DEL, C1 controls, line and paragraph separators and
the bidirectional controls.
-}
needsEscape :: Char -> Bool
needsEscape c
    | c == '\n' || c == '\t' = False
    | n < 0x20 = True
    | n == 0x7f = True
    | n >= 0x80 && n <= 0x9f = True
    | n == 0x2028 || n == 0x2029 = True
    | n >= 0x202a && n <= 0x202e = True
    | n >= 0x2066 && n <= 0x2069 = True
    | otherwise = False
  where
    n = ord c

{- | Replace every control character that could disturb a terminal by its
@\\uNNNN@ form. Newline and tab are kept, and so is a carriage return that
is directly followed by a newline. Text without such characters is returned
unchanged.
-}
escapeControl :: Text -> Text
escapeControl t
    | T.all safe t = t
    | otherwise = T.pack (go (T.unpack t))
  where
    safe c = not (needsEscape c) && c /= '\r'
    go [] = []
    go ('\r' : '\n' : rest) = '\r' : '\n' : go rest
    go (c : rest)
        | needsEscape c || c == '\r' = visible c <> go rest
        | otherwise = c : go rest
    visible c =
        let hex = showHex (ord c) ""
         in "\\u" <> replicate (4 - length hex) '0' <> hex

------------------------------------------------------------------------
-- Output data
------------------------------------------------------------------------

{- | Escape every text field that can carry text from outside the tool in an
'OutputData' value, so a renderer sees (and measures) the visible text.
'OdRawOutput' and the template body of 'OdStackTemplate' are document
output and are returned exactly as given.
-}
escapeOutputData :: OutputData -> OutputData
escapeOutputData = \case
    OdCommandMetadata m -> OdCommandMetadata (escMeta m)
    OdStackDefinition d showTimes -> OdStackDefinition (escDef d) showTimes
    OdStackEvents d -> OdStackEvents (escEventsDisplay d)
    OdStackContents c -> OdStackContents (escContents c)
    OdStatusUpdate u -> OdStatusUpdate u{suMessage = e (suMessage u)}
    OdCommandResult r -> OdCommandResult r{crMessage = em (crMessage r)}
    od@(OdFinalCommandSummary _) -> od
    OdStackList l -> OdStackList l{sldStacks = map escListEntry (sldStacks l), sldFiltersApplied = map e (sldFiltersApplied l)}
    OdChangeSetResult r -> OdChangeSetResult (escChangeSetResult r)
    OdStackDrift d -> OdStackDrift d{sdrDriftedResources = map escDrifted (sdrDriftedResources d)}
    OdError i -> OdError (escErrorInfo i)
    OdTokenInfo t -> OdTokenInfo (escToken t)
    OdNewStackEvents evs -> OdNewStackEvents (map escEventTiming evs)
    od@(OdOperationComplete _) -> od
    od@(OdInactivityTimeout _) -> od
    OdConfirmationPrompt c -> OdConfirmationPrompt c{cfrMessage = e (cfrMessage c), cfrKey = em (cfrKey c)}
    OdStackChangeDetails c -> OdStackChangeDetails c{scdStackName = e (scdStackName c)}
    OdStackAbsentInfo a -> OdStackAbsentInfo (escAbsent a)
    OdCostEstimate (CostEstimate i) ->
        OdCostEstimate (CostEstimate i{ceiUrl = e (ceiUrl i), ceiStackName = em (ceiStackName i), ceiTemplateFile = em (ceiTemplateFile i)})
    OdStackTemplate t -> OdStackTemplate t{stStderrLines = map e (stStderrLines t)}
    OdApprovalRequestResult r ->
        OdApprovalRequestResult r{arrTemplateLocation = e (arrTemplateLocation r), arrPendingLocation = e (arrPendingLocation r), arrNextSteps = map e (arrNextSteps r)}
    OdTemplateValidation v -> OdTemplateValidation v{tvErrors = map e (tvErrors v), tvWarnings = map e (tvWarnings v)}
    OdApprovalStatus s -> OdApprovalStatus s{apsPendingLocation = e (apsPendingLocation s), apsApprovedLocation = em (apsApprovedLocation s)}
    OdTemplateDiff d -> OdTemplateDiff d{tdDiffOutput = e (tdDiffOutput d)}
    OdApprovalResult r -> OdApprovalResult r{arApprovedLocation = em (arApprovedLocation r), arLatestLocation = em (arLatestLocation r)}
    OdPollingStarted msg -> OdPollingStarted (e msg)
    od@(OdRawOutput _) -> od

e :: Text -> Text
e = escapeControl

em :: Maybe Text -> Maybe Text
em = fmap escapeControl

{- | Escape keys and values of a text map. Two keys that differ only in
escaped characters would collide; the later one in key order wins.
-}
escMap :: Map Text Text -> Map Text Text
escMap = Map.fromList . map (bimap e e) . Map.toList

escToken :: TokenInfo -> TokenInfo
escToken t = t{tiValue = e (tiValue t), tiOperationId = e (tiOperationId t)}

escMeta :: CommandMetadata -> CommandMetadata
escMeta m =
    m
        { cmEnvironment = e (cmEnvironment m)
        , cmRegion = e (cmRegion m)
        , cmProfile = em (cmProfile m)
        , cmCliArguments = escMap (cmCliArguments m)
        , cmIamServiceRole = em (cmIamServiceRole m)
        , cmCurrentIamPrincipal = e (cmCurrentIamPrincipal m)
        , cmCredentialSource = e (cmCredentialSource m)
        , cmVersion = e (cmVersion m)
        , cmPrimaryToken = escToken (cmPrimaryToken m)
        , cmDerivedTokens = map escToken (cmDerivedTokens m)
        }

escDef :: StackDefinition -> StackDefinition
escDef d =
    d
        { sdName = e (sdName d)
        , sdStacksetName = em (sdStacksetName d)
        , sdDescription = em (sdDescription d)
        , sdStatusReason = em (sdStatusReason d)
        , sdCapabilities = map e (sdCapabilities d)
        , sdServiceRole = em (sdServiceRole d)
        , sdTags = escMap (sdTags d)
        , sdParameters = escMap (sdParameters d)
        , sdNotificationArns = map e (sdNotificationArns d)
        , sdStackPolicy = em (sdStackPolicy d)
        , sdArn = e (sdArn d)
        , sdConsoleUrl = e (sdConsoleUrl d)
        , sdRegion = e (sdRegion d)
        }

escEvent :: StackEvent -> StackEvent
escEvent v =
    v
        { seEventId = e (seEventId v)
        , seStackId = e (seStackId v)
        , seStackName = e (seStackName v)
        , seLogicalResourceId = e (seLogicalResourceId v)
        , sePhysicalResourceId = em (sePhysicalResourceId v)
        , seResourceType = e (seResourceType v)
        , seResourceStatusReason = em (seResourceStatusReason v)
        , seResourceProperties = em (seResourceProperties v)
        , seClientRequestToken = em (seClientRequestToken v)
        }

escEventTiming :: StackEventWithTiming -> StackEventWithTiming
escEventTiming w = w{sewEvent = escEvent (sewEvent w)}

escEventsDisplay :: StackEventsDisplay -> StackEventsDisplay
escEventsDisplay d = d{sedTitle = e (sedTitle d), sedEvents = map escEventTiming (sedEvents d)}

escContents :: StackContents -> StackContents
escContents c =
    c
        { scResources = map escResource (scResources c)
        , scOutputs = map escOutput (scOutputs c)
        , scExports = map escExport (scExports c)
        , scCurrentStatus = (scCurrentStatus c){ssiStatusReason = em (ssiStatusReason (scCurrentStatus c))}
        , scPendingChangesets = map escChangeSetInfo (scPendingChangesets c)
        }

escResource :: StackResourceInfo -> StackResourceInfo
escResource r =
    r
        { sriLogicalResourceId = e (sriLogicalResourceId r)
        , sriPhysicalResourceId = em (sriPhysicalResourceId r)
        , sriResourceType = e (sriResourceType r)
        , sriResourceStatusReason = em (sriResourceStatusReason r)
        }

escOutput :: StackOutputInfo -> StackOutputInfo
escOutput o =
    o
        { soiOutputKey = e (soiOutputKey o)
        , soiOutputValue = e (soiOutputValue o)
        , soiDescription = em (soiDescription o)
        , soiExportName = em (soiExportName o)
        }

escExport :: StackExportInfo -> StackExportInfo
escExport x =
    x
        { seiName = e (seiName x)
        , seiValue = e (seiValue x)
        , seiExportingStackId = e (seiExportingStackId x)
        , seiImportingStacks = map e (seiImportingStacks x)
        }

escChangeSetInfo :: ChangeSetInfo -> ChangeSetInfo
escChangeSetInfo c =
    c
        { csiChangeSetName = e (csiChangeSetName c)
        , csiChangeSetId = e (csiChangeSetId c)
        , csiStackId = e (csiStackId c)
        , csiStackName = e (csiStackName c)
        , csiDescription = em (csiDescription c)
        , csiStatus = e (csiStatus c)
        , csiStatusReason = em (csiStatusReason c)
        , csiExecutionStatus = em (csiExecutionStatus c)
        , csiChanges = map escChange (csiChanges c)
        }

escChange :: ChangeInfo -> ChangeInfo
escChange c =
    c
        { ciAction = e (ciAction c)
        , ciLogicalResourceId = e (ciLogicalResourceId c)
        , ciPhysicalResourceId = em (ciPhysicalResourceId c)
        , ciResourceType = e (ciResourceType c)
        , ciReplacement = em (ciReplacement c)
        , ciScope = fmap (map e) (ciScope c)
        , ciDetails = map escDetail (ciDetails c)
        }

escDetail :: ChangeDetail -> ChangeDetail
escDetail d =
    d
        { cdTarget = e (cdTarget d)
        , cdEvaluation = em (cdEvaluation d)
        , cdChangeSource = em (cdChangeSource d)
        , cdCausingEntity = em (cdCausingEntity d)
        }

escChangeSetResult :: ChangeSetCreationResult -> ChangeSetCreationResult
escChangeSetResult r =
    r
        { csrChangesetName = e (csrChangesetName r)
        , csrStackName = e (csrStackName r)
        , csrChangesetType = e (csrChangesetType r)
        , csrStatus = e (csrStatus r)
        , csrConsoleUrl = e (csrConsoleUrl r)
        , csrPendingChangesets = map escChangeSetInfo (csrPendingChangesets r)
        , csrNextSteps = map e (csrNextSteps r)
        }

escListEntry :: StackListEntry -> StackListEntry
escListEntry s =
    s
        { sleStackName = e (sleStackName s)
        , sleTags = escMap (sleTags s)
        , sleStatusReason = em (sleStatusReason s)
        , sleEnvironmentType = em (sleEnvironmentType s)
        }

escAbsent :: StackAbsentInfo -> StackAbsentInfo
escAbsent a =
    a
        { saiStackName = e (saiStackName a)
        , saiEnvironment = e (saiEnvironment a)
        , saiRegion = e (saiRegion a)
        , saiAccount = e (saiAccount a)
        , saiAuthArn = e (saiAuthArn a)
        }

escDrifted :: DriftedResource -> DriftedResource
escDrifted d =
    d
        { drLogicalResourceId = e (drLogicalResourceId d)
        , drPhysicalResourceId = e (drPhysicalResourceId d)
        , drResourceType = e (drResourceType d)
        , drDriftStatus = e (drDriftStatus d)
        , drPropertyDifferences = map escPropertyDiff (drPropertyDifferences d)
        }

escPropertyDiff :: PropertyDifference -> PropertyDifference
escPropertyDiff p =
    p
        { pdPropertyPath = e (pdPropertyPath p)
        , pdExpectedValue = em (pdExpectedValue p)
        , pdActualValue = em (pdActualValue p)
        , pdDifferenceType = em (pdDifferenceType p)
        }

escErrorInfo :: ErrorInfo -> ErrorInfo
escErrorInfo i =
    i
        { eiErrorType = e (eiErrorType i)
        , eiMessage = e (eiMessage i)
        , eiSuggestions = map e (eiSuggestions i)
        , eiErrorDetails = case eiErrorDetails i of
            ErrorGeneric d -> ErrorGeneric (em d)
            ErrorStackAbsent a -> ErrorStackAbsent (escAbsent a)
        }
