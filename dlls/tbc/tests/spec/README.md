# Project-derived lifetime specifications

These are implemented regressions and pending implementation targets for `tbc`.
They are reduced, compile-only C++23 examples based on `runtime-cpp`,
`gui-cpp`, and projects under `dlls/`. They do not include those projects or
require Qt, SQLite, FreeType, HarfBuzz, the protocol generators, or a running GUI.
The trusted stubs include proposed foreign-library contracts; these examples do
not independently validate those libraries' behavior.

Every negative example is intentionally valid C++ syntax. Never link or run these
fixtures: some contain dangling accesses, null risks, or uninitialized reads.
Other rejections express our proposed access policy rather than undefined
behavior in ordinary C++.

## Per-case contract

Each `CASE` / `END CASE` block contains:

| Field | Meaning |
| --- | --- |
| `CASE` | Stable, unique case identifier. |
| `PAIR` | A group containing both accepted and rejected examples of one obligation. A group may have more than two cases. |
| `SOURCE` | Existing project path and the symbol/pattern that motivated the reduction. This is provenance, not a claim that the source has a bug. |
| `STATUS` | `implemented` is a required regression test; `pending` is an unimplemented acceptance criterion. |
| `CONTRACT` | The lifetime, ownership, effect, or access promise being tested. |
| `SCENARIO` | What happens, why it is accepted/rejected, and where the primary diagnostic belongs. |

An inline `// expected-error [tbc-code]` requires exactly one error with that code
on that line. A block without markers requires **zero primary tbc diagnostics**.
Unexpected, missing, duplicated, or incorrectly located diagnostics fail strict
comparison. Notes are permitted but their wording and locations are not yet part
of the assertion. There is no message-substring match that can accidentally
accept a different rule's warning.

The corpus contains **216 cases in 105 groups**: 110 accepted and 106 rejected
examples. There are 170 implemented regressions and 46 explicitly pending
requirements. The original 58 cases are supplemented by 59 inference cases,
18 pointer and lambda cases, 29 standard-library cases, 12 third-party library
cases, 38 storage-place cases, and 2 system-macro cases.
A passing pending positive case does not establish support for its contract.

## Source inventory

| Fixture | Cases | Project evidence and intended distinction |
| --- | ---: | --- |
| `core.cpp` | 4 | Native references annotated with `tbc::view` and source-backed lexer tokens: direct and aliased returns. |
| `inference.cpp` | 59 | Native helper returns, aggregates, descriptor copies versus references, recursive summaries, constructors, receiver/output writes, default arguments, per-call substitution, explicit declaration contracts, and modeled helper invalidation. A cleared container drops its previous loans; a call result reads the receiver before that call overwrites it; receiver fields share a declared region with method results and retain arguments cumulatively. |
| `pointers.cpp` | 18 | `runtime-cpp` JSON nodes, agent manifests, hook settings, and server options, and `gui-cpp` session fixtures: reads and writes through pointers act on the pointee, a pointer parameter's pointee contents are a separate input, a by-value parameter is a local copy, and lambdas copy or reference their captures. |
| `standard_library.cpp` | 29 | `runtime-cpp`, `gui-cpp`, `desktop-mode`, and `dlls/ebnf` uses of `std::optional`, smart pointers, iterators, algorithms, `std::exchange`, `std::get_if`, maps, `std::function`, converting wrappers, initializer-list range loops, and moved owners. Views lend their referent, iterators their pointee, and owners their storage or a copy of their contents; a moved owner hands its object to the destination. |
| `system_library.cpp` | 12 | Qt uses in `gui-cpp` and `desktop-mode`: a library type with a trivial destructor is a view; an owner holds borrows only through its type arguments; a library container lends its storage and copies its elements; compiled library code and non-container owners' pointers are outside the analysis; constant-evaluated results borrow what their expression borrows. |
| `places.cpp` | 38 | `gui-cpp` session panes, launch arguments, and history queries, `runtime-cpp` plugin workers, JSON nodes, hook settings, HTTP/2 streams, workspace tabs, frame headers, observation results, and proxy slot callbacks, and `desktop-mode` controllers: a borrow reaches a level and a path of fields inside its variable. Growth moves element slots and whatever an element owns inline, such as a short string, but not objects owned through pointers; clearing destroys every level. Mutating a nested node, an owned object, or one field leaves its siblings, its parent, and the pointers that designate it valid, through returned references and callees too. An object's contents are held per field: assigning, clearing, or rebuilding one field replaces only what that field held, and an object's views of its own fields are invalidated with those fields. Assigning an object is not a use of what it held. Inside a lambda, `this` is the captured object, so a callback's field effects land in that object, not in the closure. A call uses only the parameters and receiver fields the called function reads, and a sequence container's structural operations do not read what its elements borrow. |
| `system_macros.cpp` | 2 | GoogleTest assertions in `dlls/ebnf/tests`: an expression spelled by a system macro cannot carry a project contract, while a project expression passed as a macro argument still can. |
| `ebnf.cpp` | 4 | `dlls/ebnf/parser.hpp`, `node`, `parse`, and `parseRule`: `string_view` text persists in recursively nested vectors of AST children. Moving/copying AST ownership does not deep-copy source text. |
| `runtime_buffers.cpp` | 8 | `memory/byte_queue.hpp`: growth can deallocate storage and compaction can change element identity. `memory/retained_stream.hpp::read` returns caller-destination storage, not receiver storage. Appended uninitialized bytes require writes before reads. |
| `runtime_sqlite.cpp` | 6 | `history/database.cpp`: `Statement::text` exposes `sqlite3_column_text`, `next` steps, `reset` resets, destruction finalizes, and text/blob bind uses `SQLITE_TRANSIENT`. `history/result_rows.hpp` copies text before retaining rows. |
| `runtime_ownership.cpp` | 6 | `memory/allocator.hpp`: `AllocationDeleter` retains an allocator pointer used during destruction; `Owned` is a custom-deleter unique pointer. `platform/request_queue.hpp::take` moves the value and resets the old optional slot. |
| `gui_fonts.cpp` | 7 | `fonts/face.hpp/.cpp`: a foreign font face retains its font bytes; `shape` resets the HarfBuzz buffer and exposes glyph arrays; `rasterize` reuses the FreeType glyph slot. Copying values differs from retaining those views. Distinct faces have distinct scratch resources. |
| `gui_history.cpp` | 4 | `history/page_storage.hpp`: decoded text is copied into owned strings; compatible row-vector swaps transfer allocation ownership rather than destroying elements. A view follows the transferred storage's new owner. |
| `callbacks.cpp` | 7 | GUI machine-profile workers use owning request fields; runtime `OwnedPathQuery::assign` copies root/query text. Compare retained captures with synchronous layout callbacks and context-bounded queued invocation in `qt/window_images.cpp`. A lifetime guard for one context does not protect unrelated captures. |
| `contracts.cpp` | 4 | Contrast a result tied to region `a` with an independent `b` input, and a function allowed to return either of two `a` inputs. Retain the modeled/unmodeled call-boundary requirements. |
| `control_flow.cpp` | 4 | Conditional ByteQueue growth and allocator cleanup during exceptions motivate CFG-sensitive checks. One invalidating path is enough if it reaches a use; an early return or an owned copy can remove the conflict. |
| `access_validity.cpp` | 4 | Glyph bitmap row slicing and allocator null checks motivate bounds/nullability requirements in addition to borrow lifetimes. Unproven bounds are not a claim that every runtime index is actually invalid. |

