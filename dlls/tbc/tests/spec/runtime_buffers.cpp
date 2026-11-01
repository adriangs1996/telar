#include "support.hpp"

// CASE: runtime.queue_reallocation
// PAIR: runtime.queue_growth
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: readable / reserve
// STATUS: pending
// CONTRACT: reserve may free the storage used by readable views.
// SCENARIO: Diagnose the invalidating call because an old view is read afterward.
void queueReallocation(tbc::view<spec::byte_queue &> queue) {
  const auto view = queue.readable();
  queue.reserve(1024); // expected-error [tbc-invalidated-borrow]
  spec::observe(view);
}

// END CASE

// CASE: runtime.queue_growth_after_read
// PAIR: runtime.queue_growth
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: readable / reserve
// STATUS: pending
// CONTRACT: Invalidating storage is legal after its borrowed view is no longer required.
// SCENARIO: Read the old view before reserve and obtain a fresh view afterward.
void queueGrowthAfterRead(tbc::view<spec::byte_queue &> queue) {
  spec::observe(queue.readable());
  queue.reserve(1024);
  spec::observe(queue.readable());
}

// END CASE

// CASE: runtime.queue_compaction
// PAIR: runtime.queue_compaction
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: compact / appendUninitialized
// STATUS: pending
// CONTRACT: Compaction changes the logical elements denoted by old views even without allocation.
// SCENARIO: Address stability alone cannot preserve an old logical view.
void queueCompaction(tbc::view<spec::byte_queue &> queue) {
  const auto view = queue.readable();
  queue.compact(); // expected-error [tbc-invalidated-borrow]
  spec::observe(view);
}

// END CASE

// CASE: runtime.queue_copied_before_compaction
// PAIR: runtime.queue_compaction
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: compact
// STATUS: pending
// CONTRACT: A vector copied from the readable range owns independent elements.
// SCENARIO: Compaction cannot invalidate the copied bytes; accept.
void queueCopiedBeforeCompaction(tbc::view<spec::byte_queue &> queue) {
  const auto view = queue.readable();
  const std::vector<std::byte> copied{view.begin(), view.end()};
  queue.compact();
  spec::observe(copied);
}

// END CASE

// CASE: runtime.read_local_destination
// PAIR: runtime.destination_origin
// SOURCE: services/runtime-cpp/memory/retained_stream.hpp :: read
// STATUS: pending
// CONTRACT: read returns a view of destination, not of the stream receiver.
// SCENARIO: A long-lived stream cannot make a local destination escape safely.
spec::bytes_a readLocalDestination(tbc::view<const spec::retained_stream &, tbc::lt::b> stream) {
  std::array<std::byte, 8> destination{};
  return stream.read(destination); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: runtime.read_caller_destination
// PAIR: runtime.destination_origin
// SOURCE: services/runtime-cpp/memory/retained_stream.hpp :: read
// STATUS: pending
// CONTRACT: The result is bounded by destination storage, independently of receiver lifetime.
// SCENARIO: A local stream may die while its caller-backed output view is returned.
spec::bytes_a readCallerDestination(spec::writable_bytes_a destination) {
  const spec::retained_stream stream;
  return stream.read(destination);
}

// END CASE

// CASE: runtime.read_uninitialized_append
// PAIR: runtime.append_initialization
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: appendUninitialized
// STATUS: pending
// CONTRACT: appendUninitialized grants writable storage, not initialized values.
// SCENARIO: Reject a read of the appended range before any initializing write.
void readUninitializedAppend(tbc::view<spec::byte_queue &> queue) {
  const auto writable = queue.appendUninitialized(8);
  spec::observe(writable); // expected-error [tbc-uninitialized-read]
}

// END CASE

// CASE: runtime.initialize_append
// PAIR: runtime.append_initialization
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: appendUninitialized / append
// STATUS: pending
// CONTRACT: The initializer must establish initialization for every output element; this effect remains a pending model.
// SCENARIO: The read follows initialize, so the writable span now contains values.
void initializeAppend(tbc::view<spec::byte_queue &> queue) {
  const auto writable = queue.appendUninitialized(8);
  spec::initialize(writable);
  spec::observe(writable);
}

// END CASE
