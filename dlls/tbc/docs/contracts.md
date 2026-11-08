# Lifetimes, declarations and explicit contracts

`tbc` checks C++ the way Rust's borrow checker checks Rust. Inside a function it
follows every borrow through the function's own code. A call is known only by
its declaration: Rust's lifetime elision, or `tbc::view` labels where elision
names no source, say what the result borrows and what the callee keeps. Each
body is checked against its own declaration where it is defined. Ordinary
references, pointers, `std::string_view`, and aggregates containing borrowed
fields need no annotation while elision describes them.

`<tbc/view.hpp>` provides `tbc::view<T, region>` for an explicit interface
contract. It aliases the native C++ type `T`. No wrapper, macro, external trait,
or parameter-name string is required.

## Start with ordinary C++

```cpp
std::string_view prefix(std::string_view source) {
  const auto alias = source;
  return alias.substr(0, 3);
}
```

The result borrows `source`, its only parameter that can lend. A caller can use
the result while those bytes remain valid. Keeping a result from a temporary string and using it in a
later full expression produces `tbc-dangling-borrow`. Reading the result within
the temporary's full expression is allowed.

The same applies to aggregates:

```cpp
struct node {
  std::string_view text;
  std::vector<node> children;
};

node makeLeaf(std::string_view source) {
  return {.text = prefix(source), .children = {}};
}
```

The returned node owns its child vector but borrows the text bytes. Copying or
moving the node preserves that dependency. It does not borrow the local node
object. Constructing an owning `std::string` copies the bytes instead.

An actual reference result is different:

```cpp
const node &identity(const node &input) { return input; }
node copy(const node &input) { return input; }
```

`identity` requires the input object to remain alive. So does `copy`: by elision
its result borrows `input`, and, as Rust's implied bounds require, what `input`
holds. To state that a copy keeps only the borrowed contents, label them as a
region of the type, as a Rust `Node<'a>` does (see below).

## What a function's own code follows

The checker builds a Clang CFG for each available project function definition.
It propagates dependencies through local aliases, assignments, calls, copies,
moves, direct fields, aggregate initialization, direct constructor member
initializers, and modeled standard-library operations. It joins reachable branch
origins and iterates loop states to a fixed point. An aggregate's reference
member is bound to its initializer, as a constructor's member initializer binds
it.

Reading through a pointer (`*pointer`, `pointer->field`, `pointer[index]`, or
`pointer->method()`) requires a live pointee and yields the pointee's contents.
Reading a reference field does the same for its referent. Writing through either
updates the object it designates. For an input, such as a parameter or a field
of the receiver, "where it points" and "what that object holds" are separate
parts: a borrow can stand for a part reached through references, as a stream
wrapper's body reaches the buffer of the stream it wraps:

```cpp
class gated_stream {
public:
  std::span<const char> peek() const { return stream_.peek(); }

private:
  buffer_stream &stream_;
};
```

Inside `peek`, what `stream_.peek()` returns stands for what `stream_`'s
referent designates. The input itself, and past it each reference field, is
followed this way, at most three times; what a pointer held in a field
designates stays merged with the object that holds the pointer. The parts an
input reaches are typed: a field the reached type does not have stops the part
there. Callers know `peek` by its declaration only: its elided result borrows
the wrapper and what the wrapper holds.

Standard-library calls are modeled by the kind of receiver. A view
(`std::string_view`, `std::span`) lends its referent. An iterator, recognized
by its `iterator_category`, designates its element like a pointer. An owner
(containers, `std::optional`, smart pointers, `std::pair`) lends its storage
through references, pointers, and iterators, and returns copies of its contents
by value. An opaque standard function's iterator or pointer comes from an
argument of the same type, a range argument that yields it, or the address of an
argument; any other result copies its arguments. Containers copy initializer
lists instead of borrowing their backing arrays.

A lambda's closure holds copies of its by-value captures. Inside the lambda, a
by-reference capture is the caller's own variable whenever the enclosing
function calls it; a closure that escapes falls back to the borrows of all its
captures. `this` inside a lambda is the object the closure captured, so what a
callback does to that object's fields lands in that object, also when a
template helper invokes it. A `std::function` keeps the borrows of the callable it wraps.

Counting, clearing, or growing a sequence container does not read what its
elements borrow; an associative container compares its keys, so it does. A
visible literal-backed result needs no artificial input lifetime.

## Calls are known by their declaration

