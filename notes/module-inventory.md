# iidy Rust Codebase Module Inventory

## Project Overview
**Total Source Code:** ~16,615 lines of Rust across 96 .rs files
**Architecture:** Two-phase YAML preprocessing pipeline with CloudFormation operations
**External Dependencies:** AWS SDK (cloudformation, s3, ssm, kms, sts), serde, tokio, yaml-rust, tree-sitter

---

## I. Top-Level Modules (Library Entry Points)

### lib.rs (9 LOC)
**Purpose:** Library root - publicly exports all major subsystems  
**Public API:**
- `pub mod aws;`
- `pub mod cfn;`
- `pub mod cli;`
- `pub mod debug;`
- `pub mod explain;`
- `pub mod output;`
- `pub mod params;`
- `pub mod render;`
- `pub mod yaml;`

**Dependencies:** None (module declarations only)

---

### main.rs (306 LOC)
**Purpose:** CLI entry point - handles command routing and async runtime setup  
**Public API:**
- `fn main()` - Entry point with clap parsing and color theme initialization
- `fn handle_command(cli: Cli)` - Async command handler router

**Key Exports:** None (binary target)

**Internal Dependencies:**
- `crate::cfn::*` - CloudFormation operations
- `crate::cli::*` - CLI argument structs
- `crate::params::*` - Parameter handling
- `crate::explain::*` - Error explanation
- `crate::render::*` - Template rendering
- `crate::output::*` - Output management
- `crate::demo` - Demo functionality

**External Dependencies:**
- `clap` (parsing, completion generation)
- `log`, `env_logger` (logging)
- `tokio::runtime::Runtime` (async runtime management)

---

### cli.rs (900 LOC)
**Purpose:** Command-line interface definition and parsing  
**Public Structures:**
```rust
pub struct Cli {
    pub global_opts: GlobalOpts,
    pub aws_opts: AwsOpts,
    pub command: Commands,
}

pub struct GlobalOpts {
    pub environment: String,
    pub color: ColorChoice,
    pub theme: Theme,
    pub output_mode: Option<crate::output::OutputMode>,
    pub debug: bool,
    pub log_full_error: bool,
}

pub struct AwsOpts {
    pub region: Option<String>,
    pub profile: Option<String>,
    pub assume_role_arn: Option<String>,
    pub client_request_token: Option<String>,
}

pub struct NormalizedAwsOpts {
    pub region: Option<String>,
    pub profile: Option<String>,
    pub assume_role_arn: Option<String>,
    pub client_request_token: crate::aws::client_req_token::TokenInfo,
    pub fixture_set: Option<String>,
}

pub enum Commands {
    CreateStack(CreateStackArgs),
    UpdateStack(UpdateStackArgs),
    CreateOrUpdate(UpdateStackArgs),
    EstimateCost(StackFileArgs),
    CreateChangeset(CreateChangeSetArgs),
    ExecChangeset(ExecChangeSetArgs),
    DescribeStack(DescribeArgs),
    WatchStack(WatchArgs),
    DescribeStackDrift(DriftArgs),
    DeleteStack(DeleteArgs),
    GetStackTemplate(GetTemplateArgs),
    GetStackInstances(GetStackInstancesArgs),
    ListStacks(ListArgs),
    Param { command: ParamCommands },
    TemplateApproval { command: ApprovalCommands },
    Render(RenderArgs),
    GetImport(GetImportArgs),
    Demo(DemoArgs),
    LintTemplate(LintTemplateArgs),
    ConvertStackToIidy(ConvertArgs),
    InitStackArgs(InitStackArgs),
    Completion { shell: Option<Shell> },
    Explain { codes: Vec<String> },
}

pub enum ParamCommands {
    Set(ParamSetArgs),
    Review(ParamPathArg),
    Get(ParamGetArgs),
    GetByPath(ParamGetByPathArgs),
    GetHistory(ParamGetArgs),
}

pub enum ApprovalCommands {
    Request(ApprovalRequestArgs),
    Review(ApprovalReviewArgs),
}
```

**Public Enums:**
- `ColorChoice::Auto, Always, Never`
- `Theme::Auto, Light, Dark, HighContrast`
- `TemplateFormat::Json, Yaml, Original`
- `TemplateStageArg::Original, Processed`
- `YamlSpec::V11, V12, Auto`

**Key Public Functions:**
- `pub fn normalize(self) -> NormalizedAwsOpts` - Normalize AWS opts with token generation
- `pub fn to_cfn_operation(&self) -> CfnOperation` - Extract CFN operation from command
- `pub fn to_arg_map(&self) -> HashMap<String, String>` - Convert CLI args to metadata map

**Traits Implemented:**
- `ToArgMap` - Convert CLI args to HashMap for metadata display

**External Dependencies:**
- `clap` - CLI parsing and completion
- `uuid` - Generate client request tokens

---

### debug.rs (21 LOC)
**Purpose:** Zero-cost debug logging macro for conditional logging  
**Public Macros:**
- `debug_log!` - Expands to `log::debug!()` if "debug-logging" feature enabled, else no-op

**Feature Gates:** `#[cfg(feature = "debug-logging")]`

---

### explain.rs (60 LOC)
**Purpose:** Error code explanation command  
**Public Functions:**
- `pub fn handle_explain_command(codes: Vec<String>)` - Display explanations for error codes

**Internal Dependencies:**
- `crate::yaml::errors::ErrorId` - Error ID parsing and explanation

---

### render.rs (194 LOC)
**Purpose:** Render command implementation for template preprocessing  
**Public Functions:**
- `pub async fn handle_render_command(args: &RenderArgs) -> Result<()>` - Main render handler
- `pub fn apply_query_to_value(value: Value, query: &str) -> Result<Value>` - Apply dot-notation queries

**Internal Dependencies:**
- `crate::yaml::engine::*` - YAML preprocessing
- `crate::cli::RenderArgs` - Render command arguments

**External Dependencies:**
- `serde_yaml::Value` - YAML value handling
- `anyhow::Result` - Error handling

---

### demo.rs (610 LOC)
**Purpose:** Demo script execution with command substitution and output masking  
**Public Functions:**
- `pub async fn run(script_path: &str, timescaling: f64, mask_secrets: bool) -> Result<()>` - Execute demo script

**Key Structures:**
```rust
enum DemoCommand {
    Shell(String),
    Silent(String),
    Sleep(u64),
    SetEnv(HashMap<String, String>),
    Banner(String),
}

struct DemoScript {
    files: HashMap<String, String>,
    demo: Vec<RawCommand>,
}
```

**Private Functions:**
- `fn substitute_iidy_command(cmd: &str, iidy_exe: &str) -> String` - Replace iidy command with path
- `fn is_iidy_on_path_same_as_current_exe(current_exe_path: &str) -> bool` - Check PATH
- `fn unpack_files(files: &HashMap<String, String>, tmp_dir: &Path) -> Result<()>` - Create temp files
- `fn exec(cmd: &str, cwd: &Path, env: &HashMap<String, String>, mask_secrets: bool) -> Result<()>` - Execute command
- `fn exec_direct(...) -> Result<ExitStatus>` - Direct execution (no masking)
- `fn exec_with_masking(...) -> Result<ExitStatus>` - PTY execution with output masking
- `fn stream_and_mask_pty_output(reader: Box<dyn Read + Send>) -> Result<()>` - Mask AWS account numbers
- `fn mask_aws_account_numbers(text: &str) -> String` - Regex-based masking
- `async fn print_command(cmd: &str, timescaling: f64) -> Result<()>` - Type out command with delay
- `fn display_banner(text: &str)` - Display colored banner

