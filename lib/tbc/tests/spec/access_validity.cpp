#include "support.hpp"

// CASE: access.unchecked_index
// PAIR: access.index_bounds
// SOURCE: src/gui-cpp/fonts/face.cppm :: GlyphBitmapView::row
// STATUS: pending
// CONTRACT: The safety profile requires a proven bound or a checked access operation.
// SCENARIO: An arbitrary index is not proven smaller than the span length.
void uncheckedIndex(tbc::view<std::span<const int>> values, std::size_t index) {
  spec::observe(values[index]); // expected-error [tbc-unproven-bounds]
}

// END CASE

// CASE: access.guarded_index
// PAIR: access.index_bounds
// SOURCE: src/gui-cpp/fonts/face.cppm :: GlyphBitmapView::row
// STATUS: pending
// CONTRACT: The guard establishes the exact inequality required by this indexing operation.
// SCENARIO: Reject the out-of-range path before performing the access.
void guardedIndex(tbc::view<std::span<const int>> values, std::size_t index) {
  if (index >= values.size()) {
    return;
  }
  spec::observe(values[index]);
}

// END CASE

// CASE: access.nullable_dereference
// PAIR: access.pointer_nullability
// SOURCE: lib/telar-base/include/telar_base/memory/allocator.hpp :: AllocatorRef::allocate
// STATUS: pending
// CONTRACT: A nullable borrowed parameter must be proven non-null before dereference.
// SCENARIO: A borrowed pointer may be null; view does not promise that allocation succeeded.
void nullableDereference(tbc::view<const int *> input) {
  spec::observe(*input); // expected-error [tbc-nullable-dereference]
}

// END CASE

// CASE: access.guarded_pointer
// PAIR: access.pointer_nullability
// SOURCE: lib/telar-base/include/telar_base/memory/allocator.hpp :: AllocatorRef::allocate
// STATUS: pending
// CONTRACT: The null guard establishes dereferenceability only with respect to nullness.
// SCENARIO: Caller-provided storage validity is a precondition; the guarded access is accepted.
void guardedPointer(tbc::view<const int *> input) {
  if (input == nullptr) {
    return;
  }
  spec::observe(*input);
}

// END CASE