A call to a project function uses its declaration, never its body, as a Rust call
uses only the callee's signature:

- The result borrows what elision or the result's label names. A returned
  reference designates some part of what it borrows, at fields the declaration
  does not name. A returned value borrows what that input owns and what it holds.
  A labeled non-const reference to a type that holds borrows is an output
  parameter, which receives borrows of its region; when the result names that
  region too, it also lends, as `fn find<'a>(store: &'a mut Store) -> &'a Entry`
  lends the store.
- The callee keeps an argument only where its declaration says so: a parameter
  and a receiver field that share a label, a labeled output parameter, a
  parameter whose type the class template's own parameters spell, as `T` in
  `Vector<T>::push(T value)`, whose borrows belong to `T`, or any argument that
  lends to a constructor of a class whose fields carry no label. A member
  template's parameter, such as a callback's type, is never kept: a Rust struct
  keeps an `F` only in a field of type `F`.
- The call uses everything it is given, including what its receiver holds, as a
  Rust call needs every borrow its inputs carry to be live.
- The call may invalidate an input it can mutate. Its summary says only which
  inputs, never which of their fields: a method's receiver counts whole, as
  `&mut self` lends the whole object. Through a reference, it reaches the object
  that reference designates. This summary is the one thing the checker infers
  across calls, because C++ picks a non-const accessor such as `operator[]` by
  the object's constness rather than by its use; every `&mut` would otherwise
  conflict, which Rust code never meets. A project function without a visible
  body, or a virtual one that is not `final`, may invalidate every input it can
  mutate. What the receiver reaches through its own reference fields it borrows
  exclusively, as a Rust `&mut` field is: a call that mutates through one
  invalidates every other borrow of that object, never the receiver's own.
  Nothing a reference to const designates, nor a constant with static storage,
  is invalidated through it, as a Rust `&T` lends nothing to mutate.

A closure is checked with the function that defines it, as Rust does, so its
call keeps which fields it reads and mutates. So are the members the compiler
writes, such as a defaulted assignment.

```cpp
void clearResponse(stream &target);

void observeMethod(stream &active) {
  const std::string_view method = active.request.method;
  clearResponse(active); // tbc-invalidated-borrow: the call may mutate all of `active`
  observe(method);
}
```

Mutating one field directly leaves the other fields' borrows valid; a call that
only needs the response takes the response:

```cpp
void clearResponse(message &response);

void observeMethod(stream &active) {
  const std::string_view method = active.request.method;
  clearResponse(active.response);
  observe(method);
}
```

A callee assumes its inputs do not overlap. An argument it can mutate, by a
non-const reference or pointer or as the receiver of a non-const method, may not
designate, contain, or lie inside another of its arguments, and no view passed by
value may point into storage the call invalidates (`tbc-invalidated-borrow`), as
Rust lends one `&mut` borrow at a time:

```cpp
void releaseGeometry(model &state, workspace &target);

releaseGeometry(state, state.workspaces.front()); // the workspace lies inside the model
```

Pass disjoint parts, or an index the callee looks up.

Inside a method, a call to another method of the same object lends that object
whole, as `self.method(..)` lends `&self` or `&mut self`: `this` counts as every
field, so a mutating method may not also be passed one of them.

```cpp
class tally {
  void grow() {
    append(items_); // tbc-invalidated-borrow: append may mutate items_ through this
  }
  void append(std::vector<int> &items);
  std::vector<int> items_;
};
```

Make such a helper `static`, or a free function, and pass it the fields it needs.

Project headers are checked too. Template definitions are analyzed in their
instantiated forms; an uninstantiated dependent template has not been verified.
Diagnostics are emitted after summary convergence, not from provisional states.

## Keep public promises explicit

Use explicit regions when an interface must state a stable relationship without
requiring its implementation at every call:

```cpp
using text_a = tbc::view<std::string_view, tbc::lt::a>;
using text_b = tbc::view<std::string_view, tbc::lt::b>;

text_a selectText(text_a first, text_a second) {
  return first.size() > second.size() ? first : second;
}

text_a wrongOrigin(text_a source, text_b other) {
  return other; // tbc-contract-violation
}
```

Repeating `a` allows either compatible input to supply the result. The buffers
need not be the same allocation or have identical owner lifetimes. The caller
needs a common validity region sufficient for the result's uses.

The declared contract remains authoritative even if the current implementation
returns only one of the permitted inputs. Inference checks the implementation;
it does not silently narrow that public promise at call sites.