**External Dependencies:**
- `crossterm` - Terminal UI primitives
- `portable_pty` - PTY management
- `regex::Regex` - Pattern matching for account masking
- `tokio::time::sleep` - Async delays
- `serde::Deserialize` - YAML parsing
- `tempfile::tempdir` - Temporary directories

---

## II. YAML Subsystem

The YAML subsystem implements CloudFormation-compatible YAML preprocessing with two-phase architecture: Phase 1 loads imports and builds environment, Phase 2 resolves custom tags and interpolates values.

### yaml/mod.rs (29 LOC)
**Purpose:** Module organization and public API exports  
**Public Exports:**
- `pub use engine::{preprocess_yaml, preprocess_yaml_v11};`
- `pub use detection::{YamlSpecDetection, detect_yaml_spec, is_cloudformation_template, is_kubernetes_manifest};`
- `pub use errors::ErrorId;`

**Submodules:**
- `custom_resources` - Custom resource template expansion
- `detection` - YAML spec version detection
- `emitter` - Custom YAML output
- `engine` - Main preprocessing pipeline
- `errors` - Error IDs and handling
- `handlebars` - Template interpolation
- `imports` - Import system
- `jmespath` - JMESPath query evaluation
- `location` - Error position tracking
- `parsing` - YAML parsing to AST
- `path_tracker` - AST path tracking
- `resolution` - Custom tag resolution
- `tree_sitter_location` - Tree-sitter based location finding

---

### yaml/engine.rs (829 LOC)
**Purpose:** Main YAML preprocessing orchestration (two-phase pipeline)  
**Public Functions:**
- `pub async fn preprocess_yaml(input: &str, location: &str, yaml_spec: &YamlSpec) -> Result<Value>` - Auto-detect YAML spec
- `pub async fn preprocess_yaml_v11(input: &str, location: &str) -> Result<Value>` - CloudFormation YAML 1.1
- `pub async fn serialize_yaml_iidy_js_compatible(value: &Value) -> Result<String>` - Custom YAML emitter output

**Key Structures:**
```rust
pub struct YamlPreprocessor<L: ImportLoader> {
    // Handles two-phase preprocessing
}

struct VariableMetadata {
    pub source: VariableSource,
    pub defined_at: String,
}

struct ImportStack {
    current_imports: HashSet<String>,
    import_chain: Vec<String>,
}
```

**Internal Dependencies:**
- `crate::yaml::parsing::*` - YAML parsing
- `crate::yaml::resolution::*` - Tag resolution
- `crate::yaml::imports::*` - Import loading
- `crate::yaml::custom_resources::*` - Custom resource expansion
- `crate::yaml::detection::*` - YAML spec detection

**External Dependencies:**
- `serde_yaml` - YAML value handling
- `yaml_rust` - Lower-level YAML parsing
- `tokio` - Async runtime

---

### yaml/parsing/mod.rs (42 LOC)
**Purpose:** YAML parsing API and diagnostics  
**Public Functions:**
- `pub fn parse_yaml_from_file(source: &str, file_path: &str) -> Result<YamlAst>` - Parse YAML to AST
- `pub fn parse_yaml_ast_with_diagnostics(source: &str, uri: Url) -> ParseDiagnostics` - Parse with diagnostics

**Internal Modules:**
- `ast` - AST node definitions (540 LOC)
- `parser` - YAML parser implementation (2090 LOC)
- `error` - Parse errors and diagnostics (149 LOC)

**Test Modules:**
- `diagnostic_tests` (405 LOC)
- `test` (675 LOC)
- `position_error_tests` (253 LOC)
- `position_verification_tests` (116 LOC)
- `proptest` (482 LOC) - Property-based testing

---

### yaml/parsing/parser.rs (2090 LOC)
**Purpose:** Core YAML parser using tree-sitter-yaml  
**Key Structures:**
```rust
pub struct YamlParser {
    parser: tree_sitter::Parser,
    location_finder: Box<dyn LocationFinder>,
}

pub struct YamlAst {
    pub root: AstNode,
    pub uri: Url,
}
```

**Public Functions:**
- `pub fn parse(source: &str, uri: Url) -> Result<YamlAst>` - Parse YAML to AST
- `pub fn validate_with_diagnostics(source: &str, uri: Url) -> ParseDiagnostics` - Validate with diagnostics

**Private Functions:**
- `fn node_to_ast(node: &Node, source: &str, uri: &Url, parent_path: &PathTracker) -> Result<AstNode>`
- `fn extract_tag_name(text: &str) -> Option<String>`
- `fn validate_tag_syntax(tag_name: &str) -> Result<()>`

**External Dependencies:**
- `tree_sitter` - AST parsing
- `tree_sitter_yaml` - YAML language binding
- `url::Url` - URI handling
- `regex` - Pattern matching

---

### yaml/parsing/ast.rs (540 LOC)
**Purpose:** Abstract syntax tree node definitions  
**Key Structures:**
```rust
pub enum AstNode {
    Scalar(ScalarNode),
    Sequence(SequenceNode),
    Mapping(MappingNode),
}

pub struct ScalarNode {
    pub tag: Option<String>,
    pub value: String>,
    pub location: Position,
}

pub struct SequenceNode {
    pub items: Vec<AstNode>,
    pub location: Position,
}

pub struct MappingNode {
    pub pairs: Vec<(AstNode, AstNode)>,
    pub location: Position,
}
```

**Location Tracking:**
- `pub struct Position` - Line, column, byte offset

---

### yaml/resolution/mod.rs (15 LOC)
**Purpose:** Custom tag resolution module organization  
**Public Modules:**
- `context` (1129 LOC) - Resolution context and variable sources
- `resolver` (2604 LOC) - Main tag resolution engine

**Public Functions:**
- `pub use resolver::{resolve_ast, TagResolver, Resolver};`
- `pub use context::{TagContext, VariableSource};`

---

### yaml/resolution/resolver.rs (2604 LOC)
**Purpose:** Main tag resolution engine (processes all custom tags)  
**Key Structures:**
```rust
pub struct Resolver {
    // Resolves custom YAML tags
}

pub enum TagResolver {
    StandardTagResolver,
    SplitArgsResolver, // 28% faster variant
}
```

**Public Functions:**
- `pub async fn resolve_ast(ast: &AstNode, context: &TagContext) -> Result<Value>` - Main resolution function
- `pub async fn resolve_value(...) -> Result<Value>` - Resolve AST node to YAML value

**Supported Custom Tags:**
- `!$` - Include from environment
- `!cfn` - CloudFormation intrinsic functions (Ref, GetAtt, etc.)
- `!sub` - String substitution
- `!join` - List joining
- `!base64` - Base64 encoding
- `!importyaml` - YAML import
- `!importjson` - JSON import
- etc.

**Internal Dependencies:**
- `crate::yaml::resolution::context::*` - Tag context
- `crate::yaml::jmespath::*` - JMESPath queries
- `crate::debug::debug_log` - Logging

---

### yaml/resolution/context.rs (1129 LOC)
**Purpose:** Tag resolution context and variable sources  
**Key Structures:**
```rust
pub struct TagContext {
    pub env: EnvValues,
    pub current_location: String,
    pub source: Vec<CredentialSource>,
}

pub enum VariableSource {
    Param,
    Def,
    Import,
    Implicit,
}
```

**Variable Tracking:**
- Tracks where variables come from (params, defs, imports)
- Metadata about variable definitions

---

### yaml/imports/mod.rs (492 LOC)
**Purpose:** Import system with security model  
**Security Model:**
- Local templates: can import from any source
- Remote templates (S3/HTTP): cannot access local-only sources (file:, env:, git:, filehash:)
- Relative imports inherit parent type

