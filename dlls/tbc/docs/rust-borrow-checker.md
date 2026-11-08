# Rust borrow checker rules

## Scope and evidence

This is a rule catalog for studying Rust's borrow checker and designing `tbc`.
The `BC-*` identifiers are local to this document, not official Rust rule names.
They do not imply that `tbc` implements these checks.

Baseline:

- Compiler: Rust **1.93.1**, commit
  `01f6ddf7588f42ae2d7eb0a2f21d44e8e96674cf`.
- Edition: **2024**, unless an edition difference is stated.
- Language sources: the Reference, standard-library documentation, and
  Rustonomicon distributed with that toolchain. Links below select version 1.93.1.
- Implementation sources: the compiler at that commit. The rustc development
  guide is supplementary, unversioned documentation, consulted on 2026-10-30.

There is no authoritative, finite list of every borrow-checker rule that also
fully specifies Rust's memory safety. The Reference explicitly says that the
memory model is incomplete and that the exact pointer-aliasing rules are not
fully determined. This catalog covers the documented rule families, their
important exceptions, and the implementation boundaries. It is not a formal
specification or a claim to enumerate every compiler special case. [R1] [R2]

Keep these layers separate:

| Layer | Responsibility |
| --- | --- |
| Ownership and move analysis | Initialization, moves, partial moves, and which places still contain values. |
| Borrow checking | Conflicting accesses to borrowed places and whether loans remain valid at each program point. |
| Type and lifetime checking | Reference types, mutability, lifetime relationships, variance, higher-ranked bounds, and function contracts. |
| Drop checking | Which borrowed data must remain valid when destruction can access it. |
| Library contracts | `RefCell`, `Send`, `Sync`, `Pin`, smart pointers, and unsafe abstractions. |
| Runtime validity | Whether references and accesses actually satisfy Rust's validity and aliasing obligations, including in unsafe code. |

Some diagnostics described here originate in type checking, not the MIR borrow
checker. They are included because a lifetime analyzer must account for their
constraints instead of treating them as unrelated rules.

## Vocabulary

- A **place** denotes storage, such as `x`, `x.field`, `*reference`, or
  `array[index]`. A value is what that storage contains. [R3]
- A **move** transfers a non-`Copy` value out of a place and deinitializes the
  relevant source place. It is not a C++ move constructor. [R3]
- A **loan** records permission obtained by borrowing a place. A reference value
  carries access to borrowed storage; copying a shared reference does not create
  another owned referent.
- A **region**, also called a lifetime in this context, describes where a borrow
  must be valid. In MIR analysis it is not simply a source-code brace range. [I1]
- An **overlap** means that accessing one place can affect storage protected by
  a loan of the other. Separate variable names do not establish disjointness.
- A **reborrow** borrows through an existing reference, for example `&mut *r`.
- **Use-live** means a value may be used later. **Drop-live** means it may be
  dropped later. These impose different lifetime requirements. [I3]

## 1. Initialization, ownership, and moves

### BC-01. Initialize before use

A local must be initialized on every reachable control-flow path before its
value is read, moved, or borrowed as an initialized value. A declaration alone
is not initialization. Branch joins and loop backedges matter. [R4] [I1]

```rust,compile_fail,E0381
fn main() {
    let value: String;
    if std::hint::black_box(true) {
        value = String::from("ready");
    }
    println!("{value}");
}
```

### BC-02. An immutable binding cannot be reassigned after initialization

A binding can be initialized later, but a second assignment requires a mutable
place. Analyzing a loop must account for the possibility of repeated assignments.
Binding mutability and the mutability of a referenced object are distinct. [R3]
[R4]

### BC-03. A moved place cannot be used until reinitialized

Moving a non-`Copy` value deinitializes its source. It cannot be moved twice,
read, or borrowed again until a permitted assignment reinitializes that place.
Passing an owned argument and returning an owned value can perform moves. [R3]

```rust,compile_fail,E0382
fn main() {
    let first = String::from("owned");
    let second = first;
    println!("{first} {second}");
}
```

### BC-04. Copying is not moving

A value-context use of a `Copy` type copies instead of deinitializing its source.
Shared references are `Copy`; mutable references are not. A `Clone` operation is
an explicit library call and does not change these implicit-move rules.
Non-`Copy` mutable references can still be implicitly reborrowed in appropriate
expression contexts. [R3] [R5] [I2]

### BC-05. Track partial moves at the place level

Moving one field can leave disjoint fields usable. The entire aggregate is no
longer usable as an initialized whole until its moved parts are restored.
Destruction only drops the initialized parts. A field cannot be moved out of a
value whose type implements `Drop`. [R3] [R6]

```rust
fn main() {
    let pair = (String::from("left"), String::from("right"));
    let left = pair.0;
    println!("{left} {}", pair.1);
}
```

### BC-06. Do not move an owner or overlapping storage while borrowed

An active borrow prevents moving its borrowed place or an overlapping owner.
This includes moves caused by calls such as `drop(owner)`. Putting the referent
on the heap does not by itself make moving or dropping its owner legal while
that owner is borrowed. [R3] [I1] [I4]

```rust,compile_fail,E0505
fn main() {
    let owner = String::from("borrowed");
    let reference = &owner;
    drop(owner);
    println!("{reference}");
}
```

### BC-07. Do not move a non-Copy value out of borrowed storage

Dereferencing `&T` or `&mut T` does not transfer ownership of a non-`Copy` `T`.
The Reference restricts movable places to eligible locals, temporaries, eligible
fields, and eligible `Box<T>` dereferences. Arbitrary indexing and arbitrary
`Deref` implementations do not grant move-out permission. `mem::replace`,
`mem::take`, and `Option::take` work through APIs that leave valid replacement
storage, subject to their own bounds. [R3] [R7]

### BC-08. Replacement and destruction are accesses too

