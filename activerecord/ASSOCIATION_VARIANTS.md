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

That wrapper is the public reflection identity for the association. It asks the
selector block for a variant key, memoizes a concrete same-class reflection for
that key, and uses that concrete reflection as an internal calculator for
option-derived values such as `foreign_key`, `active_record_primary_key`, and
`association_primary_key`.

The important boundary is that the concrete variant reflections should not
become the association identity. Callers that cache, compare, or walk the
reflection chain should continue to see the wrapper as the abstract
inter-relationship. Variant reflections exist to reuse the normal reflection
initialization and memoization logic for a specific option set.

Variant associations can use the association statement cache when the cache key
includes the selected variant key. SQL built for an `id`/`post_id` variant must
not be reused for a `uuid`/`post_uuid` variant, but each variant can have its own
cached statement.

## Statement Cache Refinement

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

## Inverse Associations

`inverse_of` is the hardest open design problem for association variants.
Rails currently treats an inverse as a memoized relationship between concrete
reflection objects. That assumption breaks down when the keys, options, and even
possibly the target class can vary by runtime context.

The target shape should split inverse identity from inverse compatibility:

* The inverse identity is the logical association on the other model, such as
  `Comment#post` for `Post#comments`. This should be represented by the
  abstract reflection, not a selected concrete variant reflection.
* Inverse compatibility is context-specific. The current selected variant on
  each side must be checked to decide whether the two abstract associations are
  valid inverses in that context.

That means `AssociationVariantReflection#inverse_of` should not simply return
the selected concrete variant reflection's memoized `inverse_of`. Doing so
reintroduces the "separate reflections with matching names" problem: each
variant can independently infer and cache an inverse, and Rails loses the fact
that there is one abstract inter-relationship whose shape changes by context.

A better internal model is:

```ruby
class AssociationVariantReflection
  def inverse_of
    inverse_for_selected_variant
  end

  private
    def inverse_for_selected_variant
      @inverse_by_variant.fetch(selected_variant_name) do
        candidate = abstract_inverse_candidate

        @inverse_by_variant[selected_variant_name] =
          inverse_compatible_in_current_context?(candidate) ? candidate : false
      end
    end
end
```

`abstract_inverse_candidate` would resolve either an explicit `inverse_of:` or
an automatically inferred candidate to the other side's abstract reflection.
`inverse_compatible_in_current_context?` would compare the selected variants'
effective association shape rather than comparing globally memoized reflection
methods.

One useful way to make that comparison explicit is a small value object for the
association shape in the current context. It could contain the pieces relevant
to inverse matching, such as:

* owner class and target class
* macro direction
* foreign key
* association primary key
* polymorphic type / foreign type, when applicable
* options that disable automatic inverse inference

The abstract reflection owns relationship identity and inverse semantics. The
selected concrete variant reflection can still compute the current shape, but it
should not be the object returned as the inverse.

Automatic inverse inference should be conservative. If two associations are
inverse-compatible in one variant but not another, either use the inverse only
when the current variant pair is compatible, or decline automatic inverse
inference unless compatibility holds for every declared variant. Explicit
`inverse_of:` can be interpreted as naming the logical inverse association, but
it should still be validated against the current context before Rails uses it
for inverse assignment.

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
* Design and implement context-aware `inverse_of` so inverse identity belongs to
  the abstract association while compatibility is checked against the selected
  variant shape.