**Key Traits and Structures:**
```rust
pub trait ImportLoader: Send + Sync {
    async fn load_import(&self, specifier: &str, parent_uri: &str, context: &ImportContext) -> Result<String>;
}

pub struct ImportRecord {
    pub name: String,
    pub value: Value,
    pub source: String,
}

pub struct EnvValues {
    pub defs: HashMap<String, Value>,
    pub imports: HashMap<String, Value>,
}
```

**Supported Import Types:**
- `file:` - Local filesystem
- `env:` - Environment variables
- `s3:` - S3 objects
- `http:`, `https:` - HTTP endpoints
- `cfn:` - CloudFormation stacks/exports
- `ssm:` - SSM parameters
- `ssm-path:` - SSM parameter paths
- `git:` - Git repository data
- `random:` - Random values
- `filehash:` - File hashing

**Import Loaders (submodule):**
- `cfn.rs` (1113 LOC) - CloudFormation stack/export imports
- `env.rs` (173 LOC) - Environment variable imports
- `file.rs` (306 LOC) - Local file imports
- `git.rs` (259 LOC) - Git data imports
- `http.rs` (196 LOC) - HTTP/HTTPS imports
- `s3.rs` (262 LOC) - S3 object imports
- `ssm.rs` (407 LOC) - SSM parameter imports
- `random.rs` (231 LOC) - Random value generation

---

### yaml/custom_resources/mod.rs (14 LOC)
**Purpose:** Custom resource template expansion  
**Key Structures:**
```rust
pub struct TemplateInfo {
    pub params: Vec<ParamDef>,
    pub raw_body: String,
    pub location: String,
}
```

**Submodules:**
- `expansion.rs` (454 LOC) - Template expansion and $params resolution
- `params.rs` (745 LOC) - Parameter definition parsing
- `ref_rewriting.rs` (421 LOC) - Reference rewriting in expanded templates

---

### yaml/custom_resources/expansion.rs (454 LOC)
**Purpose:** $params expansion in custom resource templates  
**Key Functions:**
- `pub async fn expand_template_with_params(...)` - Expand custom resource with parameters
- `pub fn resolve_param_values(...)` - Resolve parameter values from $imports

**Supported Parameter Types:**
- String, Number, Boolean
- List, Map (nested structures)
- With defaults and validation

---

### yaml/custom_resources/params.rs (745 LOC)
**Purpose:** Parse and validate parameter definitions  
**Key Structures:**
```rust
pub struct ParamDef {
    pub name: String,
    pub param_type: ParamType,
    pub default: Option<Value>,
    pub required: bool,
}

pub enum ParamType {
    String,
    Number,
    Boolean,
    List,
    Map,
}
```

---

### yaml/custom_resources/ref_rewriting.rs (421 LOC)
**Purpose:** Rewrite references in expanded templates  
**Key Functions:**
- `pub fn rewrite_refs_in_expanded_template(...)` - Update references after expansion
- Handles `!$` includes and reference resolution

---

### yaml/handlebars/mod.rs (14 LOC)
**Purpose:** Handlebars template interpolation  
**Public Functions:**
- `pub use engine::interpolate_handlebars_string;`

**Submodule:** `engine.rs` (93 LOC)

---

### yaml/handlebars/engine.rs (93 LOC)
**Purpose:** Handlebars interpolation engine  
**Public Functions:**
- `pub fn interpolate_handlebars_string(template: &str, env: &EnvValues) -> Result<String>` - Interpolate template string

**Helper Functions (via helpers/mod.rs):**
- String case helpers (camelCase, snake_case, PascalCase, etc.)
- String manipulation (trim, uppercase, lowercase, etc.)
- Encoding/decoding (base64, URI, JSON)
- Object access helpers
- Serialization helpers

---

### yaml/handlebars/helpers/ (submodules)
**Helpers organization:**
- `encoding.rs` (197 LOC) - base64, uri encoding
- `object_access.rs` (78 LOC) - Nested object access
- `serialization.rs` (63 LOC) - JSON/YAML serialization
- `string_case.rs` (196 LOC) - Case conversions
- `string_manip.rs` (239 LOC) - String operations

---

### yaml/errors/mod.rs (14 LOC)
**Purpose:** Error system organization  
**Submodules:**
- `ids.rs` (401 LOC) - Error ID enumerations and explanations
- `enhanced.rs` (758 LOC) - Enhanced error display
- `display.rs` (507 LOC) - Custom error formatting
- `wrapper.rs` (344 LOC) - Error wrapping utilities

---

### yaml/errors/ids.rs (401 LOC)
**Purpose:** Error ID enumeration and explanation  
**Key Structures:**
```rust
pub enum ErrorId {
    // Error IDs for various failures
    CircularImport,
    UnresolvedVariable,
    InvalidTag,
    // ... ~40+ error types
}

impl ErrorId {
    pub fn from_code(code: &str) -> Option<Self>
    pub fn explain(&self) -> String
}
```

---

### yaml/errors/enhanced.rs (758 LOC)
**Purpose:** Enhanced error display with context  
**Key Structures:**
```rust
pub struct ErrorInfo {
    pub code: String,
    pub message: String,
    pub location: Option<SourceLocation>,
    pub context: Option<String>,
    pub suggestion: Option<String>,
}
```

---

### yaml/errors/display.rs (507 LOC)
**Purpose:** Custom error formatting  
**Functions:**
- Format errors with source context
- Color-coded error display
- Line/column highlighting

---

### yaml/emitter.rs (635 LOC)
**Purpose:** Custom YAML output (iidy-js compatible)  
**Public Functions:**
- `pub fn emit_yaml(value: &yaml_rust::Yaml) -> String` - Custom YAML emitter
- Matches iidy-js quote and formatting behavior

**Key Predicates:**
- `fn is_plain_safe_string(s: &str) -> bool` - Determine quoting needs
- Implements js-yaml compatibility layer

---

### yaml/jmespath.rs (86 LOC)
**Purpose:** JMESPath query support  
**Public Functions:**
- `pub fn apply_jmespath_query(value: &Value, expression: &str) -> Result<Value>` - Apply JMESPath
- `pub fn yaml_to_json_value(yaml: &Value) -> Result<JsonValue>` - Convert YAML to JSON
- `pub fn json_to_yaml_value(json: &Value) -> Result<Value>` - Convert JSON to YAML

**External Dependencies:**
- `jmespath` crate - JMESPath compilation and evaluation

---

### yaml/location.rs (476 LOC)
**Purpose:** Location finding strategies for error reporting  
**Key Traits and Structures:**
```rust
pub trait LocationFinder: Send + Sync {
    fn find_tag_position_in_context(...) -> Option<Position>;
    fn find_position_of(&self, source: &str, text: &str) -> Option<Position>;
    fn offset_to_position(&self, source: &str, offset: usize) -> Position;
}

pub struct ManualLocationFinder;
pub struct TreeSitterLocationFinder;

pub struct Position {
    pub line: usize,
    pub column: usize,
    pub offset: usize,
}
```

---

### yaml/path_tracker.rs (139 LOC)
**Purpose:** Efficient AST path tracking  
**Key Structures:**
```rust
pub struct PathTracker {
    segments: SmallVec<[String; 8]>,
}

impl PathTracker {
    pub fn push(&mut self, segment: &str)
    pub fn pop(&mut self) -> Option<String>
    pub fn current_path(&self) -> String
    pub fn len(&self) -> usize
    pub fn is_empty(&self) -> bool
}
```

**Optimization:**
- Uses `SmallVec` with 8-element inline capacity
- Most YAML paths are <8 levels deep

