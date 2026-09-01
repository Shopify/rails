# Implementation plan: adapter-specific association keys at runtime

Audience: an agent working in `world` (`areas/core/shopify`).

---

## Goal

Today a model gets Yugabyte-shaped association keys only if the whole app booted in
Yugabyte mode. We need one process to serve both shapes, chosen per request by the
active adapter, because cutover is per shop and we ship one app.

Concretely, this must work in one process:

```ruby
# request on a MySQL shop
line_item.product   # WHERE products.id = ?

# request on a Yugabyte shop
line_item.product   # WHERE products.shop_id = ? AND products.id = ?
```

---

## Read these first

You need to understand these before writing code.

| File | Why |
|---|---|
| `components/platform/essentials/lib/patches/active_record/schema_context_proxy.rb` | Defines `current_schema_context_key`, which returns `"default"` or `"yugabyte"`. This is the adapter selector every step below uses. |
| `components/platform/essentials/lib/podding/database/schema_context_proxy.rb` | The pattern to copy: hold one value per adapter key, pick on read. |
| `components/platform/essentials/lib/podding/database/concerns/sharded_table.rb` | Podded models override `current_schema_context_key` and cache it in `Podding::Current`. |
| `components/platform/essentials/app/models/concerns/yugabyte_associations.rb` | Where the shape is currently chosen and discarded at boot. |
| `components/platform/essentials/app/models/concerns/belongs_to_with_query_constraints.rb`, `has_many_with_query_constraints.rb`, `has_one_with_query_constraints.rb` | **All three.** They share how `{query_constraints:, primary_key:, foreign_key:}` maps onto Rails options, but each patches the association class differently, and `belongs_to` alone handles requiredness. Read all three before step 3. |
| `components/platform/essentials/lib/patches/active_record/association_reflection_writable_foreign_key.rb` | Already patches reflections. Needs updating in step 3. |
| `components/platform/essentials/lib/development_support/yugabyte_model_migration/AGENTS.md` and `README.md` | Existing tooling that parses and classifies these declarations. Reuse it in step 0. |

Rails is pinned to the fork branch `ac/august-16-plus-all-queries-scope-schema-context`,
which includes rails/rails#58437 (`SchemaContext`). Method names below are stable; line
numbers are hints only.

---

## Ground rules

1. **Do not edit the 2,352 `yugabyte_overrides:` declarations.** They already contain both
   shapes. The whole plan is about reading them later instead of at boot. (Renaming them is
   a separate decision — see "Escalate".)
2. **Put everything behind a new flag.** Until that flag is on, behaviour must be byte-for-byte
   what it is today. See step 1.
3. **Do not touch statement caches.** The `SchemaContextProxy` PR already gives each adapter
   its own `find_by_statement_cache_key`, and `association_scope_cache` routes through it.
   Association SQL is already separated. Adding more here would be wasted work.
4. **Reuse, don't reimplement.** Especially the option mapping in step 3 and the parser in
   step 0.

---

## Step 0 — Audit: which associations would break

**Why first.** Rails raises when it has to derive a foreign key from a query-constraints
list longer than two columns:

```
The query constraints list on the `X` model has more than 2 attributes.
Active Record is unable to derive the query constraints for the association.
```

`LineItem` declares three (`yugabyte_query_constraints :order_id, :id, :shop_id`). The raise
lives inside `AssociationReflection#foreign_key`, so it is **lazy** — it only fires the first
time such an association is used. The Yugabyte app booting successfully proves nothing. There
may be associations that would raise today and simply never run.

**What to do.** Do not write a new script. Use the existing pipeline in
`components/platform/essentials/lib/development_support/yugabyte_model_migration/`. Read its
`AGENTS.md` first. The pieces you want are `reflection_snapshot.rb`, `report_builder.rb`, and
`yugabyte_overrides_detector.rb` — the detector already classifies each declaration as
`:full`, `:partial`, `:testing_guard`, or `:none`.