`lt::a` is a signature variable, not global storage or a request to extend an
owner's life. Calls instantiate labels independently. `lt::a`, `lt::b`, `lt::c`,
and `lt::d` are predefined. `tbc::lifetime<tag>` permits descriptive labels.
Distinct labels do not imply an outlives relationship; explicit outlives bounds
are not supported.

`lt::static_storage` is the one fixed region: storage that outlives every caller,
like Rust's `'static`. A result labeled with it depends on no argument or receiver,
so callers keep it after their inputs die. Its definition may return only string
literals, objects with static storage duration and inputs labeled
`static_storage`: a call passes such an input only what outlives every caller,
as a Rust `&'static str` parameter takes, and is rejected at the argument
otherwise. The environment cannot supply it, because `setenv` can replace it.

```cpp
struct content {
  std::string_view mime_type;
  std::vector<std::byte> bytes;
};

tbc::view<std::expected<content, read_error>, tbc::lt::static_storage> read();
```

A contract can be written once on the declaration:

```cpp
text_a prefix(text_a source);

std::string_view prefix(std::string_view renamed) {
  return renamed.substr(0, 3);
}
```

The checker still checks that declaration's explicit region against the plain
C++ definition. Parameter spelling does not matter. Do not declare conflicting
contracts on different redeclarations; validating every such conflict remains
outside the current checks.

## Code the project does not control

Releasing a unique owner hands its object to an owner the analysis does not see,
as Rust's `Box::into_raw` does, and a `new` expression's pointer owns a fresh
object no variable holds: borrows of either are unchecked, like a raw pointer
from foreign code. An Objective-C message is foreign code too. An optional owner
hands over what the owner it holds owns. A standard range adaptor over a view,
such as `std::views::reverse` over a span, views that range; one that owns its
range, as `std::ranges::owning_view` does, does not. Standard functions are
recognized by namespace, whatever inline namespace the library spells.

Third-party code, such as Qt, is never reported, but its types and headers are
used to infer what the project borrows. A library type with a trivial destructor
cannot release memory, so it views whatever it points to, as `QStringView` does.
A library type that releases memory in its destructor owns it and holds borrows
only through its type arguments, as `QList<QStringView>` does. A library
container lends its storage through references, pointers, and iterators, and
copies its elements by value. What it stores keeps the dependencies of what it
was given: an element, a pointer element, or the arguments an emplaced view or
pointer is constructed from, as `views.emplace_back(text.data(), text.size())`
designates `text`. An iterator range stores copies of the elements it
designates, and the position an insertion takes is not stored. A pointer
returned by any other library owner has
no inferable relation to it and is not tracked. A library function with a visible
body follows the same argument-shape model as an opaque standard function. A
compiled library function, without a body, is outside the analysis.

## Ownership transfer

Moving a smart pointer, or an allocator-aware container other than a string,
hands its allocation to the destination: a raw pointer or reference into the
moved object then depends on the new owner. An object moved into a container
lives as long as the container, across its reallocations. Resetting or
reassigning a unique owner, recognized because it cannot be copied, destroys its
object; a shared owner may not. A swap exchanges the two allocations. A
by-value parameter is the callee's own copy, so writes to it never reach the
caller.

## Places inside objects

A borrow records how deep it reaches inside a variable: the variable itself, the
storage it owns, such as a vector's element slots, and each level owned below
that, such as the object a `unique_ptr` element owns or a nested node's own
children. An operation on an object only invalidates the levels below the place
where that object lives:

```cpp
void detachAll(std::vector<std::unique_ptr<pane>> &panes) {
  for (const auto &pane : panes) {
    pane->detach(); // mutates the owned pane, not the vector's slots
  }
}
```

Growing a container moves its element slots. An element that owns its contents
through an allocation, such as a `unique_ptr` or a `std::vector`, leaves them in
place; one that keeps contents inline, such as a short `std::string`, moves them
too. Clearing or reassigning a container destroys every level below it. Levels
past a fixed depth merge into the deepest one, which keeps the analysis finite
for recursive structures.

A borrow also records the fields on the way to its place, so an operation on one
field of an object leaves borrows of its other fields valid. That holds through a
reference a function returns to a field and through a callee that mutates a field
of its argument:

```cpp
void clearResponse(stream &target) { target.response.headers.clear(); }

void observeMethod(stream &active) {
  const std::string_view method = active.request.method;
  clearResponse(active); // the request is another field
  observe(method);
}
```