---

### yaml/tree_sitter_location.rs (444 LOC)
**Purpose:** Tree-sitter based YAML position finding  
**Public Functions:**
- `pub fn create_yaml_parser() -> Result<Parser>` - Initialize tree-sitter parser
- `pub fn parse_yaml_source(parser: &mut Parser, source: &str) -> Result<Tree>` - Parse YAML
- `pub fn find_child_by_key(mapping: &Node, key: &str, source: &str) -> Option<Node>` - Find mapping child
- `pub fn find_yaml_node_by_path(root: &Node, path: &[&str], source: &str) -> Option<Node>` - Navigate to path

---

### yaml/detection.rs (318 LOC)
**Purpose:** YAML specification version detection  
**Public Structures:**
```rust
pub enum YamlSpecDetection {
    ExplicitV11,
    ExplicitV12,
    CloudFormation,
    Kubernetes,
    Unknown,
}
```

**Public Functions:**
- `pub fn detect_yaml_spec(input: &str) -> YamlSpecDetection`
- `pub fn is_cloudformation_template(input: &str) -> bool`
- `pub fn is_kubernetes_manifest(input: &str) -> bool`

---

## III. CloudFormation Subsystem

### cfn/mod.rs (758 LOC)
**Purpose:** CloudFormation operations orchestration  
**Macros (Very Important):**
```rust
pub macro await_and_render!($task, $output_manager)
pub macro run_command_handler!($impl_fn, $cli, $args)
pub macro run_command_handler_with_stack_args!($impl_fn, $cli, $args, $argsfile)
```

**Key Structures:**
```rust
pub struct CfnContext {
    pub cfn_client: Client,
    pub s3_client: S3Client,
    pub config: SdkConfig,
    pub aws_settings: AwsSettings,
    pub credential_sources: CredentialSourceStack,
    pub timing_provider: Arc<Mutex<SystemTimeProvider>>,
}

pub enum CfnOperation {
    CreateStack,
    UpdateStack,
    DeleteStack,
    DescribeStack,
    CreateOrUpdate,
    CreateChangeset,
    ExecuteChangeset,
    EstimateCost,
    ListStacks,
    WatchStack,
    GetStackTemplate,
    DescribeStackDrift,
    TemplateApprovalRequest,
    TemplateApprovalReview,
    ConvertStackToIidy,
    LintTemplate,
}
```

**Public Functions:**
- `pub async fn create_context_for_operation(opts: &NormalizedAwsOpts, op: CfnOperation) -> Result<CfnContext>`
- `pub fn is_read_only(&self) -> bool` (on CfnOperation)

**Submodules:** 36 CFN operation files

---

### cfn/stack_args.rs (766 LOC)
**Purpose:** Load and parse stack-args.yaml  
**Key Structures:**
```rust
pub struct StackArgs {
    pub template_file: String,
    pub stack_name: String,
    pub parameters: BTreeMap<String, String>,
    pub tags: BTreeMap<String, String>,
    pub profile: Option<String>,
    pub region: Option<String>,
    pub assume_role_arn: Option<String>,
    pub capabilities: Vec<String>,
    // ... more fields
}

pub struct TemplateSourceConfig {
    pub source: String,
    pub format: TemplateFormat,
}
```

**Public Functions:**
- `pub async fn load_stack_args(argsfile: &str, environment: &str) -> Result<(StackArgs, SdkConfig, CredentialSourceStack)>`
- `pub async fn merge_aws_settings(cli: &AwsSettings, stack_args: Option<&AwsSettings>) -> AwsSettings`

---

### cfn/stack_operations.rs (444 LOC)
**Purpose:** Core stack operation utilities  
**Key Functions:**
- `pub async fn poll_stack_status(...) -> Result<(StackStatus, StackEvent)>`
- `pub async fn get_stack_events(...) -> Result<Vec<AwsStackEvent>>`
- `pub fn filter_events_since(...) -> Vec<AwsStackEvent>`

---

### cfn/operations.rs (90 LOC)
**Purpose:** CloudFormation operation type enumeration  
**Public Enum:**
```rust
pub enum CfnOperation {
    CreateStack, UpdateStack, DeleteStack, DescribeStack,
    CreateOrUpdate, CreateChangeset, ExecuteChangeset,
    EstimateCost, ListStacks, WatchStack, GetStackTemplate,
    DescribeStackDrift, TemplateApprovalRequest, TemplateApprovalReview,
    ConvertStackToIidy, LintTemplate,
}

impl CfnOperation {
    pub fn parse(s: &str) -> Option<Self>
    pub fn as_str(&self) -> &'static str
    pub fn is_read_only(&self) -> bool
}
```

---

### cfn/is_terminal_status.rs (66 LOC)
**Purpose:** Terminal status detection  
**Public Functions:**
- `pub fn is_terminal_resource_status(status: &ResourceStatus) -> bool`
- `pub fn is_terminal_stack_status(status: &StackStatus) -> bool`

---

### cfn/error_handling.rs (19 LOC)
**Purpose:** Error handling utilities  
**Public Functions:**
- `pub async fn handle_aws_error<T>(result: Result<T>, output_manager: &mut DynamicOutputManager) -> Result<Option<T>>`

---

### cfn/request_builder.rs (744 LOC)
**Purpose:** CloudFormation API request construction  
**Key Structures:**
```rust
pub struct RequestBuilder {
    // Constructs CloudFormation API requests with validation
}
```

**Public Functions:**
- `pub fn add_parameter(...) -> Self` - Builder pattern for parameters
- `pub fn add_tag(...) -> Self` - Builder pattern for tags
- `pub fn build() -> CreateStackRequest` - Construct final request

---

### cfn/template_loader.rs (445 LOC)
**Purpose:** Load and process CloudFormation templates  
**Public Functions:**
- `pub async fn load_template(path: &str, environment: &str) -> Result<TemplateContent>`
- `pub async fn preprocess_template(content: &str, args_file: &str) -> Result<String>`

---

### cfn/create_stack.rs (159 LOC)
**Purpose:** CreateStack operation  
**Public Functions:**
- `pub async fn create_stack(cli: &Cli, args: &CreateStackArgs) -> Result<i32>`

---

### cfn/update_stack.rs (167 LOC)
**Purpose:** UpdateStack operation  
**Public Functions:**
- `pub async fn update_stack(cli: &Cli, args: &UpdateStackArgs) -> Result<i32>`

---

### cfn/create_or_update.rs (355 LOC)
**Purpose:** CreateOrUpdate operation (idempotent create/update)  
**Public Functions:**
- `pub async fn create_or_update(cli: &Cli, args: &UpdateStackArgs) -> Result<i32>`

---

### cfn/delete_stack.rs (226 LOC)
**Purpose:** DeleteStack operation  
**Public Functions:**
- `pub async fn delete_stack(cli: &Cli, args: &DeleteArgs) -> Result<i32>`

---

### cfn/describe_stack.rs (96 LOC)
**Purpose:** DescribeStack operation  
**Public Functions:**
- `pub async fn describe_stack(cli: &Cli, args: &DescribeArgs) -> Result<i32>`

---

### cfn/watch_stack.rs (444 LOC)
**Purpose:** WatchStack operation (continuous polling)  
**Public Functions:**
- `pub async fn watch_stack(cli: &Cli, args: &WatchArgs) -> Result<()>`

---

### cfn/list_stacks.rs (235 LOC)
**Purpose:** ListStacks operation  
**Public Functions:**
- `pub async fn list_stacks(cli: &Cli, args: &ListArgs) -> Result<i32>`

---

