#include "support.hpp"

// CASE: flow.branch_invalidates
// PAIR: flow.branch_paths
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: reserve
// STATUS: pending
// CONTRACT: A borrow needed after a join must survive every incoming reachable path.
// SCENARIO: Only one branch reallocates, but that path still reaches the old view's read.
void branchInvalidates(tbc::view<spec::byte_queue &> queue, bool grow) {
  const auto view = queue.readable();
  if (grow) {
    queue.reserve(1024); // expected-error [tbc-invalidated-borrow]
  }
  spec::observe(view);
}

// END CASE

// CASE: flow.invalidating_branch_returns
// PAIR: flow.branch_paths
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: reserve
// STATUS: pending
// CONTRACT: A view need not stay live on a path which cannot reach a later use.
// SCENARIO: The invalidating branch returns; the read is reachable only without growth.
void invalidatingBranchReturns(tbc::view<spec::byte_queue &> queue, bool grow) {
  const auto view = queue.readable();
  if (grow) {
    queue.reserve(1024);
    return;
  }
  spec::observe(view);
}

// END CASE

// CASE: flow.unwind_destroys_source
// PAIR: flow.exception_cleanup
// SOURCE: services/runtime-cpp/memory/allocator.hpp :: makeOwned exception cleanup
// STATUS: pending
// CONTRACT: Unwinding destroys local owners before entering the surrounding handler.
// SCENARIO: A descriptor assigned outside try still points into an unwound local string.
void unwindDestroysSource() {
  spec::text view;
  try {
    const std::string local{"temporary"};
    view = local;
    throw 1; // expected-error [tbc-invalidated-borrow]
  } catch (...) {
    spec::observe(view);
  }
}

// END CASE

// CASE: flow.unwind_preserves_owned_copy
// PAIR: flow.exception_cleanup
// SOURCE: services/runtime-cpp/memory/allocator.hpp :: makeOwned exception cleanup
// STATUS: pending
// CONTRACT: An owned copy declared outside try is not destroyed by unwinding its inner scope.
// SCENARIO: Copy the text before throwing; catch may safely read the independent owner.
void unwindPreservesOwnedCopy() {
  std::string copied;
  try {
    const std::string local{"temporary"};
    copied = spec::copyText(local);
    throw 1;
  } catch (...) {
    spec::observe(copied);
  }
}

// END CASE
