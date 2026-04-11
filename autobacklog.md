# Autobacklog: Freeze Unfrozen Constants

## Problem
~142 Array and Hash constants across Rails lib/ directories are not frozen.
When these constants are accessed from non-main Ractors, Ruby raises
`Ractor::IsolationError: can not access non-shareable objects in constant`.

## How to Fix
For each constant:

1. Read the file around the constant definition
2. Check if the constant is populated AFTER definition (e.g., `LOOKUP = {}`
   followed by `LOOKUP[key] = val` later in the file). If so:
   - Find where population finishes and add `.freeze` after that
   - Or if it's populated dynamically at require time, the freeze should
     go at the end of the block
3. If the constant is a static literal (defined with all values inline),
   just add `.freeze` at the end of the definition
4. For nested structures (Hash of Arrays, etc.), use `.freeze` on the outer
   structure. Inner strings are frozen by `frozen_string_literal: true`.
   Inner Arrays/Hashes need their own `.freeze` if they're mutable.
5. For constants that contain Procs or complex objects that can't be frozen,
   skip them.

### Patterns

```ruby
# Simple array — add .freeze
METHODS = [:get, :post, :put]
METHODS = [:get, :post, :put].freeze

# Simple hash — add .freeze
DEFAULTS = { format: :html }
DEFAULTS = { format: :html }.freeze

# Multi-line array — add .freeze after closing bracket
MODULES = [
  ActionController::Rendering,
  ActionController::Redirecting,
]
MODULES = [
  ActionController::Rendering,
  ActionController::Redirecting,
].freeze

# Hash populated after definition — freeze at end of population
LOOKUP = {}
LOOKUP["text/html"] = :html
LOOKUP["application/json"] = :json
# Add: LOOKUP.freeze

# Constant with nested mutable values — freeze inner too
MAPPING = {
  default: [:get, :post],
  api: [:get],
}
MAPPING = {
  default: [:get, :post].freeze,
  api: [:get].freeze,
}.freeze
```

## Verification
After fixing each file, run `bin/ractor-test` from the project root to verify
all 66 tests still pass. The test suite boots the full Rails app in production
mode and makes 66 HTTP requests through Ractors.

For individual component verification, check that the file has no syntax errors:
`ruby -c <file>`

## Constraints
- Do NOT change public APIs
- Do NOT freeze constants that are intentionally mutable (populated at runtime)
- Do NOT freeze constants that contain Procs, Mutexes, or IO objects
- All 66 existing ractor-tests must continue passing
- Batch multiple constants per file into a single commit

## Files in Scope
All `*/lib/**/*.rb` files in vendor/rails/ (excluding test/ directories).

## Notes
- Many files already have `# frozen_string_literal: true` so string values
  in constants are already frozen
- `VERSION::STRING` constants are computed from other constants — these are
  already frozen strings in frozen_string_literal files
- `Concurrent::Map.new` and `Hash.new { block }` are handled separately
  (not in this backlog)
- Some constants are populated dynamically during require (e.g.,
  `Mime::LOOKUP = {}` then `Mime::Type.register(...)`) — freeze after
  all registrations in `Application#freeze`
- Constants containing class/module references (like `MODULES = [...]` in
  controllers) are frozen arrays of already-shareable class objects