### cfn/create_changeset.rs (62 LOC)
**Purpose:** CreateChangeset operation  
**Public Functions:**
- `pub async fn create_changeset(cli: &Cli, args: &CreateChangeSetArgs) -> Result<()>`

---

### cfn/exec_changeset.rs (159 LOC)
**Purpose:** ExecuteChangeset operation  
**Public Functions:**
- `pub async fn exec_changeset(cli: &Cli, args: &ExecChangeSetArgs) -> Result<i32>`

---

### cfn/changeset_operations.rs (630 LOC)
**Purpose:** Changeset handling utilities  
**Key Structures:**
```rust
pub struct ChangesetSummary {
    pub status: ChangeSetStatus,
    pub changes: Vec<Change>,
    pub execution_status: ExecutionStatus,
}
```

**Public Functions:**
- `pub async fn create_changeset_request(...) -> Result<CreateChangeSetInput>`
- `pub async fn describe_changeset(...) -> Result<ChangesetSummary>`
- `pub async fn execute_changeset(...) -> Result<ExecutionStatus>`

---

### cfn/estimate_cost.rs (89 LOC)
**Purpose:** EstimateCost operation  
**Public Functions:**
- `pub async fn estimate_cost(cli: &Cli, args: &StackFileArgs) -> Result<i32>`

---

### cfn/lint_template.rs (44 LOC)
**Purpose:** LintTemplate operation  
**Public Functions:**
- `pub async fn lint_template(cli: &Cli, args: &LintTemplateArgs) -> Result<i32>`

---

### cfn/convert_stack_to_iidy.rs (827 LOC)
**Purpose:** ConvertStackToIidy operation (reverse engineering)  
**Public Functions:**
- `pub async fn convert_stack_to_iidy(cli: &Cli, args: &ConvertArgs) -> Result<i32>`
- Generates stack-args.yaml and cfn-template.yaml from live stack

---

### cfn/get_stack_template.rs (187 LOC)
**Purpose:** GetStackTemplate operation  
**Public Functions:**
- `pub async fn get_stack_template(cli: &Cli, args: &GetTemplateArgs) -> Result<i32>`

---

### cfn/get_import.rs (189 LOC)
**Purpose:** GetImport operation (retrieve $import values)  
**Public Functions:**
- `pub async fn get_import(cli: &Cli, args: &GetImportArgs) -> Result<i32>`

---

### cfn/init_stack_args.rs (199 LOC)
**Purpose:** InitStackArgs operation (scaffold new project)  
**Public Functions:**
- `pub fn init_stack_args(args: &InitStackArgs) -> Result<()>`

---

### cfn/template_approval_request.rs (132 LOC)
**Purpose:** TemplateApprovalRequest operation  
**Public Functions:**
- `pub async fn template_approval_request(cli: &Cli, args: &ApprovalRequestArgs) -> Result<i32>`

---

### cfn/template_approval_review.rs (255 LOC)
**Purpose:** TemplateApprovalReview operation  
**Public Functions:**
- `pub async fn template_approval_review(cli: &Cli, args: &ApprovalReviewArgs) -> Result<i32>`

---

### cfn/template_hash.rs (150 LOC)
**Purpose:** Template hashing for change detection  
**Public Functions:**
- `pub fn compute_template_hash(content: &str) -> String`
- `pub fn hash_equals(hash1: &str, hash2: &str) -> bool`

---

### cfn/template_validation.rs (35 LOC)
**Purpose:** Template validation helpers  
**Public Functions:**
- `pub fn validate_template_structure(template: &Value) -> Result<()>`

---

### cfn/get_stack_instances.rs (11 LOC)
**Purpose:** GetStackInstances operation (deprecated)  
**Public Functions:**
- `pub fn get_stack_instances(args: &GetStackInstancesArgs)`

---

### cfn/describe_stack_drift.rs (162 LOC)
**Purpose:** DescribeStackDrift operation  
**Public Functions:**
- `pub async fn describe_stack_drift(cli: &Cli, args: &DriftArgs) -> Result<()>`

---

### cfn/s3_utils.rs (18 LOC)
**Purpose:** S3 template upload utilities  
**Public Functions:**
- `pub async fn upload_template_to_s3(...) -> Result<String>`

---

### cfn/stack_change_type.rs (23 LOC)
**Purpose:** Stack change type enumeration  
**Public Enum:**
```rust
pub enum StackChangeType {
    Create,
    Update,
    Delete,
    Unknown,
}
```

---

### cfn/constants.rs (14 LOC)
**Purpose:** CloudFormation operation constants  
**Constants:**
```rust
pub const DEFAULT_POLL_INTERVAL_SECS: u64 = 2;
pub const DEFAULT_POLL_TIMEOUT_SECS: u64 = 3600;
pub const DEFAULT_PREVIOUS_EVENTS_COUNT: usize = 10;
pub const MAX_CHANGESET_CREATION_TIMEOUT_SECS: u64 = 300;
pub const CHANGESET_POLL_INTERVAL_SECS: u64 = 2;
```

---

## IV. AWS Subsystem

### aws/mod.rs (166 LOC)
**Purpose:** AWS SDK configuration and credential management  
**Key Structures:**
```rust
pub struct UserFriendlyAwsError {
    pub message: String,
    pub exit_code: i32,
}

pub struct AwsSettings {
    pub profile: Option<String>,
    pub region: Option<String>,
    pub assume_role_arn: Option<String>,
}
```

**Public Functions:**
- `pub fn format_aws_error(error: &anyhow::Error) -> String` - User-friendly error formatting
- `pub fn display_and_return_user_friendly_error(...) -> UserFriendlyAwsError`
- `pub async fn config_from_normalized_opts(opts: &NormalizedAwsOpts) -> Result<(SdkConfig, CredentialSourceStack)>`
- `pub async fn config_from_merged_settings(settings: &AwsSettings, ctx: &CredentialDetectionContext) -> Result<(SdkConfig, CredentialSourceStack)>`

**Submodules:**
- `client_req_token` (292 LOC) - Idempotency token management
- `credential_source` (713 LOC) - Credential detection and reporting
- `timing` (196 LOC) - Reliable time providers for retries

---

### aws/client_req_token.rs (292 LOC)
**Purpose:** CloudFormation client request token management  
**Key Structures:**
```rust
pub struct TokenInfo {
    pub value: String,
    pub source: TokenSource,
    pub operation_id: String,
}

pub enum TokenSource {
    UserProvided,
    AutoGenerated,
}
```

**Public Functions:**
- `pub fn user_provided(token: String, op_id: String) -> TokenInfo`
- `pub fn auto_generated(token: String, op_id: String) -> TokenInfo`

---

### aws/credential_source.rs (713 LOC)
**Purpose:** Detect and report credential sources  
**Key Structures:**
```rust
pub struct CredentialSourceStack {
    pub sources: Vec<CredentialSource>,
}

pub enum CredentialSource {
    Profile(ProfileSource),
    EnvVar(EnvVarProvider),
    AssumeRole(AssumeRoleSource),
}

pub struct CredentialDetectionContext {
    pub cli_profile: Option<String>,
    pub stack_args_profile: Option<String>,
    pub cli_assume_role_arn: Option<String>,
    pub stack_args_assume_role_arn: Option<String>,
}
```

**Public Functions:**
- `pub fn detect_credential_sources(ctx: &CredentialDetectionContext, sys_env: &SystemEnv) -> CredentialSourceStack`
- Reports where credentials ultimately came from (profile, env var, assume role, etc.)

---

### aws/timing.rs (196 LOC)
**Purpose:** Reliable time providers for AWS operations  
**Key Traits:**
```rust
pub trait TimeProvider: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

pub struct SystemTimeProvider {
    // Uses system clock with NTP synchronization detection
}

pub struct ReliableTimeProvider {
    // Detects clock skew and adjusts
}
```

