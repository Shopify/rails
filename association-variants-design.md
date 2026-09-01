# Dynamic association variants — design notes

---

## 1. Problem

One association needs two different key structures, picked at runtime, in one
process. Usually because the keys are mid-migration.

Rails shipped composite primary keys in 7.1 and `query_constraints` in 7.2, and
#58266 extends `query_constraints` to associations. Adopting any of them on a live
app means a period where both the old key shape and the new one have to work at
once. Rails has no way to say that. Today you write:

```ruby
belongs_to :order_legacy,  class_name: "Order", foreign_key: :order_id
belongs_to :order_sharded, class_name: "Order", foreign_key: :order_id, query_constraints: :shop_id

def order
  Current.tenant_scoped_keys? ? order_sharded : order_legacy
end
# ...and every joins/includes/preload call site branches too
```

Use cases for the PR. Only list ones expressible with the three key options the
first PR ships (§4.2) — anything needing `class_name`, `scope`, or `polymorphic` is
a follow-up, and citing it invites "your API doesn't do that."

- **Adopting composite keys / `query_constraints` incrementally** — adding a tenant
  or shard column to existing keys. The flagship; also runs in reverse.
- **A zero-downtime FK column swap** — `order_id` → `order_id_bigint` on integer
  overflow, `order_id` → `order_uuid`, or a plain rename.
- **Natural key → surrogate key** — `foreign_key: :country_code` becoming
  `foreign_key: :country_id`. Plain legacy cleanup, nothing distributed. Good case
  to lead with if the audience thinks this is infrastructure exotica.
- **One codebase deployed single-tenant and multi-tenant** — the tenant column is
  in the keys in one deployment and not the other.
- **Engines and gems adapting to a host app's key structure** — best
  non-Shopify-shaped case.
- **Migrating to a store whose key requirements differ** — e.g. one that needs the
  partition key in every lookup. Phrase it this way, not "migrating between
  databases": switching stores is `connects_to`'s job and changes no keys.

The last two are permanent, not migrations. So the problem statement is *one
association, two key structures, picked at runtime* — mid-migration is the main
case, not the boundary.

---

## 2. The SchemaContext precedent

