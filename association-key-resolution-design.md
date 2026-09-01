# Association key resolution

## 1. Purpose

Active Record needs two related features:

- Decoupled association query constraints.
- Dynamic association key selection.
- Dynamic model query constraints.

This design keeps each association reflection stable. It makes only the physical key relationship selectable.

The first feature adds query-only key pairs to an association. The second feature selects different key relationships at runtime.

The third feature selects the model key that Rails uses for persistence and record lookup.

This design does not introduce complete association routes. It leaves target classes, scopes, callbacks, and lifecycle behavior on the reflection.

## 2. Requirements

The design must support these operations:

- Lazy association loading.
- Preloading and eager loading.
- Joins.
- Association predicates.
- Inverse matching.
- Association assignment and clearing.
- Association build and create operations.
- Autosave.
- Touch and counter operations.
- Asynchronous destruction.
- Through associations.
- Model updates, deletes, reloads, and locks.
- Finder ordering that uses model query constraints.

The design must preserve these rules:

- Reads use the complete match mapping.
- Writes use only the writable reference mapping.
- A query-constraint change does not make a cached target stale.
- One operation uses one stable key selection.
- Different SQL shapes use different cache identities.
- Model query keys and association links use the same selected alternative name.

## 3. Non-goals

The first version does not support these capabilities:

- Dynamic target classes.
- Dynamic association scopes.
- Dynamic polymorphic type rules.
- Dynamic callbacks or lifecycle behavior.
- Record-dependent key selection.
- Multiple active routes for one association operation.
- Dynamic `has_and_belongs_to_many` keys.

The selected key alternative applies for the complete request or override block.

The first version does not use `SchemaContextProxy` as its selection mechanism. Rails supplies the resolver.

## 4. Internal model

The internal model has three parts:

```text
                  KeyVariantResolver
                    /           \
                   v             v
ResolvedModelQueryKey       AssociationLink
                                  |
                                  v
                              KeyMapping
```

`KeyMapping` describes ordered column correspondence. `AssociationLink` separates association reads from writes.

`ResolvedModelQueryKey` describes the selected model identity key. `KeyVariantResolver` selects one shared alternative name.

Models resolve query keys. Reflections resolve association links. The reflection keeps all other association behavior.

## 5. `KeyMapping`

`KeyMapping` describes one ordered mapping between two physical database keys.

It always uses this direction:

```text
referencing record -> referenced record
```

The referencing record stores the foreign key. The referenced record supplies the referenced value.

For this association:

```ruby
class LineItem < ApplicationRecord
  belongs_to :order
end
```

the physical mapping is:

```text
line_items.order_id -> orders.id
```

The object can use this shape:

```ruby
KeyMapping.new(
  referencing_key: :order_id,
  referenced_key: :id
)
```

The mapping must:

- Preserve column order.
- Validate equal key sizes.
- Support scalar and composite keys.
- Support differently named columns.
- Be immutable and hashable.
- Copy referenced values into referencing records.

### 5.1 Traversal

Association consumers usually need an owner-to-target view. The physical direction can differ from that view.

`belongs_to` uses the referencing record as its owner. `has_one` and `has_many` use the referenced record as their owner.

`KeyMapping::Traversal` supplies the applicable view:

```ruby
mapping.from(:referencing)
mapping.from(:referenced)
```

The traversal exposes:

```ruby
traversal.owner_key
traversal.target_key
traversal.each
traversal.values_from_owner(owner)
```

Consumers must not reverse column pairs independently.

## 6. `AssociationLink`

`AssociationLink` combines the mappings that establish and query one physical association relationship.

```ruby
AssociationLink.new(
  reference: reference_mapping,
  constraints: constraint_mapping
)
```

It exposes three views:

```text
reference
constraints
match = constraints + reference
```

`reference` contains the writable foreign-key relationship. `constraints` contains query-only column relationships.

`match` contains every relationship that a query must match.

For a tenant-aware order association, the link can contain:

```text
reference:
  line_items.order_id -> orders.id

constraints:
  line_items.shop_id -> orders.shop_id

match:
  line_items.shop_id  -> orders.shop_id
  line_items.order_id -> orders.id
```