Produce a report listing, for every model whose `declared_yugabyte_query_constraints` has more
than two columns, each association that is classified `:none` or `:partial` **and** has no
explicit `foreign_key:` option.

**Done when.** You have a written count and a file-by-file list. Each entry is either a missing
override or dead code.

**Then stop and report the number before continuing.** If the list is long, the real work is
writing overrides, not plumbing, and the rest of this plan should be resequenced.

---

## Step 1 — Add the runtime switching flag

**Goal.** Land all following steps as dead code, so nothing changes until we choose.

**What to do.** Add a config flag next to `yugabyte_testing?`, following whatever convention
`platform_essentials` already uses — something like
`Rails.configuration.platform_essentials.yugabyte_runtime_switching?`, defaulting to `false`.

Every behaviour change in steps 2 to 4 is guarded by it:

- flag off → today's behaviour exactly, including `yugabyte_testing?` still deciding at boot
- flag on → shape resolved per request from `current_schema_context_key`

**Watch out.** Do not reuse `yugabyte_testing?` for this. That flag means "this whole app is
Yugabyte", which is the thing we are replacing. Both must be readable independently during
the transition.

**Done when.** The flag exists, defaults off, and the full test suite is unchanged.

---

## Step 2 — Model query constraints

**Goal.** Make `query_constraints_list` and friends answer per adapter.

**Files.** New patch under `components/platform/essentials/lib/patches/active_record/`, plus an
edit to `yugabyte_associations.rb`.

**What to do.**

Prepend `ActiveRecord::Persistence::ClassMethods` and override three readers:

| Method | Today |
|---|---|
| `query_constraints_list` | returns `@query_constraints_list`, else falls back to `base_class` |
| `has_query_constraints?` | returns `@has_query_constraints` |
| `composite_query_constraints_list` | `@composite_query_constraints_list ||= ...` |

Each override: if the flag is on, the model has `declared_yugabyte_query_constraints`, and
`current_schema_context_key == "yugabyte"`, return the Yugabyte columns. Otherwise `super`.

`composite_query_constraints_list` memoizes, so replace the single variable with one value per
adapter key — same shape as `SchemaContextProxy`.

Then, in `yugabyte_associations.rb`, when the flag is on, `yugabyte_query_constraints` must
**stop calling `query_constraints`** and only record `declared_yugabyte_query_constraints`.

**Watch out.** That last point is easy to miss and silently wrong. `query_constraints(*cols)`
sets `@query_constraints_list`, which is what `super` returns. If it still runs, the MySQL path
gets Yugabyte columns.

**Also decide.** STI. `query_constraints_list` falls back to `base_class.query_constraints_list`,
and `inherited` clears the variables for subclasses. Decide whether a subclass inherits its
parent's Yugabyte columns, and write a test either way.

**Done when.** With the flag on, a model with `yugabyte_query_constraints` returns the Yugabyte
columns under a Yugabyte connection and the MySQL values under MySQL, in the same process.

**Do not ship step 2 alone with the flag on.** It breaks associations without step 3 — that is
exactly the >2-column raise from step 0. Landing the code is fine; enabling it is not.

---

## Step 3 — Association keys

**Goal.** One reflection object that answers key questions per adapter.

**Files.** `yugabyte_associations.rb`, all three `*_with_query_constraints` concerns, a new
reflection patch, and `association_reflection_writable_foreign_key.rb`.

This is the largest step. Read all three concerns before starting — they are not variations
on one file.

### 3a. Stop discarding the other shape

`YugabyteAssociations#belongs_to` currently does `options.delete(:yugabyte_overrides)` and
forwards only one option set. When the flag is on, let both reach the reflection so it can
choose later. Same for `has_many` and `has_one`.

### 3b. Extract the option mapping the three concerns share

There is one polyfill concern per macro:

| Concern | Entry point |
|---|---|
| `BelongsToWithQueryConstraints` | `belongs_to_with_query_constraints` |
| `HasManyWithQueryConstraints` | `has_many_with_query_constraints` |
| `HasOneWithQueryConstraints` | `has_one_with_query_constraints` |

All three do the same three things with a shape, and that part is worth extracting once:

- validate `(foreign_key - query_constraints).empty?` and raise otherwise
- call the real Rails macro with `foreign_key: query_constraints, primary_key: primary_key`
- set `reflection.writable_foreign_key = foreign_key`

Note the second point: Rails' `foreign_key` option receives the **full constraints array**,
not the narrow FK. The narrow FK only ever lives in `writable_foreign_key`. Getting these
backwards produces valid-looking but wrong SQL, so reuse the existing code rather than
re-deriving it.

Everything below differs per macro. Do not try to unify it.

### 3c. The declaration-time association subclass

Each concern builds an anonymous subclass of `reflection.association_class` and pins it:

```ruby
patched = Class.new(reflection.association_class) do
  # methods closing over nullify_columns / foreign_key / non_fk_constraint_cols
end
reflection.define_singleton_method(:association_class) { patched }
```

Two problems under runtime switching:

1. `association_class` returns one class regardless of which adapter is active.
2. The methods inside close over Yugabyte column arrays captured when the class body ran.
   Those values can never change.

The overridden methods differ per macro:

| Concern | Overrides |
|---|---|
| `belongs_to` | `replace_keys`, `stale_state` |
| `has_many` | `nullified_owner_attributes`, `foreign_key_present?` |
| `has_one` | `nullified_owner_attributes`, `nullify_owner_attributes`, `foreign_key_present?` |

Fix: build one subclass per shape and have `association_class` pick by
`current_schema_context_key`. Under MySQL it should return the **unpatched** class. These
patches exist only because Rails is being handed a composite foreign key it must not write
to, which is not the case on MySQL.

Free: `foreign_key_present?` in the `has_many` and `has_one` patches already reads
`reflection.active_record_primary_key` at call time, so it follows 3d on its own.

### 3d. Key the memoized values per adapter

Prepend **both** `ActiveRecord::Reflection::AssociationReflection` and
`ActiveRecord::Reflection::ThroughReflection`:

| Method | Note |
|---|---|
| `foreign_key(infer_from_inverse_of:)` | keep the keyword argument |
| `association_foreign_key` | habtm |
| `active_record_primary_key` | |
| `join_table` | habtm |
| `check_validity!` | caches `@validated`, so only the first adapter is ever checked |

Each stores one value per adapter key instead of one value total.

`association_primary_key` needs no work in its derived path — it is not memoized and already
follows the model values from step 2.

**Watch out.** `derive_foreign_key` calls `inverse_of.foreign_key(infer_from_inverse_of: false)`,
so your override can recurse into another reflection's override. Make sure that terminates and
that both sides agree on the adapter key.

### 3e. `writable_foreign_key`

The existing patch has two paths. The default path derives from `reflection.foreign_key` at call
time, so it follows 3d automatically — nothing to do. Two things do need changing:

- the explicitly set `@writable_foreign_key` (set in 3b) must become one value per adapter key
- the `Rails.configuration.platform_essentials.yugabyte_testing?` read inside it must become
  `current_schema_context_key == "yugabyte"` when the flag is on

### 3f. `belongs_to` requiredness

`belongs_to_with_query_constraints` does something the other two do not. It passes
`optional: true` to Rails to suppress Rails' own validator, restores
`reflection.options[:optional] = !required` afterwards, then installs its own presence
validator scoped to the narrow FK via `add_presence_validation(name, foreign_key)`.

`validates` is a permanent class-level callback, so it is installed once with one shape. But
its condition is a **lambda evaluated on every validation**, and it uses `fk_columns` only to
decide which columns to check. So the fix is small: have that lambda read the adapter-current
writable FK instead of closing over an array. Do not install two validators.