### Deliberate reductions and preconditions

These are adaptations, not verbatim production APIs. For example,
`spec::retained_stream::read` omits the irrelevant stream offset, `font_face`
returns a span of simplified glyph values, and all modeled history pages use
compatible allocators. Actual font parsing, SQL execution, queue emptiness,
allocation contents, and thread scheduling are not exercised.

A modeled potentially invalidating operation is conservative. `ByteQueue::reserve`
only reallocates if capacity is insufficient; a future checker can accept a
proven no-op reservation. The negative example deliberately supplies no such
capacity proof. The compaction example similarly models the path that actually
compacts, not a guarantee that every call must move bytes.

The history swap model refers to vector row allocations. It does **not** assert
that every string-view into an arbitrary small-string-optimized command buffer
survives every swap. The actual operation's allocator checks and the exact
referenced resource remain part of the contract.

The linter detects invalid memory uses, not aliasing. Two overlapping mutable
references are legal C++, so Rust's exclusive-access rules are not a target.
The former shared/exclusive loan cases are kept outside the corpus in
`excluded/aliasing.cpp` for reference.

## Lifetime syntax in the examples

Examples use [`include/tbc/view.hpp`](../../include/tbc/view.hpp), documented in
[`docs/contracts.md`](../../docs/contracts.md). There are no macros, external
traits, or strings naming parameters. `support.hpp` defines reusable aliases:

```cpp
using text_a = tbc::view<std::string_view, tbc::lt::a>;
using text_b = tbc::view<std::string_view, tbc::lt::b>;
```

The main contrast in `contracts.cpp` is now visible in the signature:

```cpp
text_a wrongReturnOrigin(text_a source, text_b other) {
  return other; // Expected linter error: no b-outlives-a relationship.
}

text_a correctReturnOrigin(text_a first, text_a second) {
  return first.size() > second.size() ? first : second;
}
```

Sharing `a` allows either input to be returned; it does not identify an allocation
or require identical owner lifetimes. Regions must be instantiated per call.
Using `b` declares an independent variable, not an automatic outlives bound.

`core.alias_argument` also shows elision without any explicit label:

```cpp
tbc::view<const int &> aliasArgument(tbc::view<const int &> input) {
  const auto &alias = input;
  return alias;
}
```