The link must be immutable and hashable. Constraint order must be canonical.

## 7. `ResolvedModelQueryKey`

`ResolvedModelQueryKey` contains the key that Rails uses to identify one model record.

```ruby
ResolvedModelQueryKey.new(
  identity: :yugabyte,
  key: ActiveRecord::Key.for([:shop_id, :id])
)
```

The object must be immutable and hashable. It must preserve the selected alternative name.

The model class owns all declared query-key alternatives:

```ruby
class Order < ApplicationRecord
  query_constraints :id

  query_constraint_variants(
    yugabyte: [:shop_id, :id]
  )
end
```

The base declaration defines the `:default` alternative. Rails compiles each alternative during model initialization.

Without a base declaration, `:default` keeps the model's current primary-key behavior.

The model resolves one query key through the shared resolver:

```ruby
Order.resolved_query_key
```

Persistence captures that object once for each operation. It uses the captured key for all predicates in that operation.

The model query key affects:

- Updates and deletes.
- Reloads and locks.
- Counter updates.
- Finder ordering fallbacks.

Rails keeps model query-key declarations on the model class. `SchemaContext` can store related statement caches.

## 8. Reflection integration

The reflection remains the stable association identity.

```ruby
reflection = LineItem.reflect_on_association(:order)
```

The reflection continues to own:

- The association name and macro.
- The target class.
- Scopes.
- Inverse configuration.
- Autosave and validation configuration.
- Dependency behavior.
- Callbacks.
- Touch and counter configuration.
- Through-association configuration.

The reflection adds these internal methods:

```ruby
reflection.association_link(associated_class = nil)
reflection.resolved_association_link(associated_class = nil)
reflection.association_owner_side
reflection.association_mapping(associated_class = nil)
```

`association_link` returns the default physical link. `resolved_association_link` returns the selected link.

`association_owner_side` returns `:referencing` for `belongs_to`. It returns `:referenced` for `has_one` and `has_many`.

`association_mapping` returns the selected match mapping in owner-to-target direction:

```ruby
def association_mapping(associated_class = nil)
  resolved_association_link(associated_class)
    .match
    .from(association_owner_side)
end
```

Rails does not introduce `QueryKeyMapping`. No released API requires a compatibility object.

## 9. Consumer contract

Every association consumer must select the correct link view.

### 9.1 Read consumers

Read consumers use `link.match`.

These consumers include:

- Lazy loading.
- Join construction.
- Preloading.
- Eager loading.
- Association predicates.
- Inverse matching.
- Touch and counter lookups.
- Old-target lookup.
- Asynchronous destruction lookup.

### 9.2 Write consumers

Write consumers use `link.reference`.

These consumers include:

- Assignment.
- Clearing and nullification.
- Association build and create operations.
- Autosave key assignment.
- Foreign-key stale tracking.

Query constraints must not supply default attributes during an association build operation.

### 9.3 Complete operation boundaries

Each operation must use one resolved link for all its stages.

A preload operation includes these stages:

1. Rails resolves the selected link.
2. Rails groups owners by that link.
3. Rails extracts owner values.
4. Rails builds SQL.
5. Rails extracts target values.
6. Rails associates results with owners.

Rails must not resolve different links during these stages.

## 10. Decoupled association query constraints

The public association option adds query-only mappings:

```ruby
class LineItem < ApplicationRecord
  belongs_to :order,
    foreign_key: :order_id,
    query_constraints: :shop_id
end
```

Rails normalizes this declaration into an `AssociationLink`:

```text
reference:
  line_items.order_id -> orders.id

constraints:
  line_items.shop_id -> orders.shop_id
```

The association read uses both mappings:

```sql
WHERE orders.shop_id = ?
  AND orders.id = ?
```

The association assignment writes only `order_id`:

```ruby
line_item.order = order
```

Rails does not copy `order.shop_id` into `line_item.shop_id`.

### 10.1 Renamed columns

The option can map different column names:

```ruby
query_constraints: { shop_id: :account_shop_id }
```

Rails normalizes the declaration into two corresponding physical keys.

The normalization logic belongs in reflection option processing. It does not belong in `KeyMapping`.