Assignment, replacement, destruction, and ending a local's storage can invalidate
a referent. They must be checked against outstanding loans, not just explicit
reads, writes, and `&mut` expressions. The implementation distinguishes access
depths and destruction of owners from access to their referents. [R6] [I4]

## 2. Shared and exclusive access

### BC-09. Shared borrows can coexist

Multiple `&T` loans of overlapping storage may be live together. Reads and
further shared borrows are permitted through compatible access paths. [R5] [R8]

### BC-10. An active mutable borrow excludes conflicting borrows

A live, active `&mut T` loan excludes independent shared or mutable borrows of
overlapping storage. This does not prohibit valid reborrows through that
reference or simultaneous mutable borrows of disjoint fields. Two-phase
reservations are a separate case described below. [R8] [I2] [I4]

```rust,compile_fail,E0499
fn main() {
    let mut value = 0;
    let first = &mut value;
    let second = &mut value;
    println!("{first} {second}");
}
```

### BC-11. Exclusivity also excludes independent reads

While an overlapping mutable loan is active, an independent access through the
original owner or another access path is not permitted. A read is not harmless
merely because it does not change the bytes. Access through the active borrow
and permitted derivations of it remains possible. [R8] [I4]

```rust,compile_fail,E0502
fn main() {
    let mut value = 0;
    let reference = &mut value;
    println!("{value}");
    *reference += 1;
}
```

### BC-12. Shared borrows prohibit conflicting mutation

A live shared borrow prevents mutation of overlapping protected storage,
including replacement. The interior of an `UnsafeCell` is the explicit
exception, not an exception for the entire containing object. [R5] [R9]

```rust,compile_fail,E0506
fn main() {
    let mut value = 1;
    let reference = &value;
    value = 2;
    println!("{reference}");
}
```

### BC-13. Mutable access requires a mutable place, not always a mut binding

`&mut place`, assignment, implicit mutable borrows, and `ref mut` require mutable
access to that place. An immutable binding of type `&mut T` can mutate `T` through
its dereference. `mut reference` additionally permits rebinding the reference
variable. Conversely, `mut reference: &T` does not permit mutating `T`. [R3]

```rust
fn main() {
    let mut value = 1;
    let reference = &mut value;
    *reference = 2;
    assert_eq!(value, 2);
}
```

### BC-14. Borrowed storage must remain valid for the required region

A reference cannot outlive the storage and initialized value it refers to.
Returning a reference to a non-promoted local, storing it in a longer-lived
object, or passing it to an API that retains it all impose this obligation.
A lifetime annotation describes a relationship; it does not extend storage
lifetime, allocate storage, or prevent destruction. [R5] [R10] [I1]

```rust,compile_fail,E0515
fn invalid<'a>() -> &'a str {
    let local = String::from("temporary");
    &local
}

fn main() {}
```

### BC-15. Mutability cannot be upgraded through a shared reference

Safe code cannot obtain an independent `&mut T` to ordinary protected data from
`&T`. An `&mut T` can be reborrowed as `&T`, with shared-access restrictions during
the reborrow. Interior-mutability APIs do not grant arbitrary overlapping mutable
references. [R5] [R9] [R11]

## 3. Non-lexical lifetimes and control flow

### BC-16. A borrow need not last until the closing brace

Non-lexical lifetimes derive required validity from the control-flow graph and
uses, including destruction when relevant. A borrow can end after its final
required use while the reference variable remains in scope. Conversely, a last
explicit use is not always the end if a destructor can still access the borrow.
[R6] [I1] [I3]

```rust
fn main() {
    let mut text = String::from("first");
    let reference = &text;
    println!("{reference}");
    text.push_str(" second");
}
```

### BC-17. Analyze all relevant paths, including loop backedges

A conflict must be absent on paths where the loan is required. An earlier loop
iteration can retain a borrow into the next iteration. A condition, return,
break, or match arm affects the analysis, but borrow checking is not an arbitrary
proof of application-specific predicates. Sound programs can still be rejected
when the implementation cannot prove the required distinctions. [R4] [I1]

```rust,compile_fail,E0499
fn main() {
    let mut value = 0;
    let mut references = Vec::new();
    for _ in 0..2 {
        references.push(&mut value);
    }
    println!("{references:?}");
}
```

### BC-18. A reference's required lifetime follows its uses and contracts

Copying a shared reference, returning it, capturing it, placing it in a container,
or converting it to a compatible reference type propagates constraints.
Reassigning or shadowing a local reference name does not erase other retained
references or prove that the original loan has ended. Ending a loan is not a
runtime instruction that invalidates all aliases. [R3] [R10] [I1]

## 4. Reborrowing and two-phase borrows

### BC-19. A reborrow derives permission from its parent

`&*r` and `&mut *r` borrow through an existing reference. A mutable reborrow
requires mutable access to the referent. Its required lifetime cannot exceed
the permission from which it is derived. Parent access that conflicts with the
child loan is unavailable while that loan is required. [R8] [I1]

```rust
fn main() {
    let mut value = 0;
    let parent = &mut value;
    let child = &mut *parent;
    *child += 1;
    *parent += 1;
    assert_eq!(value, 2);
}
```

### BC-20. Reborrowing is context-dependent

Passing an `&mut T` to an expression expecting `&mut T` can reborrow it instead of
moving the reference. Do not treat every use of a mutable reference as either an
unconditional move or an unconditional reborrow. Expected types, coercions,
method autoref, and MIR lowering determine the operation. An explicit
`&mut *reference` makes the derived borrow visible in source. [R12] [I2]

### BC-21. Only selected implicit mutable borrows are two-phase

The implementation supports two-phase borrowing for mutable method-receiver
autoref, mutable reborrows in function arguments, and implicit mutable borrows in
overloaded compound assignment. A source-level `&mut` or `ref mut` is not itself
a two-phase borrow. A reservation initially behaves like a shared borrow and
later becomes exclusive at activation. [I2]

