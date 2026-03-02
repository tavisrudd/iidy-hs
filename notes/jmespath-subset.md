# JMESPath Subset Documentation

iidy-hs implements a **subset** of the [JMESPath specification](https://jmespath.org/specification.html).
This is sufficient for all iidy template expressions but does not cover the full spec.

The Rust iidy uses the full [`jmespath` crate](https://crates.io/crates/jmespath)
which implements the complete specification. The Haskell port uses a custom ~370 LOC
parser/evaluator (`src/Iidy/Yaml/JMESPath.hs`) implementing only the features
actually used in iidy templates.

## Supported Features

| Feature                | Syntax Example          | JExpr Constructor     |
|------------------------|-------------------------|-----------------------|
| Field access           | `foo`, `foo.bar`        | `JField`, `JSubExpr`  |
| Array index            | `[0]`, `[-1]`           | `JIndex`              |
| Array wildcard         | `[*]`                   | `JProjection`         |
| Object wildcard        | `*`                     | `JWildcard`           |
| Flatten                | `[]`                    | `JFlatten`            |
| Filter expressions     | `[?active == true]`     | `JFilter`             |
| Multi-select list      | `[foo, bar]`            | `JMultiSelectList`    |
| Multi-select hash      | `{k1: foo, k2: bar}`   | `JMultiSelectHash`    |
| Pipe expressions       | `a \| b`                | `JPipe`               |
| Literal expressions    | `` `"hello"` ``         | `JLiteral`            |
| Raw string literals    | `'hello'`               | `JLiteral`            |
| Identity (current)     | `@`                     | `JIdentity`           |
| Comparison operators   | `==`, `!=`, `<`, `<=`, `>`, `>=` | `JComparison` |
| Not operator           | `!expr`                 | `JNot`                |

## Unsupported Features

### Slice Expressions

JMESPath slice syntax (`[start:stop:step]`) is not implemented.

Examples that will produce an error:
- `[0:5]` -- first 5 elements
- `[::2]` -- every other element
- `[::-1]` -- reverse an array

### Built-in Functions

None of the 26 JMESPath built-in functions are implemented.
Calling any function will produce an error.

| Function       | Description                    |
|----------------|--------------------------------|
| `abs()`        | Absolute value                 |
| `avg()`        | Average of array elements      |
| `ceil()`       | Round up to integer            |
| `contains()`   | Substring/element search       |
| `ends_with()`  | String suffix check            |
| `floor()`      | Round down to integer          |
| `join()`       | Concatenate array strings      |
| `keys()`       | Extract object keys            |
| `length()`     | Count elements/characters      |
| `map()`        | Apply expression to array      |
| `max()`        | Find maximum value             |
| `max_by()`     | Find max using expression key  |
| `merge()`      | Combine objects                |
| `min()`        | Find minimum value             |
| `min_by()`     | Find min using expression key  |
| `not_null()`   | Return first non-null argument |
| `reverse()`    | Reverse arrays/strings         |
| `sort()`       | Sort arrays                    |
| `sort_by()`    | Sort using expression key      |
| `starts_with()`| String prefix check            |
| `sum()`        | Total array values             |
| `to_array()`   | Convert to array type          |
| `to_number()`  | Convert to number type         |
| `to_string()`  | Convert to string type         |
| `type()`       | Return value type name         |
| `values()`     | Extract object values          |

### Logical Operators (`&&`, `||`)

The `&&` and `||` binary logical operators are not implemented.
The unary `!` (not) operator IS supported.

### Parenthesized Expressions

Grouping with parentheses `(expr)` for precedence control is not implemented.

### Quoted Identifiers

Quoted identifier syntax (`"foo bar"` to access keys with special characters)
is not implemented. Only unquoted identifiers matching `[a-zA-Z0-9_]+` are
supported.

## Why a Subset?

iidy templates use JMESPath for simple data access patterns: field lookups,
array indexing, projections, and filtering. The full function library and
advanced features like slicing are not used in practice. The custom
implementation keeps the dependency footprint small (~370 LOC, zero extra
dependencies) while covering all real-world usage.