The intended elision rule links the single borrowed input to the borrowed
result. In `runtime_buffers.cpp`, explicit `a` links the output to destination
bytes while `b` can describe the stream receiver. In `ebnf.cpp`, an aggregate
result annotated with `a` carries source-dependent views through nested nodes.
The owning-copy counterparts return ordinary owning C++ types instead.

`view<T, region>` is an alias for `T`. Calls and native methods remain ordinary
C++; compiler acceptance does not prove the lifetime relationship. The aliases
remain available in Clang's spelled types before canonicalization. Inference,
explicit return-region checks, and supported elision are implemented. Explicit
outlives bounds and the other pending effects are not.

### Operation effects are still requirements, not a finished interface

A lifetime label cannot alone express that a method reallocates, a callback is
retained, or a destructor consults an allocator. Those requirements remain in
`CONTRACT` and `SCENARIO`, with the same expected diagnostics and pending states.
Opaque helper declarations are not silently trusted just because their types
are annotated. They still need analyzable bodies or a separately designed
boundary/effect model.

The observer is a visible non-retaining helper with a borrowed-reference
parameter. Its stub does not traverse aggregate contents. Deep-use, invalidation,
initialization, and foreign-boundary interpretation remain acceptance targets,
not functionality smuggled in through a private annotation language.

## Diagnostics

| Code | Required rejection |
| --- | --- |
| `tbc-dangling-borrow` | An escaping or retained dependency outlives its source storage. |
| `tbc-invalidated-borrow` | An operation destroys, replaces, reuses, or invalidates storage whose old view is still required. |
| `tbc-uninitialized-read` | Read access occurs before required initialization. |
| `tbc-destructor-dependency` | An owner/deleter can outlive a resource it requires during destruction. |
| `tbc-escaping-capture` | Deferred retained captures cannot satisfy their referents' lifetime requirements. |
| `tbc-contract-violation` | A checked implementation does not implement its declared lifetime/effect contract. |
| `tbc-missing-contract` | A borrow-sensitive call has neither an analyzable body nor an explicit trusted effect contract. |
| `tbc-unproven-bounds` | The safe profile cannot establish an indexed access's bounds. |
| `tbc-nullable-dereference` | Dereference without a required non-null proof. |

`tbc-dangling-borrow`, `tbc-invalidated-borrow`, `tbc-contract-violation`, and
`tbc-missing-contract` have implemented regressions. `tbc-ambiguous-lifetime`
is also emitted for ambiguous declaration-only elision. The remaining names
are pending acceptance criteria, not claims of implemented checks.

## Running the corpus

From `dlls/tbc`, after configuring and building Debug:

```sh
ctest --preset debug -L spec
```

The default suite separates three obligations:

1. `tbc-spec-runner` tests the parser and exact diagnostic comparator, including
   missing/duplicate/wrong-location errors and false positives on accepted cases.
2. `tbc-spec-validate` validates metadata, unique IDs, provenance paths,
   positive/negative pairing, and C++23 syntax for every fixture.
3. `tbc-spec-implemented` requires exact behavior for cases explicitly marked
   implemented. It does not promote pending cases to successes.

Syntax checking uses the configured compiler and SDK. Analysis uses the built
`tbc-lint`, with compiler-provided stack-address warnings disabled so they cannot
substitute for our own diagnostics. The linter's error limit is disabled so files
with more than 20 expected errors can be compared exactly. Sources are never
linked or executed. A
compiler error, linter crash, timeout, unassigned tbc diagnostic, or wrong error
severity is a harness failure, not an expected pending result.

To exercise **all desired diagnostics**, including pending cases:

```sh
cmake --build --preset debug --target spec-check
```

This target is intentionally red until every expected behavior is implemented.
It prints missing and unexpected diagnostics separately, using exact source
lines and codes. Do not mark the whole target `WILL_FAIL`, invert its exit code
in CI, or blanket-update expected output to make it green.

To work on one group without requiring other features:

```sh
python3 tests/spec_runner.py \
  --compiler clang++ \
  --linter out/debug/tbc-lint \
  --mode all --case 'gui.shape_*'
```

On macOS, add `--sysroot "$(xcrun --sdk macosx --show-sdk-path)"` when needed.
The runner still analyzes the containing translation units, but compares only
selected cases. A case pattern matching nothing is an error.

When a contract is implemented, run both accepted and rejected cases in strict
mode, then change their `STATUS` to `implemented`. Syntax validity and a missing
warning on the negative case are not implementation success.

### Remaining gap

The alias-return, explicit return-origin, and source-backed AST groups now have
paired implemented regressions. `inference.cpp` exercises automatic contracts
with no return annotations, including retained and escaping variants.

Strict mode still fails on pending access-policy checks, foreign scratch-buffer
invalidation, callback retention, allocator dependencies, and other unimplemented
requirements. Matching pending positive cases is not evidence those features
work. Promote a pair only after both its acceptance and exact rejection checks
pass.