[#58437](https://github.com/rails/rails/pull/58437) (`SchemaContext`, **merged**) is
the same reviewers on the same problem, weeks earlier. They took the extraction and
dropped the switching:

> "Unlike the above PR, we no longer provide the ability to switch between schema
> contexts... Applications, including ours, can simply replace the default model
> context with a proxy which can handle swapping between contexts by overriding
> `build_schema_context`."

So:

1. **Rails owns the mechanism, the app owns the policy.** No adapter keys, no
   `Rails.configuration` reads inside Rails, no built-in resolver.
2. **Expect "why isn't this an app-level proxy reflection?"** The answer:
   `build_schema_context` worked as a seam because it was one method. Reflections
   are read all over Active Record — `join_dependency.rb`, `preloader/branch.rb`,
   autosave callbacks, `association_scope.rb`, the association cache at
   `associations.rb:52`. Getting resolution right in all of them means changes
   across roughly eight files. A proxy can't cover that reliably, which is why this
   seam belongs inside Active Record and SchemaContext's didn't.

---

## 3. Prior art

`reflection.rb` refs marked ★ are on the query-constraints branch (#58266), not main.

| Precedent | Location | What to borrow |
|---|---|---|
| **ActiveStorage `service:`** | `active_storage/attached/model.rb:90`, Proc resolved at `changes/create_one.rb:117` | An association option taking a symbol or callable, resolved at use time |
| **`config.active_record.shard_resolver`** | `middleware/shard_selector.rb:23` | One app-level resolver lambda, not N call sites. It takes `request` because the shard depends on it; for variants the ambient state is global, so there's nothing to pass |
| **`connects_to` / `connected_to`** | `connection_handling.rb:81`, `:140` | Named map declared once; block-scoped selection |
| **Template variants** | `actionview/.../lookup_context.rb:54` | "Variant" already means: ambient context picks among named alternatives, with a fallback |
| **Instance-dependent scopes** | `reflection.rb:722` | Callables in association macros — and precedent for limiting what they may do |
---

## 4. The API

### 4.1 The base association is the default variant

Write the association as you write one today. `variants:` adds named alternatives
next to it. Available on `belongs_to`, `has_one`, `has_many`,
`has_and_belongs_to_many`.

```ruby
class LineItem < ApplicationRecord
  belongs_to :order,
    inverse_of: :line_items,
    autosave: false,
    variants: {
      yugabyte: { primary_key: :id, foreign_key: :order_id, query_constraints: :shop_id },
    }
end
```

The base is reachable as `:default` (§4.3).

Rejected: a symmetric map where every variant is named and the first is the
default. Adding `variants:` then only stays a no-op *if the first entry matches
today's shape* — something you'd verify ~200 times, enforced by hash literal order.
Here adding `variants:` can't change behaviour, because current behaviour *is* the
base declaration. The enabling diff never touches an existing option, and rollback
is deleting one key.

An option rather than parallel `*_with_variants` macros, for two reasons: Rails
extends existing macros, and `has_many` / `has_and_belongs_to_many` already use
their block for the extension module — so a resolver block would collide on exactly
the two macros that have one. An option also lets `with_options` work (§4.7).

### 4.2 Where options live

- **Base only** — anything behavioural or callback-installing: `inverse_of`,
  `autosave`, `dependent`, `validate`, `counter_cache`, `touch`, `optional`,
  `default`, `polymorphic`, `before_add` / `after_add` / `before_remove` /
  `after_remove`, `deprecated`. Declaring one inside a variant raises.
- **Base or variant** — key-shaping: `primary_key`, `foreign_key`,
  `query_constraints`.

An allowlist of three, not a blocklist of a dozen. Behaviour and callbacks can't
vary per variant, so there's no long list of options that must be kept identical.

**Variants replace, they don't merge.** A variant states its whole key spec; base
key options aren't inherited. That's why the example above restates
`primary_key: :id, foreign_key: :order_id` even though both are conventional.

Merge semantics (`yugabyte: { query_constraints: :shop_id }` as a delta) would be
shorter, but breaks the cleanup script in §8 — you couldn't tell which merged keys
to write out and which came from convention.

### 4.3 Selection

Rails ships no policy and no default resolver. The resolver reads ambient state and
returns one variant name for the whole process.

```ruby
# config/application.rb
config.active_record.association_context_resolver = lambda do
  Rails.configuration.platform_essentials.yugabyte_testing? ? :yugabyte : :default
end
```

**Variant names are a shared vocabulary.** One returned name applies to every
association, so `:yugabyte` has to mean the same shape in every model that declares
it. That's a real constraint, and the right one — an app doesn't run two key
migrations at once, and it wouldn't want to handle the permutations if it did.

Staged rollout doesn't need per-association selection anyway. **Which models declare
`variants:` is the rollout.** The resolver returns `:yugabyte` from day one; an
association that hasn't been converted has no `:yugabyte` variant and falls back to
base (below). You convert models one at a time without touching config.

Two things fall outside the vocabulary: a gem that picked its own name (§7.5), and
one association you want held back while its siblings advance. Both are
per-association policy, and they belong at the declaration site (§6) — not in a
`case reflection.active_record.name` sitting in `application.rb`.

**Block override**, for tests and scripts:

```ruby
ActiveRecord::Base.with_association_variant(:default) do
  line_item.order   # ... WHERE orders.id = ?
end

ActiveRecord::Base.with_association_variant(:yugabyte) do
  line_item.order   # ... WHERE orders.id = ? AND orders.shop_id = ?
end
```

It's blunt: it applies to every association inside it, so it can't express two axes
at once, and nesting means the inner block wins and the outer selection is lost. Use
the resolver for anything real.

**`:default` is reserved** and always names the base. It can't be a key in
`variants:`.

A resolver returning `nil`, or a name the association doesn't declare, selects the
base. Falling back rather than raising is what makes a global resolver safe while
variants are still being added model by model.

Rejected: a `default_variant_name: :mysql` option letting each model label its base.
Adds an option to solve a naming preference, and nothing keeps the label spelled the
same across 200 declarations. `:default` is also more honest — across a fleet
mid-migration the base isn't uniformly "the MySQL shape," it's "whatever was there
before."

### 4.4 Call sites don't change

That's the point. `line_item.order`, `build_order`, `includes(:order)`,
`joins(:order)`, `order.line_items.create!` — all as written. Only the keys differ.

### 4.5 Reflection surface

```ruby
reflection = LineItem.reflect_on_association(:order)
reflection.variant?            # => true
reflection.variant_names       # => [:default, :yugabyte]
reflection.variant(:default)   # => the ordinary BelongsToReflection for the base
reflection.variant(:yugabyte)  # => the BelongsToReflection for that variant
reflection.foreign_key         # => delegates to the resolved variant
```

Non-variant associations return `false` and `[:default]`, so existing consumers are
unaffected. No `default_variant` accessor — the answer is always `:default`.

### 4.6 Errors

Ambient selection never raises on an unknown name (§4.3). Only direct lookup raises:

```
ArgumentError: LineItem#order has no :uuid variant; expected one of :default, :yugabyte

ArgumentError: :autosave cannot vary per variant; declare it on the association itself.
              Variants accept :primary_key, :foreign_key, :query_constraints.

ArgumentError: :default is reserved and names the base association;
              it cannot be a key in variants:.

ArgumentError: LineItem#order declares variants: and LineItem declares
              self.query_constraints; the base association must state :foreign_key
              explicitly. (see §5)
```

`variants: {}` and no `variants:` are the same thing: an ordinary association.

### 4.7 `with_options`

Works already, no grouping macro needed:

```ruby
with_options variants: { yugabyte: { query_constraints: :shop_id } } do |m|
  m.belongs_to :order, inverse_of: :line_items
  m.has_many :adjustments, dependent: :destroy
end
```

Only helps when the variant differs by a shared column. Because variants replace
rather than merge (§4.2), a variant needing its own `foreign_key` can't be shared.

---

## 5. The derivation hazard (important)

The base isn't a fixed option set — it's a function of *model-level*
`query_constraints`. On the query-constraints branch, `reflection.rb:616` ★:

```ruby
if !options[:query_constraints] && !derived_fk.is_a?(Array) && active_record.has_query_constraints?
  derived_fk = derive_fk_query_constraints(derived_fk)
end
```

If `LineItem` declares `self.query_constraints = [:shop_id, :id]` and an association
omits `foreign_key`, the derived key expands to `["shop_id", "order_id"]` — silently
the Yugabyte shape. Base and variant converge and the declaration stops controlling
the SQL.

**Explicit keys are the lever.** Once `options[:foreign_key]` is set, that branch is
unreachable. Requiring variants to state their keys in full (§4.2) handles the
variant side. This is why the explicit `foreign_key: :order_id` in the `:yugabyte`
variant matters — it pins the FK to a scalar instead of letting derivation build a
composite.

The base is still exposed, because §4.1 keeps it an ordinary association that
derives conventionally. So one rule:

> When an association declares `variants:` **and** its model declares
> `self.query_constraints`, the base must declare `foreign_key` explicitly.

Worth having anyway: a model whose derived FK is already composite has a base that's
already the sharded shape, and shipping that as the pre-migration default is the
exact failure this design exists to prevent.

---

## 6. Not in the first PR

- **Per-association `variant:` override** (symbol or callable, à la ActiveStorage
  `service:`). The escape hatch for the two cases the shared vocabulary doesn't
  cover (§4.3): a gem with its own variant names, and one association held back
  while its siblings advance. Purely additive later. Following `connected_to` the
  block should win over it, which makes "pin" the wrong word for it.
- **Adapter-derived selection** (`adapter:` keys). Bakes in one axis.
- **`class_name` in the key set.** Would let variants target different models — what
  a table split needs — but widens the blast radius and tangles with `inverse_of` at
  the top level.
- **`scope`.** Not a keyword, so not expressible per variant.
- **`through` / `source`.** All variants must be the same shape. State it as a rule,
  not a validator message.

---

## 7. Open questions

1. **Caching the resolver result.** Resolving on every `association(name)` access is
   too often. Since one name covers the whole process, this is a single memoized
   value per request and per `with_association_variant` block — not a per-association
   cache. Needs designing before review, not during.
2. **Statement cache keying.** Two variants generate different SQL under one
   association name. How does that interact with the statement caches just moved
   into `SchemaContext` (#58437)? Most likely question from Matthew.
3. **Mid-flight relations.** Dropping the cached association when the resolved
   variant changes (`associations.rb:52`) covers `line_item.order`, but a `Relation`
   already built from the old reflection stays live. Define the behaviour.
4. **`has_and_belongs_to_many`.** Needs a join model per variant. Generating and
   `const_set`ing one per variant is the obvious approach — confirm that's
   acceptable upstream, or drop habtm from the first PR.
5. **Variant names are the coordination mechanism** (§4.3), which makes gems awkward:
   the gem picks the name, the host writes the resolver, and one returned symbol has
   to satisfy both. Options: document a convention, reserve a generic name like
   `:next` meaning "the new shape," or lean on the per-association override (§6).
   Worth settling before the API is public — names become a compatibility surface.

---

## 8. End state

Both exits are mechanical, and asymmetric in the direction you want.

**Roll back** — delete `variants:`. The association is byte-for-byte what it was
before, because it was never edited.

**Roll forward** — delete the base's key options, lift the winning variant's keys
up, delete `variants:`:

```ruby
belongs_to :order,
  primary_key: :id, foreign_key: :order_id, query_constraints: :shop_id,
  inverse_of: :line_items, autosave: false
```

Behavioural options never moved, so nothing needs re-deriving. This is why variants
replace rather than merge (§4.2): with deltas you'd have to work out per association
which merged keys to promote and which convention already implied — times ~200
models. With complete variants it's a script.

---

## 9. PR sequencing

1. Land **#58266** (association `query_constraints`) first — it creates the generic
   need.
2. Pitch variants as *"how you adopt what we just merged, incrementally."* Avoids
   leading with the adapter migration.
3. Keep the first PR narrow: three key options, no `class_name`, no `scope`, no
   per-association override, possibly no habtm.