```rust
fn main() {
    let mut values = vec![1usize];
    values.push(values.len());
}
```

The explicit mutable borrow below does not receive that treatment:

```rust,compile_fail,E0502
fn main() {
    let mut values = vec![1usize];
    Vec::push(&mut values, values.len());
}
```

### BC-22. Reservation and activation have distinct conflict checks

Reservation conflicts with an incompatible mutable loan. Shared accesses can
occur before activation. Activation requires that other conflicting loans are
no longer live; after activation, ordinary mutable-borrow restrictions apply.
Two-phase borrowing does not make a retained reference into a vector compatible
with mutating that vector. [I2] [I4]

The development guide mentions an old reservation-time lint for shared loans.
The pinned compiler's conflict table explicitly allows a reservation against a
shared loan and notes the removed future-compatibility warning. Use the pinned
implementation, not that stale guide sentence, for this detail. [I4]

## 5. Places, overlap, and access precision

### BC-23. Disjoint struct and tuple fields can be borrowed independently

The checker can distinguish non-overlapping projections into ordinary structs
and tuples. It can permit multiple mutable borrows of separate fields, or a
partial move of one field while another is borrowed. [R3] [R13]

```rust
fn main() {
    let mut pair = (1, 2);
    let first = &mut pair.0;
    let second = &mut pair.1;
    *first += 1;
    *second += 1;
}
```

### BC-24. Borrowing a field can conflict with accessing the whole owner

A whole-aggregate access can overlap all of its fields. A method call with
`&mut self` borrows the receiver according to its signature, even if its body
happens to mutate a different field. Separate access paths do not make
same-storage accesses independent. Borrowing a pointer's storage and borrowing
its pointee are also distinct operations. [R3] [I4]

### BC-25. Arbitrary index expressions do not prove disjointness

Two index operations into an array, slice, vector, or custom container are not
generally accepted as independent mutable loans merely because their indices
look different. The checker is not a general integer or container-key theorem
prover. [R13]

```rust,compile_fail,E0499
fn main() {
    let mut values = [1, 2];
    let first = &mut values[0];
    let second = &mut values[1];
    println!("{first} {second}");
}
```

### BC-26. Destructuring and splitting APIs can establish disjoint access

Array/slice patterns can expose distinct elements or regions. APIs such as
`split_at_mut` return disjoint mutable slices under a safe contract, with any
necessary unsafe reasoning encapsulated in their implementations. Do not
confuse pattern-based disjointness with arbitrary indexing. [R13] [R14]

```rust
fn main() {
    let mut values = [1, 2, 3];
    let (left, right) = values.split_at_mut(1);
    left[0] += 1;
    right[0] += 1;

    let [first, second, ..] = &mut values;
    *first += 1;
    *second += 1;
}
```

### BC-27. Deref and indexing overloads obey their borrowing signatures

User-defined `Deref`, `DerefMut`, `Index`, and `IndexMut` operations are calls
with reference-based contracts. A checker must account for their implicit
borrows rather than assume that they expose builtin field-level separation.
`Box<T>` has language-recognized behavior that arbitrary smart pointers do not
inherit. [R7] [R8] [R12]

### BC-28. Union fields overlap

Different fields of a union share storage. Naming different union fields does
not justify simultaneous incompatible borrows. Unsafe union access also does
not remove reference validity obligations. [R2] [R15]

### BC-29. Packed fields cannot create potentially unaligned references

A reference must satisfy its pointee's alignment. Taking a reference to a
potentially unaligned `repr(packed)` field is rejected, even in an unsafe block.
An appropriate raw-address operation avoids creating that invalid reference;
it does not make a later misaligned reference valid. [R2] [R8]

```rust,compile_fail,E0793
#[repr(packed)]
struct Packed {
    first: u8,
    second: u32,
}

fn main() {
    let packed = Packed { first: 0, second: 1 };
    let reference = &packed.second;
    println!("{reference}");
}
```

### BC-30. Evaluation order and implicit accesses count

Borrows inserted by method calls, operators, formatting, pattern matching,
coercions, and temporaries participate in the same analysis as explicit borrows.
An expression cannot be judged only from its final result type. The legality of
nested calls can depend on when arguments are evaluated and when a receiver
borrow activates. [R3] [R8] [R12] [I2]

## 6. Lifetime contracts and types

### BC-31. Outlives constraints are directional

`'a: 'b` means `'a` lasts at least as long as `'b`. It permits a reference valid
for `'a` to be used for `'b` when the surrounding type's variance permits it.
It does not mean that `'a` and `'b` are identical. Constraints compose
transitively. [R10] [R16]

```rust
fn shorten<'long: 'short, 'short>(value: &'long str) -> &'short str {
    value
}

fn main() {}
```

### BC-32. T: 'a constrains embedded lifetimes, not the value's drop time

`T: 'a` requires the lifetime parameters of `T` to satisfy the outlives bound.
`T: 'static` does not mean every value of `T` must be stored forever. An owned
`String` can satisfy it and still be dropped immediately. `&'static T`, by
contrast, is a reference with a `'static` validity contract. [R10]

```rust
fn consume<T: 'static>(value: T) {
    drop(value);
}

fn main() {
    consume(String::from("owned, not immortal"));
}
```

### BC-33. Generic function bodies must honor their declared contracts

A function must be valid for its allowed lifetime instantiations. It cannot
return an input reference with an unrelated longer output lifetime. Bounds
from signatures and implied well-formedness are available inside the body;
callers must satisfy the resulting obligations. Borrow checking is not
permission to infer a different public contract from one convenient call site.
[R10] [I1]

```rust,compile_fail
fn unrelated<'a, 'b>(value: &'a str) -> &'b str {
    value
}

fn main() {}
```

### BC-34. Well-formed reference types imply lifetime bounds

