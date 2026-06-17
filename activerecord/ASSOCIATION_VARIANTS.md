# Association Variants Prototype

This prototype adds `has_many_with_variants` as a narrow entrypoint for exploring
runtime-resolved association options.

The motivating case is an association that usually joins through the conventional
primary key and foreign key, but can switch at runtime to a different key pair,
such as an `id`/`post_id` association moving to a `uuid`/`post_uuid` association:

```ruby
has_many_with_variants :comments do
  if beta_flag_check(:use_uuids)
    { primary_key: :uuid, foreign_key: :post_uuid }
  else
    { foreign_key: :post_id }
  end
end
```

The block is evaluated against the owner record when the association is used.
It returns the option overrides for the active variant.

## Chosen Approach

Association reflections are shared class-level metadata, so mutating the base
reflection would leak one record's selected variant into other records. Instead,
the prototype wraps variant-enabled reflections in an owner-bound
`AssociationVariantReflection` when an association instance is created.

That wrapper delegates ordinary reflection behavior back to the original
reflection, but resolves key-related options dynamically from the variant block.
The base reflection still stores the original declaration and the variant block.

Variant associations bypass the memoized association scope and statement cache.
The active key pair can change at runtime, so cached SQL built for one variant
must not be reused for another variant.

Automatic inverse detection is disabled for variant associations because there
is no single class-level foreign key to compare against a possible inverse.

## Dynamic Pieces

The prototype resolves these pieces dynamically:

* `options`
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

* Decide whether `foreign_key: :post_id` should represent an explicit variant or
  a request to use the association default.
* Decide whether the option validator should expose `:variant_options` as a
  public valid key for every association macro or keep it private to the
  `_with_variants` entrypoints.
* Extend the public API beyond `has_many_with_variants` if this shape proves out.
* Audit preload, eager loading, and through-association behavior once the API
  surface is broader than direct `has_many`.
