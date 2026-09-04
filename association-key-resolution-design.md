# Association key resolution

## 1. Proposal

Active Record needs three related features:

- Association query constraints that do not change writable foreign keys.
- Runtime selection between declared association key variants.
- Runtime selection between declared model query-key variants.

This design introduces four internal concepts:

```text
KeyVariantResolver
  |-- ResolvedModelQueryKey
  `-- AssociationLink
        |-- reference: KeyMapping
        |-- constraints: KeyMapping
        `-- match: constraints + reference
```

The design keeps each association reflection stable. Runtime selection changes keys, but it does not change association behavior.

Reads use the complete `match` mapping. Writes use only the `reference` mapping.

One shared variant name selects compatible model and association keys. The application supplies the selection policy.

## 2. Public API

### 2.1 Association query constraints

The `query_constraints:` option adds query-only column pairs:

```ruby
class LineItem < ApplicationRecord
  belongs_to :order,
    foreign_key: :order_id,
    query_constraints: :shop_id
end
```

Rails resolves this link:

```text
reference:
  line_items.order_id -> orders.id

constraints:
  line_items.shop_id -> orders.shop_id
```

An association read matches both mappings:

```sql
WHERE orders.shop_id = ?
  AND orders.id = ?
```

Assignment writes only the reference:

```ruby
line_item.order = order
```

Rails writes `order_id`. Rails does not copy `order.shop_id` into `line_item.shop_id`.

The option can map different column names:

```ruby
query_constraints: { shop_id: :account_shop_id }
```

The key on the left names the referencing column. The value names the referenced column.

### 2.2 Association key variants

The `key_variants:` option declares complete association key alternatives:

```ruby
class LineItem < ApplicationRecord
  belongs_to :order,
    foreign_key: :order_id,
    key_variants: {
      yugabyte: {
        primary_key: :id,
        foreign_key: :order_id,
        query_constraints: :shop_id,
      }
    }
end
```

The base association defines the `:default` variant. Each named variant replaces the complete key specification.

Only these association options can vary:

- `primary_key`.
- `foreign_key`.
- `query_constraints`.

Scopes, target classes, callbacks, dependency rules, and lifecycle options remain on the base reflection.

### 2.3 Model query-key variants

The existing `query_constraints` macro accepts a `key_variants:` option:

```ruby
class Order < ApplicationRecord
  query_constraints :id,
    key_variants: {
      yugabyte: [:shop_id, :id]
    }
end
```

The declaration produces these model query keys:

```text
default:   id
yugabyte:  shop_id + id
```

The selected key controls persistence SQL:

```sql
UPDATE orders
SET status = ?
WHERE shop_id = ?
  AND id = ?
```

The selected model key applies to these operations:

- Updates and deletes.
- Reloads and locks.
- Counter updates.
- Finder ordering fallbacks.

Rails uses original database values when an update changes a selected key column.

Model variants do not change association links automatically. Each association declares its own compatible variants.

### 2.4 Variant selection

The application configures one resolver:

```ruby
config.active_record.key_variant_resolver = lambda do
  YugabyteContext.enabled? ? :yugabyte : :default
end
```

Models and reflections use the same selected name. A declaration without that name falls back to `:default`.

Selection and declaration lookup use these rules:

- Rails selects `:default` when the application does not configure a resolver.
- A configured resolver must return a variant name, including `:default` when applicable.
- Rails raises an error when a configured resolver returns `nil` or an unsupported value.
- Rails uses the selected name to choose a variant from each model or association declaration.
- A declaration without the selected name uses its base `:default` key.

The selected name remains stable for a complete request. This rule gives models and associations one compatible selection context.

## 3. Scope

The first version supports these association operations:

- Lazy loading, preloading, eager loading, and joins.
- Association predicates and inverse matching.
- Assignment, clearing, build, create, and autosave operations.
- Touch, counter, and asynchronous destruction operations.
- Through-association construction and nullification.
- Existing polymorphic associations with fixed type behavior.

The first version excludes these capabilities:

- Dynamic target classes, scopes, type rules, callbacks, or lifecycle behavior.
- Record-dependent key selection.
- Multiple active links for one association operation.
- Dynamic HABTM keys.

The current Core checkout has no direct HABTM declarations. HABTM support would also require atomic selection for two generated links.

Rails does not use `SchemaContextProxy` as the resolver.

## 4. Internal model

### 4.1 `KeyMapping`

`KeyMapping` describes ordered correspondence between two physical database keys:

```ruby
KeyMapping.new(
  referencing_key: [:shop_id, :order_id],
  referenced_key: [:shop_id, :id]
)
```

It always uses this physical direction:

```text
record with the foreign key -> record that supplies the referenced value
```

`KeyMapping` has these responsibilities:

- Preserve pair order.
- Validate equal key sizes.
- Support scalar, composite, and differently named keys.
- Copy referenced values into a referencing record.
- Provide immutable equality and hash behavior.

Association consumers often need an owner-to-target view. `KeyMapping#from` supplies that traversal:

```ruby
mapping.from(:referencing)
mapping.from(:referenced)
```

The traversal exposes `owner_key`, `target_key`, pairs, and owner values. Consumers must not reverse pairs independently.

### 4.2 `AssociationLink`

`AssociationLink` contains the column mappings for one physical relationship:

```ruby
AssociationLink.new(
  reference: reference_mapping,
  constraints: constraint_mapping
)
```

It exposes three mappings:

```text
reference    writable foreign-key relationship
constraints  query-only relationships
match        constraints + reference
```

The link is immutable and hashable.

Reflection option processing normalizes constraint pairs into a canonical order. It sorts complete pairs and preserves each pair's correspondence.

Reference order remains unchanged because composite reference keys can require positional correspondence.

### 4.3 `ResolvedModelQueryKey`

`ResolvedModelQueryKey` contains a selected model identity:

```ruby
ResolvedModelQueryKey.new(
  identity: :yugabyte,
  key: ActiveRecord::Key.for([:shop_id, :id])
)
```

The object is immutable and hashable. It preserves the selected variant name for cache identity.

The model compiles all declared variants during initialization. Persistence captures one resolved object for each operation.

### 4.4 Reflection integration

The reflection remains the stable association identity. It continues to own all non-key association behavior.

The reflection owns its declared link variants. Rails resolves one link for each operation.

Rails interprets the physical link from the reflection direction. Polymorphic resolution can also provide the associated class.

## 5. Consumer contract

Every read consumer uses `link.match`. Every write consumer uses `link.reference`.

Query constraints do not supply attributes during build operations. They also do not participate in stale foreign-key tracking.

Each operation resolves its link once. A preload operation uses that object for grouping, SQL, value extraction, and result matching.

Relations retain the selected links from relation construction. Execution does not resolve new links.

A change to a query-only column does not make a loaded target stale. A change to the selected link identity does.

## 6. Cache behavior

Different variants can produce different SQL shapes and bind counts.

Model statement-cache identity includes the resolved model query key. Association statement-cache identity includes the reflection and resolved link.

The preloader groups owners by resolved link. A loaded association records its selected link identity.

A through association includes its ordered link identities in cache identity. The first version does not need a route-chain object.

## 7. Polymorphic and through associations

The first version keeps existing polymorphic type behavior.

Rails resolves the target class through existing reflection logic. It then resolves the link for that class and selected variant.

The first version does not let a key variant change target-class resolution, the polymorphic type column, or stored type semantics.

A through association resolves one link for each reflection in its chain. Construction and nullification use each link's `reference` mapping.

## 8. Validation

Rails validates these conditions during declaration compilation:

- Reference endpoints have equal sizes.
- Constraint endpoints have equal sizes.
- A constraint does not duplicate a writable referencing column.
- A renamed constraint has an explicit direction.
- Referenced columns exist when schema information is available.
- Every variant contains only supported options.

## 9. Core migration

Core can replace its custom model and association APIs with these Rails APIs.

For example, this current declaration mixes writable and query-only pairs:

```ruby
class LineItem < ApplicationRecord
  yugabyte_query_constraints :order_id, :id, :shop_id

  belongs_to :order,
    primary_key: :id,
    yugabyte_overrides: {
      query_constraints: [:order_id, :shop_id],
      primary_key: [:id, :shop_id],
      foreign_key: :order_id,
    }
end
```

The Rails APIs separate those roles:

```ruby
class LineItem < ApplicationRecord
  query_constraints :id,
    key_variants: {
      yugabyte: [:order_id, :id, :shop_id]
    }

  belongs_to :order,
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

The association reference maps `line_items.order_id` to `orders.id`. The constraint matches `shop_id` on both records.

Core removes the writable `order_id` pair from association `query_constraints`. It remains in `foreign_key` and `primary_key`.

A missing `:yugabyte` variant falls back to `:default`. This rule permits migration one model at a time.

Core still uses `SchemaContextProxy` for database-specific columns, types, defaults, and schema caches.

## 10. Comparison with Matthew Draper's route refactor

Both designs use the same `KeyMapping` and `AssociationLink` concepts. Their object shapes and logical meanings match.

The main difference is the containing abstraction:

| Area | This design | Association-route refactor |
|---|---|---|
| Resolved object | The reflection resolves an `AssociationLink`. | An `AssociationRouter` resolves an `AssociationRoute`. |
| Variable data | Model keys and association keys can vary. | Classes, keys, fixed values, and endpoint scopes can vary. |
| Selection | One shared variant name selects model and association keys. | Each router can use its own policy and context. |
| Model persistence | The design includes model query-key variants. | The refactor does not change model persistence keys. |
| Polymorphism | Existing logic resolves the class before link resolution. | The router resolves the class and discriminator with the route. |
| Public API | The design adds query constraints and key variants. | The branch keeps association declarations unchanged. |

This design uses the smaller boundary that Core needs. The reflection remains authoritative for target classes, scopes, and lifecycle behavior.

The route refactor supports future dynamic classes, scopes, discriminators, and record-dependent selection.

A later `AssociationRoute` can contain the `AssociationLink` from this design without conversion.

See [Association Routes as an Internal Key Model](https://gist.github.com/matthewd/96472f4d1acbda81c677077e985f73a1).

## 11. Delivery and verification

The implementation can use these delivery stages:

1. Add physical `KeyMapping` and static reflection mappings.
2. Add `AssociationLink` with empty constraints.
3. Migrate association consumers in complete operation groups.
4. Add association query constraints.
5. Add resolved model query keys and cache identity.
6. Add the shared resolver.
7. Add model `query_constraints key_variants:`.
8. Add association `key_variants:`.

Stages 1, 2, 3, 5, and 6 change no visible behavior. Stages 4, 7, and 8 add public behavior.

Association variants depend on association query constraints when a variant adds query-only pairs.

### 11.1 Query-constraints-first delivery

The project can deliver decoupled association query constraints before dynamic association keys.

This sequence requires a scope cut, not only a stage reorder:

1. Finalize the association `query_constraints:` API.
2. Add static `KeyMapping` and `AssociationLink` objects.
3. Migrate association consumers to use `match` for reads and `reference` for writes.
4. Add normalization and validation for `query_constraints:`.
5. Ship association `query_constraints:`.
6. Finalize the association `key_variants:` and resolver APIs.
7. Add resolved-link identity, operation capture, and variant-aware cache behavior.
8. Ship association `key_variants:`.
9. Add model key variants when the upstream model design is ready.

The first five stages do not need routes, named variants, runtime resolution, or variant-aware caches.

The public option must wait until every affected association operation uses the correct link view.

Dynamic association work then reuses the same consumer contract:

```text
read  -> selected_link.match
write -> selected_link.reference
```

Model query-key variants do not block association query constraints. Core can investigate runtime model constraints through `SchemaContextProxy` as a separate track.

A broader route refactor can continue behind these APIs. A future `AssociationRoute` can contain the static `AssociationLink` without conversion.