A type such as `&'a T` requires `T: 'a`. Some lifetime bounds are implied by
function inputs, outputs, type definitions, and impl headers. Arbitrary trait
bounds are not inferred merely because the lifetime bounds are. [R10]

### BC-35. Higher-ranked lifetimes are universally quantified

`for<'a>` requires the relevant contract for every allowed `'a`, not one selected
lifetime such as `'static`. A function accepting only `&'static T` cannot stand
in for one that must accept references of arbitrary lifetimes. Inference must
not leak placeholder lifetimes into regions that cannot name them. [R10] [R16]
[I1]

### BC-36. Apply the full variance rules

Lifetime shortening is constrained by the containing type, not just the spelling
of a lifetime parameter. [R16]

| Type | Variance in `'a` | Variance in `T` |
| --- | --- | --- |
| `&'a T` | Covariant | Covariant |
| `&'a mut T` | Covariant | Invariant |
| `*const T` | Not applicable | Covariant |
| `*mut T` | Not applicable | Invariant |
| `[T]`, `[T; N]` | Not applicable | Covariant |
| `fn() -> T` | Not applicable | Covariant |
| `fn(T)` | Not applicable | Contravariant |
| `UnsafeCell<T>` | Not applicable | Invariant |
| `PhantomData<T>` | Not applicable | Covariant |
| `dyn Trait<T> + 'a` | Covariant | Invariant |

Composite-type variance follows the positions of its fields. Mixed co- and
contravariant uses can make a parameter invariant. In particular, invariance in
`T` of `&mut T` prevents writing a shorter-lived reference into storage that
promises a longer-lived one. It does not make the outer lifetime of every
`&mut` invariant.

### BC-37. Elision supplies contracts; it does not bypass checking

Function and method signatures use these rules. [R17]

1. Each elided input lifetime becomes a distinct parameter.
2. If exactly one lifetime occurs in the inputs, assign it to elided output
   lifetimes.
3. For a receiver `&Self` or `&mut Self`, use its lifetime for elided output
   lifetimes under the receiver rule.
4. If the required output lifetime cannot be determined, omission is an error.
5. `'_` requests inference where permitted. It does not mean `'static`.

Reference types in `const` and `static` declarations default to `'static` unless
otherwise specified. Function/closure reference types within those declarations
still apply their own elision rules first. Ordinary structs that retain
references need a type-level lifetime relationship; elision is not a universal
permission to omit such relationships.

### BC-38. Trait objects have their own default lifetime rules

An omitted object lifetime bound is first obtained from a unique bound on its
containing type, then from applicable trait lifetime bounds. Ambiguity requires
an explicit bound. If none applies, inference is used in expressions and
`'static` is used outside expressions. An explicit `'_` invokes ordinary
elision behavior. [R17]

Consequently, `Box<dyn Trait>` in a type position often means
`Box<dyn Trait + 'static>`, while `&'a dyn Trait` can use the containing reference's
bound. `&'a Box<dyn Trait>` does not automatically change the inner boxed
object's default to `'a`.

### BC-39. Hidden impl Trait captures can retain lifetime constraints

Return-position `impl Trait` hides a concrete type, not its lifetime
obligations. In edition 2024 it automatically captures all in-scope type, const,
and lifetime parameters. Before 2024, free functions and inherent impl methods
did not automatically capture lifetime parameters absent from the return
bounds. [R18]

A `use<..>` bound explicitly selects captures. In the baseline it must include
all in-scope type and const parameters and lifetimes mentioned by other return
bounds; only one such bound is allowed. Lifetimes precede type/const parameters.
Anonymous argument-position `impl Trait` parameters prevent naming the complete
required list. Trait-associated functions must include the trait's parameters,
including `Self`. These are capture/type rules that feed lifetime analysis, not
new kinds of shared or exclusive access.

## 7. Destruction, storage, and temporaries

### BC-40. A destructor is a possible use of borrowed data

A custom `Drop::drop` can access its fields and invoke arbitrary methods or
callbacks. Borrowed data needed for destruction must still be valid when the
destructor can run. The checker does not generally inspect the destructor body
to prove that a particular field will be ignored. [R6] [R19] [I3]

```rust,compile_fail,E0597
struct Inspect<'a>(&'a i32);

impl Drop for Inspect<'_> {
    fn drop(&mut self) {
        println!("{}", self.0);
    }
}

fn main() {
    let holder;
    let value = 1;
    holder = Inspect(&value);
}
```

### BC-41. Use-liveness and drop-liveness are different

All regions required by a value's type must be valid when it can be used.
When it is only implicitly dropped, only the regions required by drop checking
must remain live. Dropping a shared reference does not dereference its referent.
This permits some values containing expired reference regions to remain until
destruction if their destruction cannot access those referents. [R5] [I3]

```rust
fn main() {
    let mut references = Vec::new();
    {
        let temporary = String::from("short lived");
        references.push(&temporary);
    }
    // Do not use the references here. Dropping them does not read the string.
}
```

This is not permission to read a dangling reference or to give a type with an
observing destructor the same treatment.

### BC-42. Generic Drop adds conservative outlives requirements

For an explicit `Drop` implementation, generic arguments are required to remain
live for destruction unless an applicable unsafe `#[may_dangle]` promise relaxes
that requirement. Drop checking also traverses owned field types, including
recursively owned data and captured closure/future state. [R19] [I3]

`ManuallyDrop<U>` does not normally contribute ownership of `U` to this traversal;
`PhantomData<U>` does model ownership for drop checking. The implementation guide
records subtleties involving `needs_drop`, zero-length arrays, `PhantomData`, and
analysis before drop elaboration. These are implementation precision issues, not
permission to ignore actually executed destructors. `#[may_dangle]` is unstable
in this baseline and is not a stable, safe opt-out for arbitrary client code.

### BC-43. Destruction order constrains validity

