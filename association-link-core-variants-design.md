# Static association links with Core-owned variants

## 1. Decision

Rails will introduce an internal `AssociationLink` abstraction.

Rails will not introduce association variants or a variant resolver.

Core will continue to own runtime key selection. Core will patch `AssociationReflection#association_link` for this selection.

After the Rails refactor, Core needs only two association integration changes:

- Preserve both declared shapes and compile their links.
- Override `association_link` to select one link by context.

Model query-key selection remains a separate Core patch.

This design depends on one Core invariant:

> The schema context stays stable for a complete request and each complete Active Record operation.

This invariant permits repeated link lookups during one operation. Each lookup returns the same link.

This approach is smaller than the association-route refactor. It does not provide general runtime association variance for Rails applications.

## 2. Goals

This work has these goals:

- Give Rails one internal representation for an association's physical keys.
- Give Core one narrow method to patch for adapter-specific association keys.
- Separate writable reference keys from query-only constraints.
- Preserve current Rails behavior.
- Preserve Core's existing `yugabyte_overrides:` declarations.
- Support `belongs_to`, `has_many`, and `has_one` in Core.
- Permit a later migration to association routes.

## 3. Non-goals

This work does not add these Rails features:

- A public `key_variants:` option.
- A Rails variant resolver.
- Dynamic target classes or scopes.
- Record-dependent selection.
- A guarantee for context changes during an operation.
- Dynamic HABTM keys.
- A complete association-route implementation.

Core will not support relations that move between schema contexts. The relation must execute in its creation context.

## 4. Rails foundation

### 4.1 `Key::Mapping`

`Key::Mapping` stores an ordered physical relationship between two keys.

```ruby
ActiveRecord::Key::Mapping.new(
  reference_key: :order_id,
  target_key: :id
)
```

The direction is always physical:

```text
record with the foreign key -> record that supplies the value
```

The mapping has these properties:

- It preserves column order.
- It requires equal key sizes.
- It is immutable and hashable.
- It supports scalar and composite keys.
- It supports different column names at each endpoint.

### 4.2 `AssociationLink`

`AssociationLink` stores the mappings for one physical association relationship.

```ruby
ActiveRecord::AssociationLink.new(
  reference: reference_mapping,
  constraints: constraint_mapping
)
```

It exposes three mappings:

| Mapping | Purpose |
|---|---|
| `reference` | The writable foreign-key relationship. |
| `constraints` | Additional query-only relationships. |
| `match` | The constraints followed by the reference. |

Rails initially creates links with empty constraints. Rails does not add association `query_constraints:` behavior in this change.

### 4.3 Reflection integration

Each association reflection builds one static link.

```ruby
reflection.association_link(associated_class = nil)
```

The associated class is required for a polymorphic `belongs_to` link.

Existing reflection methods project keys from the static link:

- `foreign_key` reads the link's reference key.
- `active_record_primary_key` reads the target key for owner-side associations.
- `association_primary_key` reads the target key for `belongs_to` associations.

The association statement-cache identity includes the link. This change has no effect while each reflection has one static link.

### 4.4 Rails consumer contract

Rails must migrate all association consumers to the link.

```text
queries -> association_link.match
writes  -> association_link.reference
```

Query consumers include these paths:

- Lazy loading and association scopes.
- Preloading, eager loading, and joins.
- Association predicates and inverse matching.
- Counter, touch, and asynchronous destruction queries.
- Through-association queries.

Write consumers include these paths:

- Assignment and replacement.
- Build and create operations.
- Autosave.
- Stale-state checks.
- Nullification.
- Required `belongs_to` validation.
- Through-association construction.

Rails links have empty constraints unless an internal caller supplies constraints. This preserves current Rails behavior.

This consumer migration is part of the upstream refactor. Core does not patch individual query or write consumers.

### 4.5 Rails tests

Rails tests must confirm these properties:

- Mapping order and endpoint correspondence.
- Mapping equality and hash behavior.
- Unequal key sizes raise an error.
- Link equality and hash behavior.
- `match` combines constraints before the reference.
- Writes copy only the reference mapping.
- `belongs_to`, `has_many`, and `has_one` use the correct physical direction.
- Composite and differently named keys keep current behavior.
- Polymorphic links use the supplied associated class.
- Existing association behavior does not change.
- Every query consumer uses `match`.
- Every write consumer uses `reference`.