---

## V. Parameters Subsystem

### params/mod.rs (524 LOC)
**Purpose:** AWS SSM Parameter Store operations  
**Key Structures:**
```rust
pub struct ParamOutput {
    pub name: String,
    pub value: String,
    pub version: i32,
    pub type_: String,
    pub arn: String,
}

pub struct ParamHistoryOutput {
    pub name: String,
    pub history: Vec<ParamVersion>,
}
```

**Public Functions:**
- `pub async fn create_ssm_client(opts: &NormalizedAwsOpts) -> Result<(SsmClient, SdkConfig)>`
- `pub async fn create_kms_client(config: &SdkConfig) -> KmsClient`
- `pub async fn get_kms_alias_for_parameter(kms: &KmsClient, param_path: &str) -> Result<Option<String>>`
- `pub async fn maybe_fetch_param(ssm: &SsmClient, name: &str, with_decryption: bool) -> Result<Option<Parameter>>`
- `pub async fn get_param_tags(ssm: &SsmClient, name: &str) -> Result<BTreeMap<String, String>>`
- `pub async fn set_param_tags(ssm: &SsmClient, name: &str, tags: Vec<Tag>) -> Result<()>`
- `pub fn format_output(format: &str, value: &impl Serialize) -> Result<String>`

**Constants:**
```rust
const MESSAGE_TAG: &str = "iidy:message";
```

**Submodules:**
- `get.rs` (30 LOC) - GetParameter operation
- `get_by_path.rs` (60 LOC) - GetParametersByPath operation
- `get_history.rs` (113 LOC) - Parameter history retrieval
- `set.rs` (54 LOC) - PutParameter operation
- `review.rs` (92 LOC) - Review pending parameter changes

---

### params/get.rs (30 LOC)
**Purpose:** GetParameter operation  
**Public Functions:**
- `pub async fn get_param(cli: &Cli, args: &ParamGetArgs) -> Result<i32>`

---

### params/get_by_path.rs (60 LOC)
**Purpose:** GetParametersByPath operation  
**Public Functions:**
- `pub async fn get_by_path(cli: &Cli, args: &ParamGetByPathArgs) -> Result<i32>`

---

### params/get_history.rs (113 LOC)
**Purpose:** Parameter version history retrieval  
**Public Functions:**
- `pub async fn get_history(cli: &Cli, args: &ParamGetArgs) -> Result<i32>`

---

### params/set.rs (54 LOC)
**Purpose:** PutParameter operation with tagging support  
**Public Functions:**
- `pub async fn set_param(cli: &Cli, args: &ParamSetArgs) -> Result<i32>`

---

### params/review.rs (92 LOC)
**Purpose:** Review pending parameter changes  
**Public Functions:**
- `pub async fn review_param(cli: &Cli, args: &ParamPathArg) -> Result<i32>`

---

## VI. Output Subsystem

### output/mod.rs (27 LOC)
**Purpose:** Output system module organization  
**Public Exports:**
- `pub mod aws_conversion;`
- `pub mod color;`
- `pub mod data;`
- `pub mod fixtures;`
- `pub mod manager;`
- `pub mod renderer;`
- `pub mod renderers;`
- `pub mod spinner;`
- `pub mod terminal;`
- `pub mod theme;`

---

### output/manager.rs (175 LOC)
**Purpose:** Output manager (router to multiple renderers)  
**Key Structures:**
```rust
pub struct OutputOptions {
    pub color: ColorChoice,
    pub theme: Theme,
    pub fixture_set: Option<String>,
}

pub struct DynamicOutputManager {
    // Routes to appropriate renderer based on OutputMode
}
```

**Public Functions:**
- `pub async fn new(mode: OutputMode, options: OutputOptions) -> Result<Self>`
- `pub async fn render(&mut self, data: OutputData) -> Result<()>`

---

### output/renderer.rs (60 LOC)
**Purpose:** Output renderer trait  
**Public Trait:**
```rust
pub trait OutputRenderer: Send + Sync {
    async fn render(&mut self, data: OutputData) -> Result<()>;
    fn supports_interactive(&self) -> bool;
}

pub enum OutputMode {
    Interactive,
    Plain,
    Json,
    Fixtures,
}

impl OutputMode {
    pub fn default_for_environment() -> Self
}
```

---

### output/renderers/mod.rs (7 LOC)
**Purpose:** Output renderers organization  
**Renderers:**
- `interactive.rs` (2438 LOC) - Interactive terminal UI (iidy-js compatible)
- `json.rs` (527 LOC) - JSON output

---

### output/renderers/interactive.rs (2438 LOC)
**Purpose:** Interactive terminal renderer (primary iidy-js compatible output)  
**Key Structures:**
```rust
pub struct InteractiveOptions {
    pub color: ColorContext,
    pub theme: ColorTheme,
}

pub struct InteractiveRenderer {
    options: InteractiveOptions,
    fixture_loader: Option<FixtureLoader>,
}
```

**Public Functions:**
- `pub async fn render(&mut self, data: OutputData) -> Result<()>`

**Constants:**
```rust
pub const COLUMN2_START: usize = 25;
pub const MIN_STATUS_PADDING: usize = 17;
pub const MAX_PADDING: usize = 60;
pub const RESOURCE_TYPE_PADDING: usize = 40;
```

**Features:**
- Precise iidy-js output compatibility
- Color and theme support
- Resource status icons
- Event streaming
- Changeset visualization

---

### output/renderers/json.rs (527 LOC)
**Purpose:** JSON output renderer  
**Key Structures:**
```rust
pub struct JsonOptions {
    pub pretty: bool,
    pub fixture_set: Option<String>,
}

pub struct JsonRenderer {
    options: JsonOptions,
    fixture_loader: Option<FixtureLoader>,
}
```

---

### output/aws_conversion.rs (906 LOC)
**Purpose:** Convert AWS SDK types to output data structures  
**Key Functions:**
- `pub fn convert_token_info(token: &TimingTokenInfo) -> OutputTokenInfo`
- `pub async fn create_command_metadata(...) -> Result<CommandMetadata>`
- `pub async fn get_caller_identity(context: &CfnContext) -> Result<(String, String)>`
- `pub fn create_status_update(message: &str, level: StatusLevel) -> OutputData`
- `pub fn create_command_result(...) -> OutputData`
- `pub fn create_final_command_summary(success: bool, elapsed_seconds: i64) -> OutputData`
- `pub fn progress_message(msg: &str) -> OutputData`
- `pub fn success_message(msg: &str) -> OutputData`
- `pub fn warning_message(msg: &str) -> OutputData`
- `pub fn error_message(msg: &str) -> OutputData`
- `pub fn convert_stack_to_list_entry(stack: &Stack) -> StackListEntry`
- `pub fn convert_stacks_to_list_display(stacks: Vec<Stack>, show_tags: bool) -> OutputData`
- `pub fn convert_stack_to_definition(stack: &Stack, show_times: bool) -> OutputData`
- `pub fn convert_aws_stack_event(aws_event: &AwsStackEvent) -> StackEvent`
- `pub fn convert_stack_events_to_display(events: Vec<AwsStackEvent>, title: &str) -> OutputData`
- `pub fn convert_stack_events_to_display_with_max(...) -> OutputData`
- `pub fn convert_stack_resource(aws_resource: &StackResource) -> StackResourceInfo`
- `pub fn convert_stack_resources(aws_resources: Vec<StackResource>) -> Vec<StackResourceInfo>`
- `pub fn convert_stack_output(aws_output: &Output) -> StackOutputInfo`
- `pub fn convert_stack_outputs(aws_outputs: Vec<Output>) -> Vec<StackOutputInfo>`
- `pub fn create_stack_export(...) -> StackExportInfo`
- `pub fn convert_outputs_to_exports(outputs: Vec<Output>) -> Vec<StackExportInfo>`
- `pub async fn convert_aws_error_to_error_info(error: &anyhow::Error, context: Option<(&CfnContext, &Cli)>) -> ErrorInfo`

