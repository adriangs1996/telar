#ifndef TBC_ANNOTATIONS_HPP
#define TBC_ANNOTATIONS_HPP

// The attributes tbc-lint reads on declarations. This header includes nothing: a module unit
// includes it for the macros alone and imports telar.tbc for the types of tbc/view.hpp.

// A class marked TBC_SHARED keeps every borrow it hands out valid whatever is done through it, as a
// Rust type with interior mutability does through `&self`; an allocator is one. Many objects may keep
// a reference to one of its objects, and calls through it invalidate nothing. Its implementation is
// trusted rather than checked, like the unsafe code behind such a Rust type.
#if defined(__clang__)
#define TBC_SHARED [[clang::annotate("tbc::shared")]]
#else
#define TBC_SHARED
#endif

// A class template marked TBC_OWNER owns one object in an allocation of its own, as Rust's Box does:
// the checker reads it as the standard library's unique owner, so its object lies one level below
// it, moving it hands that object over, and a borrow of the object outlives the owner's moves. Its
// implementation is trusted rather than checked, like the unsafe code behind Box.
#if defined(__clang__)
#define TBC_OWNER [[clang::annotate("tbc::owner")]]
#else
#define TBC_OWNER
#endif

// A function template marked TBC_CONSTRUCTS builds its first template argument from the arguments
// of its trailing parameter pack, as `Box::new(Value::new(arguments))` does: its result keeps what
// that type's constructor keeps of them, and borrows its other arguments.
#if defined(__clang__)
#define TBC_CONSTRUCTS [[clang::annotate("tbc::constructs")]]
#else
#define TBC_CONSTRUCTS
#endif

// A raw pointer, as Rust's `pointer as *mut T`: the checker keeps no borrow through what it returns,
// so the code that dereferences it answers for the object being alive, as unsafe Rust does. It
// belongs only where foreign code already holds the object by address, such as a C library's
// callbacks re-entering the object that owns their state.
#if defined(__clang__)
#define TBC_RAW [[clang::annotate("tbc::raw")]]
#else
#define TBC_RAW
#endif

// A function marked TBC_HOT_PATH keeps its body in a module interface so that importers can inline it;
// tbc-lint's interface-bodies check reports every other body there. A non-template one must also be
// inline, because the body of a non-inline function never reaches an importer. On a class, it covers
// the bodies of all its members, as for a small template that stays one; on a variable, the lambdas
// that initialize it.
#if defined(__clang__)
#define TBC_HOT_PATH [[clang::annotate("tbc::hot_path")]]
#else
#define TBC_HOT_PATH
#endif

// A function marked TBC_GENERIC keeps its body in a module interface because it is a template, or a
// member of one, over a type its caller chooses (a protocol message, a visitor, a callable), which no
// `extern template` can instantiate in advance. tbc-lint's interface-bodies check reports the mark on
// a declaration that is neither. On a class template, it covers the bodies of all its members; on a
// variable template, the lambdas that initialize it.
#if defined(__clang__)
#define TBC_GENERIC [[clang::annotate("tbc::generic")]]
#else
#define TBC_GENERIC
#endif

// A method or function marked TBC_SWAPS exchanges storage ownership between its receiver and argument
// (or between its two arguments), as `std::swap` does: views into either object follow their storage
// to the new owner rather than being invalidated at the call.
#if defined(__clang__)
#define TBC_SWAPS [[clang::annotate("tbc::swaps")]]
#else
#define TBC_SWAPS
#endif

// A method or function marked TBC_UNINITIALIZED returns writable storage whose elements are not yet
// initialized: reading those elements before an initializing write is reported as
// `tbc-uninitialized-read`.
#if defined(__clang__)
#define TBC_UNINITIALIZED [[clang::annotate("tbc::uninitialized")]]
#else
#define TBC_UNINITIALIZED
#endif

// A function or method marked TBC_INITIALIZES writes every element of its writable buffer argument,
// establishing initialization for storage returned by `TBC_UNINITIALIZED`.
#if defined(__clang__)
#define TBC_INITIALIZES [[clang::annotate("tbc::initializes")]]
#else
#define TBC_INITIALIZES
#endif

// Declares an explicit directional outlives bound (`longer: shorter`) on a function declaration,
// allowing borrows in `longer` to supply results or targets in `shorter`.
#if defined(__clang__)
#define TBC_OUTLIVES(longer, shorter) [[clang::annotate("tbc::outlives:" #longer ":" #shorter)]]
#else
#define TBC_OUTLIVES(longer, shorter)
#endif

#endif