Also free: `save_belongs_to_association` — an instance method on the concern, not in
`ClassMethods` — already reads `reflection.writable_foreign_key` at save time, so it follows
3e on its own.

**Free, no work needed.** Rails' own autosave and counter cache read `reflection.foreign_key`
inside method bodies at save time, not when the association is declared. They follow the
adapter without help.

**Done when.** In one process, the same association emits MySQL-shaped SQL under a MySQL
connection and Yugabyte-shaped SQL under a Yugabyte connection, for `belongs_to`, `has_many`,
and `has_one`. Requiredness validation checks the narrow writable FK under both. Under
Yugabyte, `dependent: :nullify` still clears only the narrow FK and not the whole constraints
list; under MySQL it behaves exactly as it does today.

## Step 4 — Stale per-record caches

**Goal.** A record that outlives an adapter switch must not reuse the old shape.

**What to do.** Each record caches association objects in `@association_cache`
(`ActiveRecord::Associations#association`). Each cached association caches the scope it built
(cleared by `Association#reset_scope`). There is no public clear-all — the only resets are in
`init_internals` and `initialize_dup`, both private.

Store the adapter key on the association when it is built, and on read, reset it if the key has
changed. Prepend `association(name)` or `Association#reset_scope`, whichever is cheaper.

**Watch out.** `association(name)` is extremely hot. Benchmark it. The `SchemaContextProxy` PR
measured about 35 ns for its columns proxy and accepted that, so use the same bar and the same
benchmark harness (`script/benchmarks/schema_context_benchmark.rb` in that PR).

**Out of scope.** `Relation` objects held across a switch are not reachable this way. One request
is always one adapter, so we accept that. Note it, do not fix it.

**Done when.** A record loaded under MySQL and then used under a Yugabyte connection issues
Yugabyte-shaped SQL, and the benchmark shows no measurable request-level regression.

---

## Testing

Follow the pattern in
`components/platform/essentials/test/lib/patches/active_record/schema_context_proxy_test.rb`,
and check its sibling `association_reflection_writable_foreign_key_test.rb`. Discover the test
command from the component's CI config rather than guessing it.

Every test must exercise **both shapes in one process**. A test that only runs in Yugabyte mode
proves nothing here — that already works today.

Cover at least:

1. `belongs_to`, `has_many`, `has_one` each emitting both shapes, switching between them
2. a model with a three-column `yugabyte_query_constraints` (like `LineItem`)
3. switching adapters twice, to prove nothing is memoized after the first switch
4. `writable_foreign_key` and requiredness validation correct under both
5. `dependent: :nullify` on a `has_many` and a `has_one`, under both adapters — Yugabyte
   must clear only the narrow FK, MySQL must behave as it does today (this is the whole
   reason the association-class patches in 3c exist)
6. a record cached under one adapter then read under the other (step 4)
7. flag off → identical behaviour to today

---

## Escalate, don't decide

Stop and ask rather than choosing these yourself:

1. **`has_many :through` and `habtm`.** Through reflections read keys from three other
   reflections, and `join_table` is memoized. Not yet investigated. If step 0 or step 3 turns up
   a lot of these, say so before proceeding.
2. **Polymorphic associations.** `association_primary_key(klass)` takes the target class at call
   time, unlike everything else. Probably fine; confirm rather than assume.
3. **Renaming `yugabyte_overrides:`.** It bakes a vendor name into 2,352 call sites and can never
   go upstream in that form. Renaming is possible and cheapest before this lands, but it is a
   separate decision, not part of this work.
4. **Anything requiring a change to Rails itself.** Steps 2 and 4 need none. Step 3c touches
   private variables in `AssociationReflection`, which works as a prepend but is fragile — that
   is the piece we intend to upstream later as "memoized association keys should be stored per
   schema context". Do not fork Rails for it now.