Locals are dropped in reverse declaration order within their drop scope.
Struct fields and tuple elements are dropped in declaration/index order; array
and owned-slice elements are dropped first to last. `Drop::drop` runs before the
fields' destruction. Leaving nested scopes unwinds those scopes from the inside
out, including ordinary early returns. Captured-by-value closure fields have
unspecified relative drop order. [R6]

NLL can shorten a loan, but it does not arbitrarily reschedule an owner's
destructor to that loan's last explicit use.

### BC-44. Temporary storage has a language-defined drop scope

An unnamed value borrowed through a temporary place does not acquire an
arbitrary caller-requested lifetime. Its temporary scope, possible extension,
and possible promotion determine when its storage remains valid. An ordinary
function or method call does not, merely by returning a reference, extend a
borrowed argument's temporary storage. [R3] [R6]

```rust,compile_fail,E0716
fn main() {
    let reference = String::from("temporary").as_str();
    println!("{reference}");
}
```

### BC-45. Temporary lifetime extension is syntactic and limited

Eligible `let` initializers and reference-binding patterns can extend a
temporary's scope to the containing block. An extending pattern is a reference
binding or an eligible composite pattern containing one. Extension propagates
through the operators specified by the Reference, not every expression that
happens to return a reference. [R6]

```rust
fn main() {
    let reference = &String::from("extended");
    println!("{reference}");
}
```

For the baseline, extending expressions include:

- The initializer itself and operands of extending borrow expressions.
- Eligible super-macro operands and super temporaries, such as those described
  for `pin!` and `format_args!` in the Reference.
- Operands of extending array, cast, braced-struct, and tuple expressions.
- Arguments of extending tuple-struct and tuple-enum-variant constructors.
- Final expressions of extending non-async blocks and extending `if` branches,
  and arm expressions of extending matches.

Extended borrow/dereference/field/tuple-index operands and the indexed operand
of an extending indexing expression follow the propagation rules. An ordinary
function argument, method receiver, or match scrutinee is not thereby an
extending expression. The Reference specifically notes the unresolved treatment
of array-repeat operands. Eligible `const` and `static` initializers can extend
temporary storage to program duration. The Reference labels these exact rules
as subject to change.

### BC-46. Constant promotion is not temporary lifetime extension

Eligible constant expressions can be promoted to storage with `'static`
lifetime. Promotion requires the relevant compile-time evaluation and absence
of disallowed interior mutability/destructors for the promoted value. It is not
a general rule that a reference to a local or a temporary becomes `'static`.
[R6]

```rust
fn promoted() -> &'static i32 {
    &42
}

fn main() {
    assert_eq!(*promoted(), 42);
}
```

### BC-47. Edition changes can alter temporary drop points

Edition 2024 narrows `if let` temporaries before the `else` branch and narrows
temporaries of block tail expressions. Edition 2021 and earlier can therefore
accept or reject different source patterns or observe different destructor
ordering. `match` scrutinees have their own scope rules. A checker must choose
an edition rather than assume that brace nesting alone determines all drops.
[R6] [R20]

## 8. Patterns and closures

### BC-48. Patterns can move, copy, or borrow

A by-value binding moves or copies according to the bound value's type.
`ref` and `ref mut` create shared and mutable loans; match ergonomics can infer
reference binding modes. These operations must observe initialization,
mutability, overlap, and partial-move restrictions. A wildcard is not a
universal move of the matched value. [R3] [R14]

Edition 2024 restricts explicit `mut`, `ref`, `ref mut`, and reference patterns
when the inherited binding mode is not the fully explicit mode. This is an
edition-specific pattern/type rule, not a relaxation of borrow exclusivity.

### BC-49. Matching must preserve protected storage and discriminants

Changing an enum variant, moving out of protected storage, or mutating a
scrutinee through a conflicting path cannot invalidate an active match borrow.
Before evaluating an arm's guard, Rust takes a shared reference to the matched
part of the scrutinee and uses it to access the pattern binding in the guard.
Moving/copying into a by-value binding happens only if the guard succeeds. This
prevents mutation of that protected matched storage in the guard and avoids
premature moves when the guard fails. Lowering also introduces protective/fake
borrows. Treating all matching as unconditional field reads misses these
accesses. [R14] [R28] [I4]

### BC-50. Closures retain the loans of their captures

A closure is approximately an anonymous aggregate containing its captures.
Borrowed captures must remain valid for the closure's required uses and drops.
Returning or storing a closure can therefore extend required borrow regions.
A closure that borrows a local cannot escape that local's storage. [R21]

```rust,compile_fail,E0373
fn escaping() -> impl Fn() -> usize {
    let local = String::from("captured");
    || local.len()
}

fn main() {}
```

### BC-51. move captures ownership of captures, not of their referents

A `move` closure captures values by value, copying `Copy` values as appropriate.
Moving a shared reference into a closure copies/moves the reference; it does not
move its referent or lengthen its lifetime. Moving owned data into the closure
can remove a borrow of the original local, but does not erase references stored
inside that owned data. [R21]

### BC-52. Closure capture includes a unique immutable borrow mode

Rust closures can capture through `ImmBorrow`, `UniqueImmBorrow`, `MutBorrow`,
or `ByValue`. A unique immutable borrow is an internal capture mode that cannot
be written as an ordinary reference type. It supports, for example, modifying
the referent of an `&mut T` binding that is not itself `mut`, while preventing
conflicting access to that binding. It is not an ordinary freely aliasable
`&&mut T`. [R21]

### BC-53. Capture precision is determined by place projections

For edition 2021 onward, captures can select fields rather than entire locals,
subject to the Reference's precision rules. [R21]

- If ancestor and descendant paths are captured, their common captured ancestor
  uses the strongest required mode, ordered
  `ImmBorrow < UniqueImmBorrow < MutBorrow < ByValue`.
- Shared-reference dereference paths are truncated according to the rightmost
  shared-reference-dereference rule.