---

### output/data.rs (546 LOC)
**Purpose:** Output data type definitions  
**Key Structures:**
```rust
pub enum OutputData {
    CommandMetadata(CommandMetadata),
    StackDefinition(StackDefinition),
    StatusUpdate(StatusUpdate),
    StackEventsDisplay(StackEventsDisplay),
    CommandResult(CommandResult),
    StackListDisplay(StackListDisplay),
    ChangeSetCreationResult(ChangeSetCreationResult),
    Error(ErrorInfo),
}

pub struct CommandMetadata {
    pub operation: String,
    pub account_id: String,
    pub region: String,
    pub user: String,
    pub args: HashMap<String, String>,
    pub token_info: TokenInfo,
    pub timestamp: String,
}

pub struct StackDefinition {
    pub stack_name: String,
    pub status: StackStatusInfo,
    pub resources: Vec<StackResourceInfo>,
    pub outputs: Vec<StackOutputInfo>,
    pub exports: Vec<StackExportInfo>,
}

pub struct StackEvent {
    pub resource_id: String,
    pub resource_status: String,
    pub timestamp: String,
    pub reason: Option<String>,
    pub resource_type: String,
}

pub struct StackEventsDisplay {
    pub events: Vec<StackEvent>,
    pub total_count: usize,
    pub title: String,
    pub truncation: Option<TruncationInfo>,
}

pub struct ErrorInfo {
    pub code: String,
    pub message: String,
    pub location: Option<SourceLocation>,
    pub context: Option<String>,
    pub suggestion: Option<String>,
}
```

---

### output/color.rs (325 LOC)
**Purpose:** ANSI color and styling  
**Key Structures:**
```rust
pub struct ColorContext {
    pub color_mode: ColorChoice,
    pub theme: Theme,
}

pub enum ColorChoice {
    Auto, Always, Never,
}

pub enum Theme {
    Auto, Light, Dark, HighContrast,
}
```

**Public Functions:**
- `pub fn init_global(color: ColorChoice, theme: Theme)` - Initialize global color context
- `pub fn get_global() -> ColorContext` - Get global color context
- `pub fn colorize(text: &str, color: Color) -> String`

---

### output/terminal.rs (267 LOC)
**Purpose:** Terminal capabilities detection  
**Key Structures:**
```rust
pub struct TerminalCapabilities {
    pub supports_unicode: bool,
    pub supports_256_colors: bool,
    pub is_interactive: bool,
}

pub struct ColorTheme {
    pub success: Color,
    pub error: Color,
    pub warning: Color,
    pub info: Color,
    pub muted: Color,
}
```

---

### output/theme.rs (181 LOC)
**Purpose:** Color theme definitions  
**Themes:**
- Light theme
- Dark theme
- High contrast theme
- Auto-detect theme

---

### output/status.rs (271 LOC)
**Purpose:** Stack status categorization and display  
**Constants:**
```rust
pub const IN_PROGRESS: &[&str] = &[ /* statuses */ ];
pub const COMPLETE: &[&str] = &[ /* statuses */ ];
pub const FAILED: &[&str] = &[ /* statuses */ ];
pub const SKIPPED: &[&str] = &[ /* statuses */ ];
pub const TERMINAL: &[&str] = &[ /* all terminal statuses */ ];
```

**Public Functions:**
- `pub enum StatusCategory { InProgress, Complete, Failed, Skipped, Unknown }`
- `pub fn categorize_status(status: &str) -> StatusCategory`
- `pub fn is_in_progress(status: &str) -> bool`
- `pub fn is_complete(status: &str) -> bool`
- `pub fn is_failed(status: &str) -> bool`
- `pub fn is_skipped(status: &str) -> bool`
- `pub fn is_terminal(status: &str) -> bool`
- `pub fn status_icon(status: &str) -> &'static str`
- `pub fn status_description(status: &str) -> &'static str`

---

### output/spinner.rs (81 LOC)
**Purpose:** Progress spinner for long-running operations  
**Key Structures:**
```rust
pub enum SpinnerStyle {
    Dots,
    Line,
    Arrow,
}

pub struct Spinner {
    style: SpinnerStyle,
    message: String,
}

impl Spinner {
    pub fn new(style: SpinnerStyle, message: &str) -> Self
    pub async fn run_until_done<F>(&self, future: F) -> Result<T>
}
```

---

### output/fixtures/mod.rs (429 LOC)
**Purpose:** Test fixtures for output validation  
**Key Structures:**
```rust
pub struct TestFixture {
    pub name: String,
    pub input_data: FixtureTokens,
    pub expected_output: ExpectedOutput,
}

pub struct FixtureLoader {
    // Loads fixture YAML files
}

impl FixtureLoader {
    pub fn new() -> Self
    pub fn load_fixture(&self, name: &str) -> Result<TestFixture>
}
```

---

### output/test_data.rs (380 LOC)
**Purpose:** Sample data for output testing  
**Public Functions:**
- `pub fn sample_command_metadata() -> CommandMetadata`
- `pub fn sample_stack_definition() -> StackDefinition`
- `pub fn sample_stack_events() -> StackEventsDisplay`
- `pub fn sample_stack_contents() -> StackContents`
- `pub fn sample_status_update() -> StatusUpdate`
- `pub fn sample_command_result(success: bool) -> CommandResult`
- `pub fn sample_stack_list() -> StackListDisplay`
- `pub fn sample_changeset_result() -> ChangeSetCreationResult`
- `pub fn sample_error_info() -> ErrorInfo`
- `pub fn all_sample_output_data() -> Vec<OutputData>`

---

## VII. Module Dependency Graph