## 5. Core selection model

Core uses `current_schema_context_key` as the selection key.

The initial values remain:

```text
default
yugabyte
```

Core compiles one `AssociationLink` for each declared shape. A reflection stores the links by context key.

Core prepends `AssociationReflection#association_link`:

```ruby
def association_link(associated_class = nil)
  links_for(associated_class).fetch(current_schema_context_key) do
    links_for(associated_class).fetch("default")
  end
end
```

The exact cache must include the associated class for polymorphic associations.

Core owns all fallback rules. Rails does not know the Core context names.

## 6. Core patch inventory

Core currently maintains these relevant patches and concerns.

| Core file | Current responsibility | Change under this design |
|---|---|---|
| `components/platform/essentials/lib/patches/active_record/schema_context_proxy.rb` | Supplies `current_schema_context_key`. | Keep it as the link selector. |
| `components/platform/essentials/lib/podding/database/schema_context_proxy.rb` | Stores values by adapter context. | Reuse its cache pattern for links. |
| `components/platform/essentials/lib/podding/database/concerns/sharded_table.rb` | Selects and caches the current context. | Keep the stable request context. |
| `components/platform/essentials/app/models/concerns/yugabyte_associations.rb` | Selects `yugabyte_overrides:` during boot. | Preserve both shapes and compile both links. |
| `belongs_to_with_query_constraints.rb` | Builds composite query keys and patches writes. | Remove it after Rails consumers use `match` and `reference`. |
| `has_many_with_query_constraints.rb` | Builds composite query keys and patches nullification. | Remove it after Rails consumers use `match` and `reference`. |
| `has_one_with_query_constraints.rb` | Builds composite query keys and patches nullification. | Remove it after Rails consumers use `match` and `reference`. |
| `association_reflection_writable_foreign_key.rb` | Separates writable columns from query columns. | Remove it because `association_link.reference` owns this role. |
| The model query-constraint patch | Selects model persistence keys by context. | Keep this work separate from association links. |

## 7. Changes to Core declarations

Core keeps the current declaration format during the first migration.

```ruby
belongs_to :order,
  primary_key: :id,
  yugabyte_overrides: {
    query_constraints: [:order_id, :shop_id],
    primary_key: [:id, :shop_id],
    foreign_key: :order_id
  }
```

Core converts each shape into a link.

The default link uses the ordinary Rails association options.

The Yugabyte link separates the existing declaration into two mappings:

```text
reference:
  line_items.order_id -> orders.id

constraints:
  line_items.shop_id -> orders.shop_id
```

Core must not pass the complete query key to Rails as the writable foreign key after this conversion.

The existing declarations can remain unchanged. Core can rename them in a separate project.

## 8. Core patches required for variant behavior

### 8.1 Declaration capture

`YugabyteAssociations` currently removes the unused shape during application boot.

Core must retain both shapes when runtime selection is enabled. It must compile both shapes into immutable links.

A new rollout flag must protect this behavior. The disabled path must keep current behavior.

### 8.2 Reflection link selection

Core must prepend `AssociationReflection#association_link`.

The override must:

- Read `current_schema_context_key`.
- Select a link from a per-context cache.
- Include the associated class in polymorphic cache keys.
- Fall back to the default link when an association has no Yugabyte override.
- Return the same immutable object for repeated lookups.

Core should not separately override `foreign_key`, `active_record_primary_key`, or `association_primary_key` when the Rails projections are sufficient.

### 8.3 Remove association consumer patches

Rails handles query and write separation before Core enables runtime link selection.

Core can then remove these concerns and patches:

- `belongs_to_with_query_constraints.rb`.
- `has_many_with_query_constraints.rb`.
- `has_one_with_query_constraints.rb`.
- `association_reflection_writable_foreign_key.rb`.
- The anonymous association subclasses created by those concerns.
- The custom narrow-key `belongs_to` validator.

Rails uses `link.match` for every association query. Rails uses `link.reference` for every association write.

Core does not patch lazy loading, preloading, joins, autosave, nullification, counters, touch operations, or requiredness.

### 8.4 Model query keys

