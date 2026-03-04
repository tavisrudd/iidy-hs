module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Iidy.Cli.HelpTest qualified as HelpTest
import Test.AwsLoaderTest (awsLoaderTests)
import Test.CfnYamlEmitterTest (cfnYamlEmitterTests)
import Test.ChangesetHelpersTest (changesetHelpersTests)
import Test.ChangesetTest (changesetTests)
import Test.CliParserTest (cliParserTests)
import Test.ConvertStackTest (convertStackTests)
import Test.DeleteStackTest (deleteStackTests)
import Test.DescribeStackTest (describeStackTests)
import Test.EmitterTest (emitterTests)
import Test.EngineTest (engineTests)
import Test.ErrorClassificationTest (errorClassificationTests)
import Test.ErrorColorTest (errorColorTests)
import Test.ErrorContentTest (errorContentTests)
import Test.ErrorFixtureTest (buildErrorTests)
import Test.ErrorIdTest (errorIdTests)
import Test.FilehashTest (filehashTests)
import Test.FixtureTest (buildFixtureTests)
import Test.GlobalConfigTest (globalConfigTests)
import Test.HandlebarsTest (handlebarsTests)
import Test.ImportLoaderTest (importLoaderTests)
import Test.IntegrationTest (integrationTests)
import Test.JMESPathTest (jmespathTests)
import Test.JsonRendererTest (jsonRendererTests)
import Test.JsonSchemaTest (jsonSchemaTests)
import Test.OValueTest (oValueTests)
import Test.ParamsClientTest (paramsClientTests)
import Test.ParserTest (parserTests)
import Test.Phase14FixTest (phase14FixTests)
import Test.PreprocessingPropertyTest (preprocessingPropertyTests)
import Test.PropertyTest (propertyTests)
import Test.RendererOutputTest (rendererOutputTests)
import Test.RendererTest (rendererTests)
import Test.RequestBuilderTest (requestBuilderTests)
import Test.ResolverTest (resolverTests)
import Test.SecurityControlsTest (securityControlsTests)
import Test.SpecConformanceTest (specConformanceTests)
import Test.StackArgsLoaderTest (stackArgsLoaderTests)
import Test.StackOpsConverterTest (stackOpsConverterTests)
import Test.TemplateDiffTest (templateDiffTests)
import Test.TemplateHashTest (templateHashTests)
import Test.TemplateLoaderTest (templateLoaderTests)
import Test.ThemeVariantTest (themeVariantTests)
import Test.TimingTest (timingTests)
import Test.WatchStackTest (watchStackTests)

main :: IO ()
main = do
    fixtureTests <- buildFixtureTests
    errorTests <- buildErrorTests
    conformanceTests <- specConformanceTests
    defaultMain $
        testGroup
            "iidy-hs"
            [ HelpTest.tests
            , testGroup "Parser" parserTests
            , testGroup "JMESPath" jmespathTests
            , testGroup "Handlebars" handlebarsTests
            , testGroup "Emitter" emitterTests
            , testGroup "Fixtures" fixtureTests
            , testGroup "ErrorFixtures" errorTests
            , testGroup "StackArgsLoader" stackArgsLoaderTests
            , testGroup "ConvertStack" convertStackTests
            , testGroup "TemplateHash" templateHashTests
            , testGroup "CliParser" cliParserTests
            , testGroup "OValue" oValueTests
            , testGroup "RequestBuilder" requestBuilderTests
            , testGroup "JsonSchema" jsonSchemaTests
            , testGroup "DeleteStack" deleteStackTests
            , testGroup "Changeset" changesetTests
            , testGroup "Properties" propertyTests
            , testGroup "WatchStack" watchStackTests
            , testGroup "ErrorColors" errorColorTests
            , testGroup "Renderer" rendererTests
            , testGroup "JsonRenderer" jsonRendererTests
            , testGroup "ThemeVariants" themeVariantTests
            , testGroup "RendererOutput" rendererOutputTests
            , testGroup "Integration" integrationTests
            , testGroup "Phase14Fixes" phase14FixTests
            , testGroup "Filehash" filehashTests
            , testGroup "ImportLoaders" importLoaderTests
            , testGroup "AwsLoaders" awsLoaderTests
            , testGroup "ErrorIds" errorIdTests
            , testGroup "ErrorClassification" errorClassificationTests
            , testGroup "Resolver" resolverTests
            , testGroup "CfnYamlEmitter" cfnYamlEmitterTests
            , testGroup "ChangesetHelpers" changesetHelpersTests
            , testGroup "DescribeStack" describeStackTests
            , testGroup "StackOpsConverters" stackOpsConverterTests
            , testGroup "Timing" timingTests
            , testGroup "SecurityControls" securityControlsTests
            , testGroup "ParamsClient" paramsClientTests
            , testGroup "TemplateLoader" templateLoaderTests
            , testGroup "GlobalConfig" globalConfigTests
            , testGroup "PreprocessingProperties" preprocessingPropertyTests
            , testGroup "ErrorContent" errorContentTests
            , testGroup "TemplateDiff" templateDiffTests
            , testGroup "SpecConformance" conformanceTests
            , testGroup "Engine" engineTests
            ]
