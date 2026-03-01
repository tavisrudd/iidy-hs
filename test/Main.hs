module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import qualified Iidy.Cli.HelpTest as HelpTest
import Test.ParserTest (parserTests)
import Test.JMESPathTest (jmespathTests)
import Test.HandlebarsTest (handlebarsTests)
import Test.EmitterTest (emitterTests)
import Test.FixtureTest (buildFixtureTests)
import Test.ErrorFixtureTest (buildErrorTests)
import Test.StackArgsLoaderTest (stackArgsLoaderTests)
import Test.ConvertStackTest (convertStackTests)
import Test.TemplateHashTest (templateHashTests)
import Test.CliParserTest (cliParserTests)
import Test.OValueTest (oValueTests)
import Test.RequestBuilderTest (requestBuilderTests)
import Test.JsonSchemaTest (jsonSchemaTests)
import Test.DeleteStackTest (deleteStackTests)
import Test.ChangesetTest (changesetTests)
import Test.PropertyTest (propertyTests)
import Test.WatchStackTest (watchStackTests)
import Test.ErrorColorTest (errorColorTests)
import Test.RendererTest (rendererTests)
import Test.JsonRendererTest (jsonRendererTests)
import Test.ThemeVariantTest (themeVariantTests)
import Test.RendererOutputTest (rendererOutputTests)
import Test.IntegrationTest (integrationTests)
import Test.Phase14FixTest (phase14FixTests)
import Test.FilehashTest (filehashTests)
import Test.ImportLoaderTest (importLoaderTests)
import Test.AwsLoaderTest (awsLoaderTests)
import Test.ErrorIdTest (errorIdTests)
import Test.ErrorClassificationTest (errorClassificationTests)
import Test.ResolverTest (resolverTests)
import Test.CfnYamlEmitterTest (cfnYamlEmitterTests)
import Test.ChangesetHelpersTest (changesetHelpersTests)

main :: IO ()
main = do
  fixtureTests <- buildFixtureTests
  errorTests <- buildErrorTests
  defaultMain $ testGroup "iidy-hs"
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
    ]
