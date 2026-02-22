# Error Examples

This directory contains focused examples of various error types to test and demonstrate the enhanced error reporting system.

## Error Categories

### YAML Syntax Errors (IY1001)
- `yaml-syntax-malformed-mapping.yaml` - Malformed block mapping with chained tags
- `yaml-syntax-unexpected-end.yaml` - Unexpected end of stream (missing quote)

### Tag Parsing Errors (IY4002)  
- `tag-map-uses-source.yaml` - !$map tag uses 'source' instead of 'items'
- `tag-map-uses-transform.yaml` - !$map tag uses 'transform' instead of 'template'
- `tag-missing-required-field.yaml` - Missing required 'template' field in !$map
- `multiple-occurrence-error-positioning.yaml` - Error positioning with multiple !$if tags (13th is missing 'test')

### Variable Errors (IY2001)
- `variable-not-found.yaml` - Handlebars variable not found in $defs
- `variable-include-not-found.yaml` - Include reference to non-existent property

### Unknown Tag Errors
- `unknown-tag-typo.yaml` - Typo in iidy preprocessing tag (!$mapp instead of !$map)

### CloudFormation Tag Validation Errors
- `cloudformation-null-value.yaml` - CloudFormation tag with null value
- `cloudformation-empty-arrays.yaml` - CloudFormation tags with empty arrays
- `cloudformation-wrong-element-count.yaml` - CloudFormation tags with incorrect number of elements

## Testing Enhanced Errors

Run with enhanced error reporting enabled:

```bash
cargo run --features enhanced-errors -- render example-templates/errors/[filename]
```

These examples will be used for snapshot testing to ensure error message quality and consistency.