### 10.2 Validation

Rails must validate these conditions:

- Reference keys have equal sizes.
- Constraint keys have equal sizes.
- A constraint does not duplicate a writable foreign-key column.
- A renamed constraint has an explicit direction.
- Every referenced column exists when schema information is available.

## 11. Dynamic model query constraints

Dynamic model query constraints select one declared `ResolvedModelQueryKey`.

For this declaration:

```ruby
class Order < ApplicationRecord
  query_constraints :id

  query_constraint_variants(
    yugabyte: [:shop_id, :id]
  )
end
```

Rails uses these effective keys:

```text
default:
  id

yugabyte:
  shop_id + id
```

The selected key controls persistence SQL. For example, Yugabyte updates use both columns:

```sql
UPDATE orders
SET status = ?
WHERE shop_id = ?
  AND id = ?
```

Rails must use the original database value when an update changes one selected key column.

Model query-key alternatives do not automatically change association links. Each association declares its link alternatives explicitly.

This rule prevents model-level selection from silently changing association SQL.

## 12. Dynamic association key alternatives

Dynamic selection chooses one complete `AssociationLink`. It does not choose another reflection.

A model declaration could use this API:

```ruby
class LineItem < ApplicationRecord
  belongs_to :order,
    foreign_key: :order_id,
    key_variants: {
      yugabyte: {
        foreign_key: :order_id,
        query_constraints: :shop_id
      }
    }
end
```

The base association defines the `:default` alternative.

The declaration compiles into immutable links during model initialization:

```text
default:
  reference: order_id -> id

yugabyte:
  reference:   order_id -> id
  constraints: shop_id  -> shop_id
```

Alternatives replace the complete key specification. They do not merge with the base key specification.

Only these options can vary:

- `primary_key`.
- `foreign_key`.
- `query_constraints`.

## 13. `KeyVariantResolver`

The application supplies selection policy. Rails supplies resolution mechanics.

```ruby
config.active_record.key_variant_resolver = lambda do
  YugabyteContext.enabled? ? :yugabyte : :default
end
```

The resolver returns one alternative name for the complete request or override block.

Models use that name to resolve query keys. Reflections use the same name to resolve association links.

A model or association without the selected alternative uses `:default`. This fallback supports incremental conversion.

The resolver result must remain stable during one association operation.

Rails should also support a block override for tests and scripts:

```ruby
ActiveRecord::Base.with_key_variant(:yugabyte) do
  order.reload
  line_item.order
end
```

The block override takes precedence over the application resolver.

## 14. Cache behavior

Dynamic keys can produce different SQL and bind shapes. Selected model and association identities must participate in cache behavior.

### 14.1 Statement caches

Model statement-cache identity must include the selected model query key.

Association statement-cache identity must include the selected alternative or resolved link:

```text
[reflection, resolved link]
```

Rails must not reuse this MySQL statement:

```sql
WHERE orders.id = ?
```

for this Yugabyte statement:

```sql
WHERE orders.shop_id = ? AND orders.id = ?
```

### 14.2 Association caches

A loaded association must remember its selected link identity.

Rails must reload the association when the selected identity changes.

### 14.3 Preload groups

The preloader must group owners by resolved link.

A request-global resolver usually produces one group. Explicit override tests can produce separate groups.

### 14.4 Through-association chains

A through association uses one resolved link for each reflection in its chain.

Cache identity must include the complete ordered link combination.

Rails can represent this combination as an array. The first version does not need a general route-chain object.

## 15. Polymorphic associations

The first version preserves current polymorphic type behavior.

Rails resolves the target class through existing reflection logic. It then resolves keys for that target class:

```ruby
reflection.resolved_association_link(target_class)
```

A key alternative cannot change:

- The target class.
- The type column.
- The stored type value.

Rails can cache one immutable link for each target class and alternative name.

## 16. Mid-operation stability

The selected alternative must not change during one operation.

Rails should capture the current selection identity before it resolves a link.

Persistence captures one model query key before it builds a statement. Association operations capture one link before they build SQL.

Relations keep the link selection that Rails used during relation construction. Execution does not rebuild the relation with a new selection.