- Wildcard/rest fields that are not read need not be captured. Arrays and slices
  are still captured as wholes rather than as arbitrary individual indices.
- A move capture stops before dereferencing a reference. Raw-pointer and union
  projections likewise limit how precisely the capture proceeds.
- Access into a packed struct captures the prefix before its first field,
  including potentially aligned fields. `Box` receives special dereference
  treatment; an ordinary `Deref` implementation does not.

Moving a value out of a `Box` into a closure, or reading its contents in a `move`
closure, can capture the entire box. Captures by reference also require the
captured place to be initialized as specified by the Reference. Edition 2018 and
earlier generally captured whole variables instead of these precise field paths.

### BC-54. Fn traits describe how the closure uses its captures

All closures implement `FnOnce`. A closure that does not move out of captures
can implement `FnMut`; one that neither mutates nor moves out of captures can
implement `Fn`. A `move` closure can still implement `Fn` or `FnMut`. Invocation
then uses owned, mutable, or shared access to the closure as required by the
trait. [R21]

Ordinary `Fn`/`FnMut` return types do not express a fresh output reference tied to
the lifetime of each call's borrow of the closure. In particular, a mutable
closure cannot let a new borrow of its captured mutable state escape each call.
Returning a captured reference with an independently valid external lifetime is
a different case. Lending APIs need an appropriate contract. [R21] [R29]

```rust,compile_fail
fn main() {
    let mut values = vec![1];
    let mut callback = || {
        values.push(2);
        &values[0]
    };
    let _ = callback();
}
```

### BC-55. Capturing a field by value changes its destruction owner

A precisely captured field can be dropped with the closure while another field
of its former aggregate remains outside it. Its validity and destructor
requirements follow that capture, not an assumption that the original aggregate
still drops every field together. [R21]

## 9. Async, suspension, and concurrency

### BC-56. Futures retain captured borrows

An async block or function returns a future with captured state. Its retained
references and inputs impose lifetime constraints on that future. `async move`
moves captures, but does not turn borrowed contents into owned contents. An async
function's arguments are captured into its returned future as described by its
desugaring. [R22] [R21]

### BC-57. Borrowing across await is not categorically forbidden

A borrow can remain live across a suspension point when its storage and access
constraints remain valid. Compiler-generated future state can contain such
relationships. Polling, pinning, and library execution requirements must still be
satisfied. Rejecting every reference that spans `.await` would reject valid Rust.
[R22] [R23]

```rust
async fn retain_across_await() {
    let owned = String::from("future state");
    let reference = &owned;
    std::future::ready(()).await;
    println!("{reference}");
}

fn main() {}
```

### BC-58. Async closures can lend to their returned futures

An async closure is lending when its future includes a mutable capture, or it
captures by value other than through the Reference's dereference-projection
exception. A lending async closure does not implement ordinary `Fn` or `FnMut`,
although it still implements `FnOnce`. This is a capture/call-trait restriction,
not a blanket ban on async borrows. [R21]

### BC-59. Send, Sync, and 'static requirements come from separate contracts

`Send` and `Sync` govern transfer/sharing across threads through trait checking.
A closure/future's captured values determine those traits. For example, a shared
capture generally needs `Sync` to make the closure `Send`; mutable or owned
captures generally need `Send`. [R21] [R24]

An API such as `thread::spawn` can require `Send + 'static`; a scoped-thread API
can have a different lifetime contract. A future is not automatically `Send` or
`'static` simply because it is async. Those requirements are not universal
borrow-checker rules. Data races remain undefined behavior. [R2] [R24]

## 10. Interior mutability, unsafe code, and library boundaries

### BC-60. UnsafeCell relaxes shared immutability only for its contents

`UnsafeCell<T>` is the language-recognized way to permit interior mutation under
shared references. It does not permit aliased independent `&mut T` references,
remove validity/lifetime requirements, or prevent data races by itself.
`Cell`, `RefCell`, locks, and atomics build different contracts on top of the
required underlying mechanisms. [R9] [R11]

### BC-61. Runtime borrow guards have destruction-based lifetimes

`RefCell` checks shared/exclusive access at runtime. `Ref` and `RefMut` are guard
values whose destruction releases the dynamic borrow. NLL ending the last
explicit use of a guard does not automatically run its destructor there.
`drop(guard)` or ending its scope can be necessary before a conflicting dynamic
borrow. This is a library runtime check, not an omitted static borrow-checker
error. [R9] [R25]

### BC-62. unsafe does not switch off ordinary borrow checking

Unsafe code enables specific operations with extra obligations. It does not
permit ordinary reference-based violations of initialization, move, or borrow
rules, and does not make undefined behavior valid. [R2] [R26]

```rust,compile_fail,E0506
fn main() {
    unsafe {
        let mut value = 1;
        let reference = &value;
        value = 2;
        println!("{reference}");
    }
}
```

### BC-63. Raw pointers do not carry reference liveness guarantees

Raw pointers can be copied, stored, and returned without the lifetime guarantees
of references. Direct `&raw const` and `&raw mut` operations can avoid creating a
reference to potentially unaligned or uninitialized storage. Dereferencing a raw
pointer, or converting it into a reference through `&*pointer`/`&mut *pointer`,
requires the applicable unsafe validity and access obligations. Compilation
alone does not prove that those obligations hold. [R5] [R8]

### BC-64. Reference validity is broader than conflict detection

References must satisfy validity requirements such as non-nullness, alignment,
non-dangling storage, and valid pointee values, with the Reference's stated
exceptions and unresolved details. Accesses must also respect provenance,
in-bounds projection requirements, and aliasing rules. The entire required
pointee range matters, not merely the numeric starting address. A raw pointer
cast, `transmute`, or forged lifetime does not manufacture longer-lived storage.
[R1] [R2]

