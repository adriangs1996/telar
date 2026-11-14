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

#endif