What an object holds is kept per field too. Assigning, clearing, or rebuilding one
field replaces what that field held and leaves the others. An object that views
its own fields, like a list of `string_view`s over a sibling vector of strings,
loses those views when that vector grows. Assigning an object overwrites what it
held without reading it. A path keeps a bounded number of fields, and the members
of a union share one place.

A branch on `std::holds_alternative<T>(v)` or `std::get_if<T>(&v)`, negated or
through the variable a condition declares, tells each side which alternatives
`v` can hold. Where none of them can borrow, `v` holds nothing borrowed:

```cpp
if (std::holds_alternative<std::string_view>(criteria.scope)) {
  criteria.scope = std::string_view{owned_scope};
}
// either the owned copy, or an alternative that borrows nothing
```

Which alternative borrows what is not tracked, so a test leaves a variant with
several borrowing alternatives unchanged.

## Regions of a type

A label on a field is a region of its class, like a lifetime parameter of a Rust
struct. A free function whose result takes a region that no parameter names
borrows what its arguments of that class hold, as `&Record<'a> -> &'a str` does:

```cpp
struct record {
  tbc::view<std::string_view, tbc::lt::a> text;
};

tbc::view<std::string_view, tbc::lt::a> textOf(const record &input) {
  return input.text; // the text the record holds, not the record
}
```

A field labeled `lt::static_storage` only ever holds storage that outlives every
caller, as a Rust `&'static str` does, so its object borrows nothing through it,
and what it holds supplies a static result or any other place, as a static input
does.
Initializing or assigning it from anything else is a `tbc-contract-violation`:

```cpp
struct limit {
  tbc::view<std::string_view, tbc::lt::static_storage> name;
};

limit fromLiteral() { return {.name = "terminal.max_bytes"}; }
```

## Receiver fields

A region label on a field is shared by every method of that class whose
signature uses the same label, like a lifetime parameter of the class:

```cpp
struct holder {
  text_a held;

  void hold(text_a text);
  text_a read() const;
};
```

A result in that region can come from the receiver's field or from any
parameter in the region. A non-const method can retain any argument passed to a
parameter in the region, whatever it returns. Retention accumulates across
calls: every retained source must outlive the receiver's later uses.

What a region keeps of a labeled reference parameter depends on its fields: a
reference, a pointer or a view there keeps the argument itself, while fields
that hold values keep a copy of what the argument holds, so a temporary passed
by `const &` and copied does not dangle. An allocator, or any shared type, is
always kept by reference.

A body keeps nothing its declaration does not let it keep. Storing an input's
borrow in a field, in an output parameter, or in what an input designates
requires the input and that place to share a label, as a Rust method can store
`&'a str` only in a `Holder<'a>` (`tbc-contract-violation`). What a template
argument holds may be stored where the template keeps that argument, and a
parameter of the class's own type, as `Self` in an assignment or a swap, shares
the class's regions. A constructor of a class whose fields carry no label may
keep any argument, which its callers assume it does.

A constructor is a mutating method too. The new object retains every argument
whose parameter shares a region with a field, so a prepared statement can state
that it borrows its database, as Rust's `Statement<'conn>` does:

```cpp
class statement {
public:
  statement(tbc::view<database &, tbc::lt::a> owner, std::string_view sql);

private:
  tbc::view<sqlite3_stmt *, tbc::lt::a> handle_ = nullptr;
};
```

A constructor of a class whose fields carry no region may retain any argument
that can lend, and a reference parameter's object itself. A Rust struct always declares its lifetimes; without that
declaration, assuming every one is retained is sound and asks callers only to
keep those arguments alive. Labels narrow it to what the object really keeps, as
a font face keeps its bytes but copies its match:

```cpp
explicit Face(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes, const FontMatch &match = {});
tbc::view<std::unique_ptr<FT_FaceRec, FaceDeleter>, tbc::lt::a> face_;
```

What a field labeled with a result's region owns lives in that region too, as a
field of `&'a self` does.

A field label matters to methods of its own class and to functions whose result
takes its region. Code that initializes an aggregate's fields directly is
followed as written.

## Constructors

A constructor's fields hold nothing on entry; its initializers and body give
them their first values. A path that throws constructs no object, so what the
fields held there is not part of the result. A base initializer, a delegating
initializer, and an inheriting constructor (`using base::base`) write the
fields as the constructor they run does.