The Reference outlines shared immutability and exclusive access for live
references, including derived access paths, and treats `Box` similarly to a
unique reference for those aliasing obligations. It explicitly leaves exact
aliasing and liveness details unsettled. Stacked Borrows, Tree Borrows, and Miri
are not a replacement for a finalized language specification.

### BC-65. Pin is an address-stability contract, not a second borrow checker

`Pin<Pointer>` restricts safe movement/replacement of a pinned pointee when its
contract requires address stability; `Unpin` permits the corresponding escape
from those restrictions. Moving a pointer handle is distinct from moving its
pointee. Pinning does not establish arbitrary referent lifetimes or legalize
aliasing violations. Unsafe implementations must uphold pinning and destruction
contracts. [R23]

### BC-66. Leaks and skipped destructors are not universally forbidden

Rust allows operations such as `mem::forget`, leaking owned storage, and some
reference cycles in safe code. A safe abstraction cannot rely on every destructor
necessarily running to preserve memory safety. Borrow checking does not promise
leak freedom or general resource reclamation. Conversely, the destructor/drop
obligations of operations that actually execute must still be honored. [R6]
[R27]

## 11. Operational model of the MIR checker

This is an implementation model, not an alternative language specification.
The compiler and development guide describe this pipeline. [I1] [I4]

1. Lower source constructs to MIR and establish move/initialization facts.
2. Replace/infer regions and collect type, outlives, and liveness constraints.
3. Solve region constraints, including universally quantified signature regions.
4. Compute which loans are in scope at each control-flow point.
5. Check accesses for mutability, initialization, and conflicts with those loans.

For overlapping ordinary places, the core access compatibility is:

| Existing live loan | Independent read / shared borrow | Independent mutable borrow | Write / replacement | Move / relevant destruction |
| --- | --- | --- | --- | --- |
| Shared | Allowed | Rejected | Rejected | Rejected |
| Active mutable | Rejected | Rejected | Rejected | Rejected |
| Two-phase reservation, before activation | Shared-style access can be allowed | Conflicting mutable loan rejected | Rejected | Rejected |

This table does not replace place-overlap analysis. It excludes compatible
accesses through the active reference itself, valid reborrows, disjoint fields,
`UnsafeCell`-mediated operations, and compiler-only protective/fake borrows.
Activation of a two-phase borrow does not conflict with its own reservation.
Destruction checks distinguish destroying a reference handle from destroying its
referent or its owner. [I4]

The pinned implementation also has access-depth distinctions and special handling
for fake borrows used by lowered constructs. These are necessary implementation
details, not extra source-level reference types or general exemptions that client
code can request.

## 12. What this means for tbc

The signature API is [`view<T, region>`](contracts.md), with symbolic region
labels and lifetime elision. [`contracts.md`](contracts.md) describes how `tbc`
applies these rules to C++:

- Each function is checked on its own: borrows are followed through its places,
  branches and loops, and through the closures it defines.
- A call is known by its declaration. Elision or labels give its result, labels
  give what it keeps, and it needs every borrow it receives to be live. Every
  definition is checked against its declaration.
- C++ chooses a non-const accessor by the object's constness rather than by its
  use, so a call's ability to invalidate an input is summarized across calls, an
  input at a time, never field by field. Rust needs no such summary.
- Exclusivity is upheld where `noalias` matters to the callee: a call's mutable
  argument may not overlap another argument, and an object may not borrow itself
  except through a pinned `lt::self` field.
- A `TBC_SHARED` type is the trusted boundary that `UnsafeCell` and unsafe code
  form in Rust.

Shared versus exclusive loans between two independent holders, one region per
level of a type (`&'s T<'b>`), and explicit outlives bounds remain pending. The
older pointer-backed `borrow<T, scope>` utility is not the signature notation.

A Rust-inspired C++ analyzer needs explicit semantics for at least:

- Places, ownership, initialization, moves, destruction, and C++ replacement.
- Shared versus exclusive loans, their derivations, and overlap.
- Control-flow-sensitive liveness, including exceptions and implicit destructors.
- Interprocedural lifetime contracts and generic substitution.
- Escape through aggregates, callbacks, coroutines, containers, and raw pointers.
- Trusted unsafe/library boundaries and the diagnostics for unmodeled code.

C++ `const`, references, copy/move operations, destructors, unions, and aliasing
rules are not equivalent to their Rust counterparts. Rust's variance, `Drop`,
`Copy`, and lifetime rules cannot be copied into C++ templates without defining
what they mean for C++ operations. This document records Rust behavior; it does
not silently turn all of it into a `tbc` implementation specification.

## 13. Example validation

Every fenced Rust example in this document is a complete independent compilation
unit. Compile with:

```sh
rustc --edition=2024 --emit=metadata example.rs
```

A plain `rust` block must compile. A `rust,compile_fail` block must fail. An
additional error code identifies an expected diagnostic, not a guarantee that no
other diagnostic can accompany it.

Validation on 2026-10-30 with the baseline compiler:

- **30/30 independent compilation checks matched expectations**, including the
  stated error codes: 13 accepted examples and 17 rejected examples.
- **30/30 rustdoc tests passed**. These also execute the accepted examples;
  the async example defines a checked future but does not poll it.
- All 32 distinct versioned documentation targets, including their cited anchors,
  resolved in the installed official documentation.

To rerun the doctests from `dlls/tbc`:

```sh
rustdoc --test --edition=2024 --test-args=--test-threads=2 docs/rust-borrow-checker.md
```

These checks do not prove general memory safety or validate every unsafe-code
obligation. The supplementary development guide can evolve independently; the
versioned language/library references and pinned compiler take precedence for
baseline-specific claims.

## Sources

### Versioned language and library documentation