```
main.rs (entry point)
  ├─ cli.rs (command parsing)
  │   └─ clap crate
  │
  ├─ cfn/* (CloudFormation operations)
  │   ├─ cfn/mod.rs (macros, context creation)
  │   ├─ cfn/stack_args.rs (load YAML)
  │   ├─ cfn/request_builder.rs (API construction)
  │   ├─ cfn/template_loader.rs
  │   │   └─ yaml/engine.rs (preprocess)
  │   ├─ cfn/operations.rs (enum)
  │   ├─ cfn/changeset_operations.rs
  │   ├─ cfn/stack_operations.rs
  │   └─ (20+ operation modules)
  │       └─ output/manager.rs (rendering)
  │
  ├─ yaml/* (YAML preprocessing)
  │   ├─ yaml/mod.rs (exports)
  │   ├─ yaml/engine.rs (two-phase pipeline)
  │   │   ├─ yaml/parsing/parser.rs (AST)
  │   │   ├─ yaml/imports/mod.rs (loaders)
  │   │   │   ├─ yaml/imports/loaders/file.rs
  │   │   │   ├─ yaml/imports/loaders/s3.rs
  │   │   │   ├─ yaml/imports/loaders/http.rs
  │   │   │   ├─ yaml/imports/loaders/cfn.rs
  │   │   │   ├─ yaml/imports/loaders/ssm.rs
  │   │   │   ├─ yaml/imports/loaders/env.rs
  │   │   │   ├─ yaml/imports/loaders/git.rs
  │   │   │   └─ yaml/imports/loaders/random.rs
  │   │   ├─ yaml/custom_resources/params.rs (expand)
  │   │   ├─ yaml/custom_resources/expansion.rs
  │   │   ├─ yaml/custom_resources/ref_rewriting.rs
  │   │   ├─ yaml/resolution/resolver.rs (tags)
  │   │   │   └─ yaml/resolution/context.rs
  │   │   ├─ yaml/handlebars/engine.rs (interpolate)
  │   │   └─ yaml/emitter.rs (output)
  │   ├─ yaml/detection.rs (YAML version)
  │   ├─ yaml/errors/* (error handling)
  │   └─ yaml/jmespath.rs (queries)
  │
  ├─ aws/* (AWS SDK wrappers)
  │   ├─ aws/mod.rs (config loading)
  │   ├─ aws/credential_source.rs (detect credentials)
  │   ├─ aws/client_req_token.rs (idempotency)
  │   └─ aws/timing.rs (clock sync)
  │
  ├─ params/* (SSM Parameter Store)
  │   ├─ params/mod.rs (SSM client)
  │   ├─ params/get.rs
  │   ├─ params/set.rs
  │   ├─ params/get_by_path.rs
  │   ├─ params/get_history.rs
  │   └─ params/review.rs
  │
  ├─ output/* (output rendering)
  │   ├─ output/mod.rs (exports)
  │   ├─ output/manager.rs (router)
  │   ├─ output/renderer.rs (trait)
  │   ├─ output/renderers/interactive.rs (iidy-js compatible)
  │   ├─ output/renderers/json.rs
  │   ├─ output/aws_conversion.rs (AWS->output data)
  │   ├─ output/data.rs (type definitions)
  │   ├─ output/color.rs (ANSI colors)
  │   ├─ output/terminal.rs (capabilities)
  │   ├─ output/status.rs (status helpers)
  │   ├─ output/theme.rs (color themes)
  │   ├─ output/spinner.rs (progress)
  │   ├─ output/fixtures/mod.rs (test fixtures)
  │   └─ output/test_data.rs (sample data)
  │
  ├─ explain.rs (error explanations)
  │   └─ yaml/errors/ids.rs
  │
  ├─ render.rs (render command)
  │   └─ yaml/engine.rs
  │
  ├─ demo.rs (demo script execution)
  │   ├─ yaml/engine.rs (preprocess script)
  │   ├─ portable_pty (PTY management)
  │   └─ regex (masking)
  │
  └─ debug.rs (logging macro)

External Crates (Dependencies):
  ├─ aws-sdk-cloudformation (CloudFormation API)
  ├─ aws-sdk-s3 (S3 API)
  ├─ aws-sdk-ssm (SSM API)
  ├─ aws-sdk-kms (KMS API)
  ├─ aws-sdk-sts (STS API)
  ├─ aws-config (AWS SDK config)
  ├─ aws-credential-types (credential types)
  ├─ aws-types (AWS types)
  ├─ clap (CLI parsing)
  ├─ clap_complete (shell completion)
  ├─ serde / serde_yaml / serde_json (serialization)
  ├─ tokio (async runtime)
  ├─ yaml-rust (YAML parsing)
  ├─ tree-sitter / tree-sitter-yaml (precise parsing)
  ├─ jmespath (JMESPath queries)
  ├─ handlebars (template interpolation)
  ├─ regex (pattern matching)
  ├─ crossterm (terminal UI)
  ├─ portable_pty (PTY management)
  ├─ chrono (timestamps)
  ├─ uuid (unique IDs)
  ├─ anyhow (error handling)
  ├─ url (URI parsing)
  ├─ log / env_logger (logging)
  ├─ once_cell (lazy statics)
  ├─ smallvec (optimized vectors)
  └─ tempfile (temporary files)
```

---

## VIII. Key Architectural Patterns

### 1. Two-Phase YAML Preprocessing (yaml/engine.rs)
- **Phase 1:** Parse YAML, load $imports, build environment from $defs
- **Phase 2:** Resolve custom tags, interpolate handlebars, output final YAML

### 2. Macros for Command Handlers (cfn/mod.rs)
- `run_command_handler!` - Standard setup, error handling
- `run_command_handler_with_stack_args!` - Merge CLI + stack-args AWS config
- `await_and_render!` - Async task handling with error rendering

### 3. Output Manager Pattern (output/manager.rs)
- `DynamicOutputManager` routes to appropriate renderer
- Multiple renderers: Interactive (iidy-js compatible), JSON, Plain
- Fixture-based testing support

### 4. AST-Based Resolution (yaml/resolution/)
- Resolves to abstract syntax tree first
- Tag resolution on AST with context tracking
- Path tracking for precise error reporting

### 5. Credential Source Detection (aws/credential_source.rs)
- Detects where credentials came from (profile, env var, assume role)
- Reports to user via output system
- Merges CLI opts + stack-args AWS settings

### 6. Stack Args Preprocessing
- Loads stack-args.yaml with environment-based settings
- Merges with CLI options
- YAML processed with import/interpolation before parsing

---

## IX. Testing Infrastructure

**Test Modules:**
- `yaml/parsing/test.rs` (675 LOC) - Parser unit tests
- `yaml/parsing/diagnostic_tests.rs` (405 LOC) - Diagnostic tests
- `yaml/parsing/proptest.rs` (482 LOC) - Property-based testing
- `yaml/handlebars/tests.rs` (495 LOC) - Template interpolation tests
- `output/fixtures/mod.rs` (429 LOC) - Fixture-based output testing
- `output/test_data.rs` (380 LOC) - Sample data for testing
- Inline `#[cfg(test)]` modules in most source files

**Testing Strategy:**
- Unit tests for individual modules
- Integration tests via fixtures
- Property-based testing for parser robustness
- Inline tests close to implementation

---

## X. Summary Statistics

| Category | LOC | Files | Purpose |
|----------|-----|-------|---------|
| **CLI & Main** | 1,216 | 7 | Entry points, command parsing |
| **YAML System** | 7,950 | 36 | Preprocessing, parsing, resolution |
| **CloudFormation** | 4,660 | 36 | Stack operations, templates |
| **AWS SDK** | 1,367 | 4 | Config, credentials, timing |
| **Output System** | 3,962 | 12 | Rendering, data conversion, colors |
| **Parameters** | 524 | 6 | SSM parameter operations |
| **Demo/Explain** | 730 | 3 | Demo scripts, error explanations |
| **Total** | **~16,615** | **96** | Complete iidy-rs codebase |

---

## XI. Haskell Port Considerations

### High-Priority Modules to Port
1. **yaml/parsing/parser.rs** (2090 LOC) - Core YAML parser logic
2. **yaml/resolution/resolver.rs** (2604 LOC) - Tag resolution engine
3. **output/renderers/interactive.rs** (2438 LOC) - Output rendering
4. **cfn/stack_args.rs** (766 LOC) - Configuration loading
5. **yaml/engine.rs** (829 LOC) - Two-phase preprocessing

### External Dependencies Needing Equivalents
- **aws-sdk-rust** → AWS Haskell SDK (amazonka)
- **yaml-rust** → aeson (JSON/YAML parsing)
- **tree-sitter** → tree-sitter-hs or language-yaml
- **jmespath** → jmespath-hs
- **handlebars** → Haskell templating (Hastache/Heist)
- **clap** → optparse-applicative
- **tokio** → async/Haskell's IO

### Architecture Preservation
- Keep two-phase YAML preprocessing design
- Maintain AST-based resolution strategy
- Preserve output manager pattern for multiple renderers
- Keep credential source detection approach
- Implement similar module organization

---