This rule gives stable SQL to relations that outlive an override block.

## 17. Core integration

Core can replace its custom Yugabyte APIs with the Rails public APIs in this design.

### 17.1 Current Core declarations

`LineItem` currently uses a Core model macro:

```ruby
class LineItem < ApplicationRecord
  self.primary_key = :id
  yugabyte_query_constraints :order_id, :id, :shop_id

  belongs_to :order,
    inverse_of: :line_items,
    autosave: false,
    primary_key: :id,
    yugabyte_overrides: {
      query_constraints: [:order_id, :shop_id],
      primary_key: [:id, :shop_id],
      foreign_key: :order_id,
    }
end
```

The custom association arrays describe the complete Yugabyte match. They mix the writable foreign key with query-only constraints.

### 17.2 Rails public declarations

The Rails APIs separate the writable reference from additional constraints:

```ruby
class LineItem < ApplicationRecord
  self.primary_key = :id

  query_constraint_variants(
    yugabyte: [:order_id, :id, :shop_id]
  )

  belongs_to :order,
    inverse_of: :line_items,
    autosave: false,
    primary_key: :id,
    key_variants: {
      yugabyte: {
        primary_key: :id,
        foreign_key: :order_id,
        query_constraints: :shop_id,
      }
    }
end
```

The model uses its primary-key behavior for `:default`. It uses `[:order_id, :id, :shop_id]` for `:yugabyte`.

The association uses these Yugabyte mappings:

```text
reference:
  line_items.order_id -> orders.id

constraints:
  line_items.shop_id -> orders.shop_id
```

The writable `order_id` pair no longer appears in `query_constraints`.

### 17.3 A `has_many` migration

`LineItem#sales` currently uses this Core declaration:

```ruby
has_many :sales,
  -> { order(id: :asc) },
  inverse_of: :line_item,
  autosave: false,
  yugabyte_overrides: {
    query_constraints: [:order_id, :line_item_id, :shop_id],
    primary_key: [:order_id, :id, :shop_id],
    foreign_key: :line_item_id,
  }
```

The Rails public API expresses the same relationship:

```ruby
has_many :sales,
  -> { order(id: :asc) },
  inverse_of: :line_item,
  autosave: false,
  key_variants: {
    yugabyte: {
      primary_key: :id,
      foreign_key: :line_item_id,
      query_constraints: [:order_id, :shop_id],
    }
  }
```

The reference maps `LineItem#id` to `Sale#line_item_id`. The constraints match `order_id` and `shop_id` on both models.

### 17.4 Shared selection

Core configures the shared Rails resolver:

```ruby
config.active_record.key_variant_resolver = lambda do
  YugabyteContext.enabled? ? :yugabyte : :default
end
```

Core does not need `SchemaContextProxy` to override model query constraints.

Models and reflections declare alternatives. The shared Rails resolver defines selection policy.

Rails does not provide runtime `SchemaContext` switching with this feature. One stable schema can contain every column for several key alternatives.

Core still uses `SchemaContextProxy` for database-specific columns, types, defaults, and schema caches. The same Core context selects compatible schema and key states.

### 17.5 Core migration rules

Core can migrate one model at a time. A missing `:yugabyte` alternative continues to use `:default`.

For each model, replace `yugabyte_query_constraints` with `query_constraint_variants`.

For each association, replace `yugabyte_overrides` with `key_variants`.

Remove the writable foreign-key pair from the old `query_constraints` array. Keep that pair in `foreign_key` and `primary_key`.

Keep scopes, callbacks, inverse options, and lifecycle options on the base association.

After all declarations migrate, Core can remove the custom model and association patches.

## 18. Delivery units

Some changes can ship independently. Feature changes require completed internal contracts.

### 18.1 Unit A: Physical mappings

Ship these changes together:

- `KeyMapping`.
- `KeyMapping::Traversal`.
- Static reflection mapping construction.
- Tests for both traversal directions.

This unit changes no behavior.

### 18.2 Unit B: Association links

Ship these changes together after Unit A:

- `AssociationLink`.
- Static reflection link construction.
- Empty constraints for existing associations.

This unit changes no behavior because `match` equals `reference`.