[R1]: https://doc.rust-lang.org/1.93.1/reference/memory-model.html
[R2]: https://doc.rust-lang.org/1.93.1/reference/behavior-considered-undefined.html
[R3]: https://doc.rust-lang.org/1.93.1/reference/expressions.html
[R4]: https://doc.rust-lang.org/1.93.1/reference/variables.html
[R5]: https://doc.rust-lang.org/1.93.1/reference/types/pointer.html
[R6]: https://doc.rust-lang.org/1.93.1/reference/destructors.html
[R7]: https://doc.rust-lang.org/1.93.1/reference/special-types-and-traits.html
[R8]: https://doc.rust-lang.org/1.93.1/reference/expressions/operator-expr.html
[R9]: https://doc.rust-lang.org/1.93.1/reference/interior-mutability.html
[R10]: https://doc.rust-lang.org/1.93.1/reference/trait-bounds.html
[R11]: https://doc.rust-lang.org/1.93.1/std/cell/struct.UnsafeCell.html
[R12]: https://doc.rust-lang.org/1.93.1/reference/type-coercions.html
[R13]: https://doc.rust-lang.org/1.93.1/nomicon/borrow-splitting.html
[R14]: https://doc.rust-lang.org/1.93.1/reference/patterns.html
[R15]: https://doc.rust-lang.org/1.93.1/reference/items/unions.html
[R16]: https://doc.rust-lang.org/1.93.1/reference/subtyping.html
[R17]: https://doc.rust-lang.org/1.93.1/reference/lifetime-elision.html
[R18]: https://doc.rust-lang.org/1.93.1/reference/types/impl-trait.html
[R19]: https://doc.rust-lang.org/1.93.1/nomicon/dropck.html
[R20]: https://doc.rust-lang.org/1.93.1/edition-guide/rust-2024/temporary-tail-expr-scope.html
[R21]: https://doc.rust-lang.org/1.93.1/reference/types/closure.html
[R22]: https://doc.rust-lang.org/1.93.1/reference/items/functions.html#async-functions
[R23]: https://doc.rust-lang.org/1.93.1/std/pin/index.html
[R24]: https://doc.rust-lang.org/1.93.1/reference/special-types-and-traits.html#send
[R25]: https://doc.rust-lang.org/1.93.1/std/cell/index.html
[R26]: https://doc.rust-lang.org/1.93.1/reference/unsafe-blocks.html
[R27]: https://doc.rust-lang.org/1.93.1/reference/behavior-not-considered-unsafe.html
[R28]: https://doc.rust-lang.org/1.93.1/reference/expressions/match-expr.html#match-guards
[R29]: https://doc.rust-lang.org/1.93.1/std/ops/trait.FnMut.html#tymethod.call_mut

- [R1: Memory model][R1]
- [R2: Undefined behavior and the unfinished aliasing model][R2]
- [R3: Places, moves, mutability, expression evaluation, and temporaries][R3]
- [R4: Variables and definite initialization][R4]
- [R5: References and raw pointers][R5]
- [R6: Destruction, drop scopes, promotion, and temporary lifetime extension][R6]
- [R7: Language-recognized types and traits][R7]
- [R8: Borrow, raw-address, dereference, and operator expressions][R8]
- [R9: Interior mutability][R9]
- [R10: Lifetime, implied, and higher-ranked bounds][R10]
- [R11: UnsafeCell aliasing obligations][R11]
- [R12: Coercions and implicit reference operations][R12]
- [R13: Borrow splitting and conservative container analysis][R13]
- [R14: Patterns and binding modes][R14]
- [R15: Unions][R15]
- [R16: Subtyping and variance][R16]
- [R17: Function elision and trait-object lifetime defaults][R17]
- [R18: Opaque return types and precise capture][R18]
- [R19: Generic drop checking and may_dangle][R19]
- [R20: Edition 2024 tail-expression temporary scopes][R20]
- [Edition 2024 if-let temporary scopes](https://doc.rust-lang.org/1.93.1/edition-guide/rust-2024/temporary-if-let-scope.html)
- [Edition 2024 return-position impl Trait capture](https://doc.rust-lang.org/1.93.1/edition-guide/rust-2024/rpit-lifetime-capture.html)
- [R21: Closure captures, unique immutable borrows, call traits, and async closures][R21]
- [R22: Async function desugaring and lifetime capture][R22]
- [R23: Pinning contracts][R23]
- [R24: Send and Sync][R24]
- [R25: Cell and runtime borrow guards][R25]
- [R26: Unsafe blocks][R26]
- [R27: Leaks and behavior not considered unsafe][R27]
- [R28: Match-guard borrowing and delayed moves][R28]
- [R29: FnMut receiver and output contract][R29]
- [Sync](https://doc.rust-lang.org/1.93.1/reference/special-types-and-traits.html#sync)

### Compiler implementation and supplementary guide

[I1]: https://rustc-dev-guide.rust-lang.org/borrow-check.html
[I2]: https://rustc-dev-guide.rust-lang.org/borrow-check/two-phase-borrows.html
[I3]: https://rustc-dev-guide.rust-lang.org/borrow-check/drop-check.html
[I4]: https://github.com/rust-lang/rust/blob/01f6ddf7588f42ae2d7eb0a2f21d44e8e96674cf/compiler/rustc_borrowck/src/lib.rs

- [I1: MIR borrow-checking pipeline][I1]
- [NLL region inference](https://rustc-dev-guide.rust-lang.org/borrow-check/region-inference.html)
- [I2: Two-phase borrowing][I2]
- [I3: Use-liveness and drop-liveness][I3]
- [I4: Pinned rustc access checks and conflict table][I4]
- [Pinned place-conflict analysis](https://github.com/rust-lang/rust/blob/01f6ddf7588f42ae2d7eb0a2f21d44e8e96674cf/compiler/rustc_borrowck/src/places_conflict.rs)
- [Pinned region inference](https://github.com/rust-lang/rust/tree/01f6ddf7588f42ae2d7eb0a2f21d44e8e96674cf/compiler/rustc_borrowck/src/region_infer)