An object never keeps a borrow of itself, such as a pointer to a sibling field
or a service that references a sibling model: callers know each of its fields as
a separate input, which Rust guarantees by refusing self-referential structs.
Storing such a borrow is a `tbc-dangling-borrow` where it is taken, in a
constructor or any method:

```cpp
class buffer {
public:
  buffer() : cursor_(storage_.data()) {} // tbc-dangling-borrow

private:
  std::string storage_;
  const char *cursor_;
};
```

Keep an index or an offset instead, or pass the sibling to each call that needs
it.

A function's address is static storage, not a borrow of the object that keeps
it, as a `std::unique_ptr` with a function deleter does.

`tbc::raw(pointer)` makes a raw pointer, as Rust's `pointer as *mut T` does: the
checker keeps no borrow through what it returns, so the code that dereferences
it answers for the object being alive, as unsafe Rust does. It belongs only where
foreign code already holds the object by address, such as a C library's
callbacks re-entering the object that owns their state.

A pointer field of a C struct that a system header declares, such as zlib's
`z_stream::next_in`, is a raw pointer, as Rust's `*const T` in an FFI struct
is: storing a buffer in it keeps no borrow, nor does a value of such a struct,
and the code that hands the buffer to the C library answers for it.

A field labeled `lt::self` is the one exception: it borrows only the object that
holds it, as an allocator reference to a sibling arena does. Its borrows never
count as the object's, so a `std::shared_ptr` to such an object carries none,
and a later call that mutates the object, even from its own constructor, does
not invalidate them. Such a field may also carry a region the object already
keeps in another field, as a face reading bytes a sibling allocates there: the
object lives within that region anyway. The label is a promise, like a raw pointer behind Rust's `Pin`: the checker only
requires the type to be neither copyable nor movable, and rejects the
initializer otherwise.

Neither `lt::self` nor `lt::static_storage` is a lifetime of the class, as a
Rust struct's lifetime parameter is: a constructor of a class whose other fields
carry no label still keeps every argument that lends.

## Shared types

A class marked `TBC_SHARED`, from `<tbc/view.hpp>`, keeps every borrow it hands
out valid whatever is done through it, as a Rust type with interior mutability
does through `&self`. An allocator is the usual case: many objects keep a
reference to it, a call through it invalidates nothing, and two arguments may
name the same one. Its implementation is trusted rather than checked, like the
unsafe code behind such a Rust type, so the mark belongs only on types audited
for it.

```cpp
template <typename Upstream>
class TBC_SHARED SynchronizedAllocator {
  // ...
};
```

A pointer or a reference a shared type's method returns, such as an allocated
block or a cache's entry, is storage the shared object keeps valid, unchecked
like a `new` expression's.

Nor is an object of a shared type invalidated by a call to something that keeps
it: a store that mutates a model holding the allocator leaves the allocator, and
every other borrow of it, valid.

A field may keep a reference to a sibling of a shared type, as services keep the
allocator or the limit queue of the object that holds them. That borrow is internal
to the object, so the object only has to keep its address: it must be neither
copyable nor movable, as Rust shares such a field behind `Pin`
(`tbc-dangling-borrow` otherwise). A sibling of any other type still needs the
`lt::self` label.

```cpp
class pool {
public:
  pool() : lender_(memory_) {}   // accepted: arena is TBC_SHARED and pool is pinned
  pool(const pool &) = delete;
  pool &operator=(const pool &) = delete;

private:
  arena memory_;
  lender lender_;
};
```

## Constructing factories

A function template marked `TBC_CONSTRUCTS` builds its first template argument
from the arguments of its trailing pack, as `Box::new(Value::new(arguments))`
does. Its result keeps what that type's constructors keep of those arguments, by
their declarations, and borrows the arguments before the pack, such as the
allocator `makeOwned` takes:

```cpp
template <typename Value, Allocator Memory, typename... Arguments>
TBC_CONSTRUCTS Owned<Value, Memory> makeOwned(Memory &memory, Arguments &&...arguments);
```

```cpp
class asset {
public:
  asset(const asset &) = delete;
  asset &operator=(const asset &) = delete;

private:
  SystemAllocator memory_;
  tbc::view<Vector<std::uint8_t, SystemAllocator>, tbc::lt::self> bytes_;
};
```

## Elision

`tbc::view<T>` uses `lt::elided`, which means the same as no annotation.

For an annotated declaration, the signature rules are:

1. Each elided annotated input introduces an independent region.
2. One input region can supply an elided result.
3. A method's elided result follows its receiver unless explicit labels say
   otherwise.
4. Multiple incompatible input regions produce `tbc-ambiguous-lifetime`.

Callers rely on these promises, so the checker verifies each one against the
definition when it checks the translation unit that defines the function. A
method with an elided result that returns a parameter instead of the receiver's
storage is a `tbc-contract-violation`.

```cpp
class session {
public:
  tbc::view<const state &> current() const noexcept;

private:
  state state_;
};
```

A project declaration without any annotation follows Rust's lifetime elision
too. A method's result borrows from its receiver. A function without a receiver
borrows from its only parameter that can lend, a reference, a pointer or a
view; with no such parameter it borrows nothing, as Rust's `'static` output. With
several, elision names no source, and using the result is
`tbc-missing-contract` until the declaration labels one. Every definition is
checked against the same rule, because callers see only the declaration:

```cpp
class registry {
public:
  const std::string &pick(const std::string &fallback) const;
};

const std::string &registry::pick(const std::string &fallback) const {
  return fallback; // tbc-contract-violation: callers assume the receiver
}
```

An override of a library virtual, such as Qt's `updatePaintNode`, takes its
contract from the library, whose callers are not checked. A deduced return type
repeats the label of what it returns; it is not a contract of the deducing
function. Unsupported borrowed expressions retain an unknown dependency rather
than becoming an assumed static result.

Explicit labels state which input supplies a result when elision cannot. For
example, a stream can return a view of a caller-supplied destination rather than
its own storage:

```cpp
using bytes_a = tbc::view<std::span<const std::byte>, tbc::lt::a>;
using writable_bytes_a = tbc::view<std::span<std::byte>, tbc::lt::a>;

struct retained_stream {
  bytes_a read(writable_bytes_a destination) const;
};
```

## EBNF

`dlls/ebnf` keeps the public source/result contract on `parse`. Its helpers,
including `parseRule`, `parseIdentifier`, `peek`, and the lexer's token readers,
use native return types. The checker follows their source dependencies through
bodies rather than requiring the same annotation on every helper.

The other explicit contract is the lexer's output parameter: `source` and the
token `buffer` share one region, so a call replaces the buffer's views with
views of `source`. Inference cannot prove that replacement, because it does not
track element indices. Without it, `parse` could return tokens from an earlier
source. The parser's own fields carry no region label.

A returned AST borrows the source text, not the local parser or token-buffer
objects. Reusing the parser does not make an earlier tree independent of its
original source.

## Limits

A clean run is not a proof of arbitrary C++ memory safety. The current analysis
has deliberate limits:

- The elements of one container are merged. Index-sensitive ownership is not
  implemented, so erasing at a position is not modeled. Fields past a path's
  bound, and what a library object holds inside its own layout, are not told
  apart. A function that retains an argument on one path retains it for every
  call, whatever value selects that path: a queue that copies a reply unless a
  shared owner is supplied must copy and retain in separate functions. A shared
  owner retained beside a view does not keep the view's referent alive.
- One label per field or parameter names one region. A wrapper that holds a
  reference to an object which itself holds borrows cannot yet name the inner
  region apart from the reference, as `&'s Stream<'b>` does.
- Two objects that each keep the same mutable reference, when neither is the
  other's field, are not reported; only overlapping arguments of one call are.
- A function known by its declaration may call a callback it receives with
  borrows of its other inputs; what the callback keeps of them in its captures
  is not yet followed back to the caller.
- Deferred captures, general callable type erasure, custom allocator/destructor
  dependencies, ownership transfer through opaque project swaps, and foreign invalidation
  protocols still require further analysis or audited models.
- Mutable global borrowed state, exception-unwinding analysis, virtual/indirect
  dispatch, and conflicting redeclaration contracts are not comprehensively
  checked. Unsupported result dependencies may produce `tbc-missing-contract`.
- Bounds, nullability, initialization, and concurrency are separate checks and
  remain pending. A pointer annotation is not a non-null promise.

A region label alone cannot describe reallocation, retained callbacks, or every
foreign-library effect. The pending specifications preserve those requirements
without pretending the annotation already implements them.

See `tests/spec/places.cpp` and `tests/spec/inference.cpp` for paired acceptance/rejection regressions and
`tests/spec/README.md` for the distinction between implemented and pending cases.
