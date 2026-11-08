#include "support.hpp"

// CASE: runtime.allocator_escape
// PAIR: runtime.allocator_dependency
// SOURCE: lib/telar-base/include/telar_base/memory/allocator.hpp :: AllocationDeleter / makeOwned
// STATUS: pending
// CONTRACT: An allocated owner's deleter borrows the allocator until owner destruction.
// SCENARIO: Heap-allocated pointee lifetime does not rescue a dead stack allocator.
tbc::view<spec::allocated_int, tbc::lt::a> allocatorEscape() {
  spec::arena memory;
  return spec::makeOwned(memory); // expected-error [tbc-destructor-dependency]
}

// END CASE

// CASE: runtime.allocator_caller_owned
// PAIR: runtime.allocator_dependency
// SOURCE: lib/telar-base/include/telar_base/memory/allocator.hpp :: AllocationDeleter / makeOwned
// STATUS: pending
// CONTRACT: A returned owner's allocator dependency is propagated to its caller.
// SCENARIO: The allocator is borrowed from a reference parameter, not created locally.
tbc::view<spec::allocated_int, tbc::lt::a> allocatorCallerOwned(tbc::view<spec::arena &, tbc::lt::a> memory) {
  return spec::makeOwned(memory);
}

// END CASE

// CASE: runtime.moved_owner_releases_view
// PAIR: runtime.owner_transfer
// SOURCE: lib/telar-base/include/telar_base/memory/allocator.hpp :: Owned
// STATUS: implemented
// CONTRACT: Moving unique_ptr transfers ownership; destroying the new owner invalidates views.
// SCENARIO: Follow the allocation to destination and diagnose reset, not the prior move.
void movedOwnerReleasesView() {
  auto source = std::make_unique<int>(1);
  tbc::view<const int &> view = *source;
  auto destination = std::move(source);
  destination.reset(); // expected-error [tbc-invalidated-borrow]
  spec::observe(view);
}

// END CASE

// CASE: runtime.moved_owner_preserves_view
// PAIR: runtime.owner_transfer
// SOURCE: lib/telar-base/include/telar_base/memory/allocator.hpp :: Owned
// STATUS: implemented
// CONTRACT: Moving a unique_ptr does not move its pointee or immediately dangle its views.
// SCENARIO: Accept a pointee read while the transferred allocation remains owned.
void movedOwnerPreservesView() {
  auto source = std::make_unique<int>(1);
  tbc::view<const int &> view = *source;
  auto destination = std::move(source);
  spec::observe(view);
  spec::observe(destination);
}

// END CASE

// CASE: runtime.queue_slot_removed
// PAIR: runtime.queue_slot
// SOURCE: src/runtime-cpp/platform/request_worker.cppm :: operator[] / take
// STATUS: pending
// CONTRACT: take destroys the old optional slot object after transferring its value.
// SCENARIO: A reference to that slot is invalid even if its value was moved elsewhere.
void queueSlotRemoved(tbc::view<spec::request_queue &> queue) {
  const auto &view = queue.front();
  const auto taken = queue.take(); // expected-error [tbc-invalidated-borrow]
  spec::observe(view);
  spec::observe(taken);
}

// END CASE

// CASE: runtime.queue_taken_owner
// PAIR: runtime.queue_slot
// SOURCE: src/runtime-cpp/platform/request_worker.cppm :: take
// STATUS: pending
// CONTRACT: The returned string owns its transferred value independently of the old slot.
// SCENARIO: A view acquired from the taken string remains valid after more queue removals.
void queueTakenOwner(tbc::view<spec::request_queue &> queue) {
  const auto taken = queue.take();
  spec::text view = taken;
  const auto other = queue.take();
  spec::observe(view);
  spec::observe(other);
}

// END CASE