Association links do not select model persistence keys.

Core must keep its model-level query-constraint patch. That patch selects model query keys through `current_schema_context_key`.

This patch controls updates, deletes, reloads, locks, and model statement caches.

### 8.5 Link validation

Rails caches `AssociationReflection#check_validity!` with one `@validated` value.

Core must check:

- Equal reference endpoint sizes.
- Equal constraint endpoint sizes.
- No query-only constraint duplicates a writable reference column.
- Every declared column exists when schema data is available.

Core should validate every compiled link eagerly. This avoids Rails' single `@validated` cache.

### 8.6 Statement caches

The Rails prototype includes the selected link in association statement-cache identity.

Core does not need another association statement-cache patch when its `association_link` override returns the selected link.

`SchemaContextProxy` still separates model statement caches by adapter context.

### 8.7 Association object caches

The initial Core implementation assumes that a record does not cross request contexts.

Under this assumption, Core does not need association-cache invalidation for the first version.

Core must document this restriction. Tests and background jobs must not reuse one record across context changes.

If Core later permits that behavior, it must reset cached association objects when the selected link changes.

### 8.8 Verification of Rails consumers

The context stays stable during these operations. Repeated reflection lookups therefore select the same link.

Core must test each path with both selected links. These tests verify the upstream consumer migration.

The initial test scope includes:

- Lazy loading.
- Preloading.
- Eager loading.
- Joins.
- Association predicates.
- Assignment and build operations.
- Autosave.
- Counter caches and touch operations.
- `dependent: :nullify`.
- Used through associations.

Core must audit through associations before enabling runtime selection. Core excludes dynamic HABTM keys.

### 8.9 Polymorphic associations

Rails accepts the associated class when it builds a polymorphic link.

Core must cache links by both context and associated class. Core does not change type columns or stored type values.

Core must test each polymorphic association that uses a Yugabyte override.

## 9. Safety contract

Core's implementation is safe only while all these conditions hold:

- The context stays stable throughout an Active Record operation.
- The context stays stable throughout a request.
- A relation executes in its creation context.
- A model instance does not move between request contexts.
- Association target classes and scopes do not vary.
- Polymorphic type behavior does not vary.

Core should add assertions in test environments where practical.

Rails makes no runtime variance guarantee. The Core patch owns this contract.

## 10. Delivery plan

### Stage 1: Rails foundation

1. Add `Key::Mapping`.
2. Add `AssociationLink`.
3. Build one static link from each reflection.
4. Project existing reflection key methods from the link.
5. Migrate all query consumers to `link.match`.
6. Migrate all write consumers to `link.reference`.
7. Include the link in association statement-cache identity.
8. Prove no visible behavior changes.

### Stage 2: Core link compilation

1. Add the runtime switching flag.
2. Preserve both association shapes during boot.
3. Compile default and Yugabyte links.
4. Validate both links.

### Stage 3: Core link selection

1. Override `association_link` with context selection.
2. Cache links by context and associated class.
3. Fall back to the default link for missing overrides.
4. Test both contexts in one process.

### Stage 4: Core patch removal and model keys

1. Remove the three association query-constraint concerns.
2. Remove the writable foreign-key reflection patch.
3. Remove the custom association subclasses and validator.
4. Keep the separate model query-key patch.

### Stage 5: Verification and rollout

1. Audit unsupported through, polymorphic, and HABTM declarations.
2. Test all used association operations under both contexts.
3. Benchmark hot reflection and association paths.
4. Enable the Core flag for test traffic.
5. Expand the rollout by shop.

## 11. Exit criteria

The work is complete when all these statements are true:

- Rails has no public variant API.
- Rails behavior remains unchanged with static links.
- Core selects links at runtime through one reflection method.
- Rails association queries use `match`.
- Rails association writes use `reference`.
- Both contexts work in one process.
- The selected context stays stable for each operation and request.
- Core no longer selects one permanent association shape during boot.
- Core has tests for every association operation that it uses.

## 12. Future direction

Rails can later add operation-level association routes.

An `AssociationRoute` can contain the same `AssociationLink` without conversion. The route can add classes, scopes, fixed values, and explicit operation capture.

Core can remove its runtime patches if Rails later provides a safe public variance API.
