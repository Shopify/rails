# Association Variants Prototype

This prototype adds `has_many_with_variants` as a narrow entrypoint for exploring
keyed, runtime-selected association variants.

The motivating case is an association that usually joins through the conventional
primary key and foreign key, but can switch at runtime to a different key pair,
such as an `id`/`post_id` association moving to a `uuid`/`post_uuid` association:

```ruby
has_many_with_variants :comments,
  variants: {
    default: { foreign_key: :post_id },
    uuid: { fk: :post_uuid, pk: :uuid }
  } do
  if beta_flag_check(:use_uuids)
    :uuid
  else
    :default
  end
end
```

The block is evaluated against the owner record when the association is used.
It returns the key for one of the predefined variants.

## API Options

### Prototype shape: explicit `variants:` plus selector block

```ruby
has_many_with_variants :comments,
  variants: {
    default: { foreign_key: :post_id },
    uuid: { foreign_key: :post_uuid, primary_key: :uuid }
  } do
  beta_flag_check(:use_uuids) ? :uuid : :default
end
```

This is the shape used by the prototype. It separates static declaration from
runtime selection, lets Rails normalize and validate every variant up front, and
makes statement-cache keys straightforward because the runtime value is a stable
variant key. It is concise and keeps the selected variant visually close to the
variant table.

The main drawback is that regular association blocks are already used for
association extension methods. A `_with_variants` API can choose to give the
block a different meaning, but that makes it less compatible with existing
association conventions.

### Short aliases inside variants

```ruby
has_many_with_variants :comments,
  variants: {
    default: { fk: :post_id },
    uuid: { fk: :post_uuid, pk: :uuid }
  } do
  beta_flag_check(:use_uuids) ? :uuid : :default
end
```

This is compact, but it introduces association-specific abbreviations that Rails
does not generally use. It is useful for prototyping, but the long option names
are clearer and avoid making variant declarations feel like a separate DSL.

### Recommended public shape: selector as an option

```ruby
has_many_with_variants :comments,
  variants: {
    default: { foreign_key: :post_id },
    uuid: { foreign_key: :post_uuid, primary_key: :uuid }
  },
  variant: -> { beta_flag_check(:use_uuids) ? :uuid : :default }
```

This is the shape I would lean toward for a public Rails API. It preserves the
existing association block for extension methods, keeps the variant selector as
just another association option, and still gives Rails static variant data to
normalize up front.

The tradeoff is that the selector is slightly less prominent. A clearer option
name like `select_variant:` or `variant_selector:` might be better than
`variant:` if we want to emphasize that the proc returns a key, not options.

### Nested variant builder

```ruby
has_many_with_variants :comments do
  variant :default, foreign_key: :post_id
  variant :uuid, foreign_key: :post_uuid, primary_key: :uuid

  select_variant { beta_flag_check(:use_uuids) ? :uuid : :default }
end
```

This gives Rails room to grow a richer DSL, but it is heavier than the problem
requires and conflicts with the current association block convention, where the
block usually defines extension methods on the association proxy.

### Fully dynamic options block

```ruby
has_many_with_variants :comments do
  if beta_flag_check(:use_uuids)
    { foreign_key: :post_uuid, primary_key: :uuid }
  else
    { foreign_key: :post_id }
  end
end
```

This was the original sketch. It is flexible, but it forces Rails to repeatedly
normalize and merge options at runtime and makes cache keys depend on the shape
of arbitrary returned hashes. The keyed API is better for the UUID migration
case because the variants are known in advance and only the selection is
dynamic.

## Chosen Approach

Association reflections are shared class-level metadata, so mutating the base
reflection would leak one record's selected variant into other records. Instead,
the prototype predefines named variant option sets on the reflection, then wraps
variant-enabled reflections in an owner-bound `AssociationVariantReflection`
when an association instance is created.

That wrapper delegates ordinary reflection behavior back to the original
reflection, but asks the selector block for a variant key and uses the matching
prebuilt option set. The base reflection stores the original declaration, the
variant table, and the selector block.

Variant associations bypass the memoized association scope and statement cache.
The active key pair can change at runtime, so cached SQL built for one variant
must not be reused for another variant.

Automatic inverse detection is disabled for variant associations because there
is no single class-level foreign key to compare against a possible inverse.

## Statement Cache Refinement

The current prototype disables the association statement cache for variant
associations. That is conservative, but the keyed API gives us a cleaner final
shape.

Association statement caching is keyed by the value passed from
`association_scope_cache` into `cached_find_by_statement`. For ordinary
associations this is the reflection object, and polymorphic associations add the
runtime polymorphic type to the key.

Variant associations can keep the statement cache if the cache key includes the
selected variant key. Because each key maps to a predefined option set, the key
is a stable signature for the SQL shape. A conservative variant cache key could
also include the normalized key-related options:

```ruby
[
  selected_variant_key,
  resolved_options[:primary_key],
  resolved_options[:foreign_key],
  resolved_options[:query_constraints],
]
```

With either shape, an `id`/`post_id` variant and a `uuid`/`post_uuid` variant
would build and reuse separate cached statements. Flipping the runtime flag
would pick the matching cached statement instead of disabling caching for every
variant association.

## Dynamic Pieces

The prototype resolves these pieces dynamically:

* selected variant key
* `options` for the selected prebuilt variant
* `foreign_key`
* `active_record_primary_key`
* `association_primary_key` for `belongs_to`-style key resolution
* `join_primary_key`
* `join_foreign_key`
* owner join ids used by association scopes
* association scope construction for variant associations
* statement-cache eligibility for association loads

## Current Scope

The exposed API is intentionally limited to `has_many_with_variants`.
The internal reflection wrapper is generic enough to explore the same idea for
other association macros, but those public APIs are not added in this slice.

The first tests use existing `posts` and `comments` columns to switch between
the default `id`/`post_id` join and a custom `title`/`body` join. That covers the
same primary-key and foreign-key mechanics as the UUID example without changing
the shared test schema.

## Known Follow-ups

* Decide whether `default` is a reserved variant key or just a convention.
* Decide whether `foreign_key: :post_id` should represent an explicit variant or
  a request to use the association default.
* Decide whether the option validator should expose variant internals as public
  valid keys for every association macro or keep them private to the
  `_with_variants` entrypoints.
* Extend the public API beyond `has_many_with_variants` if this shape proves out.
* Audit preload, eager loading, and through-association behavior once the API
  surface is broader than direct `has_many`.