### 18.3 Unit C: Association consumer migration

Migrate consumers in complete operation groups:

1. Lazy loading and association scopes.
2. Joins and eager loading.
3. Preloading and result matching.
4. Assignment, creation, and clearing.
5. Autosave, inverse matching, and stale tracking.
6. Touch, counter, and asynchronous destruction operations.
7. Through associations.

Each group can ship independently. Each operation must use one consistent link view from start to finish.

### 18.4 Unit D: Decoupled association query constraints

This feature requires completed Units A through C.

Ship these changes together:

- The public option.
- Option normalization.
- Validation.
- Constraint link construction.
- Documentation.
- Tests for all supported operations.

This unit must not require new consumer-specific behavior.

### 18.5 Unit E: Model query-key objects

Ship these changes independently:

- `ResolvedModelQueryKey`.
- Static model query-key construction.
- Persistence capture of one query key per operation.
- Variant-aware statement-cache identity.

All models still select `:default`. Therefore, this unit changes no visible behavior.

### 18.6 Unit F: Shared selection preparation

Ship these changes independently after Units C and E:

- Resolved link identity.
- Resolved model query-key identity.
- Link-aware statement-cache identity.
- Link-aware association-cache metadata.
- Link-aware preload grouping.
- Ordered link identities for through chains.

All associations still select `:default`. Therefore, this unit changes no visible behavior.

### 18.7 Unit G: Shared Rails resolver

Ship these changes together after Units E and F:

- `current_key_variant`.
- `key_variant_resolver` configuration.
- `with_key_variant` block overrides.
- Request-stability rules.

All declarations still have only `:default`. Therefore, this unit changes no visible behavior.

### 18.8 Unit H: Dynamic model query constraints

This feature requires Units E and G.

Ship these changes together:

- Named model query-key alternatives.
- Model declaration validation.
- Runtime model query-key resolution.
- Persistence and finder behavior tests.
- Public documentation.

### 18.9 Unit I: Dynamic association key selection

This feature requires Units A, B, C, F, and G. Unit D is not a structural requirement.

Ship these changes together:

- Named key alternatives.
- Runtime link resolution.
- Public documentation.
- MySQL and Yugabyte behavior tests.

Units D and H should normally ship first. Yugabyte association alternatives use decoupled constraints and matching model query keys.

## 19. Required test matrix

Each supported association type needs tests for both default and Yugabyte links.

The test matrix includes:

- Default and Yugabyte model query keys.
- Model updates, deletes, reloads, and locks.
- Changes to selected model query-key columns.
- Finder ordering with each model query key.
- `belongs_to` reads and writes.
- `has_one` reads and writes.
- `has_many` reads and writes.
- Scalar and composite reference keys.
- Added query constraints.
- Renamed query constraints.
- Lazy loading.
- Preloading and eager loading.
- Joins.
- Inverse matching.
- Autosave.
- Touch and counter operations.
- Asynchronous destruction.
- Through associations.
- Polymorphic associations with a fixed type policy.
- Statement-cache separation.
- Association-cache invalidation.
- Nested override blocks.
- Relations that outlive override blocks.
- One shared selection for model and association operations.

## 20. Migration path to complete routes

This design does not prevent a later `AssociationRoute` abstraction.

A future route can contain the existing link:

```ruby
AssociationRoute.new(
  referencing_class: LineItem,
  referenced_class: Order,
  link: resolved_link,
  owner_side: :referencing
)
```

Rails should use complete routes when it needs these capabilities:

- Dynamic target classes.
- Record-dependent selection.
- Dynamic discriminator values.
- Endpoint-specific scopes.
- Multiple simultaneous routes.

The current design keeps the smaller boundary that Core requires. It selects association keys without reflection swapping.

## 21. Summary

The model resolves one immutable query key. The reflection resolves one immutable association link.

Both operations use one shared Rails key variant. Core supplies policy through the Rails resolver.

`AssociationLink` separates writable references from query-only constraints. Decoupled query constraints populate the constraint mapping.

Dynamic selection chooses one model query key and one association link. Cache and preload identities include that selection.

This design delivers all required key features without reflection swapping or a complete association-route refactor.
