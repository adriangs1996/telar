// Excluded from the corpus: exclusive aliasing is a Rust access policy, not a C++ memory error.
// The linter's objective is invalid memory use; these cases are kept as reference only.
#include "../support.hpp"

using int_view = tbc::view<const int &, tbc::lt::a>;

// CASE: core.shared_write
// PAIR: core.shared_liveness
// SOURCE: dlls/ebnf/lexer.hpp :: token
// STATUS: pending
// CONTRACT: Shared references protect their referent from writes while required.
// SCENARIO: The later read keeps the loan live; diagnose the intervening write.
void sharedWrite() {
  int value = 1;
  tbc::view<const int &> view = value;
  value = 2; // expected-error [tbc-conflicting-access]
  spec::observe(view);
}

// END CASE

// CASE: core.ended_shared
// PAIR: core.shared_liveness
// SOURCE: dlls/ebnf/lexer.hpp :: token
// STATUS: pending
// CONTRACT: A loan with no remaining use or observing destructor may end before scope exit.
// SCENARIO: The view is consumed before the write; accept the later mutation.
void endedShared() {
  int value = 1;
  tbc::view<const int &> view = value;
  spec::observe(view);
  value = 2;
  spec::observe(value);
}

// END CASE

// CASE: core.overlapping_mutable
// PAIR: core.reborrow
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: appendUninitialized
// STATUS: pending
// CONTRACT: A live exclusive loan forbids an independent overlapping mutable loan.
// SCENARIO: Both references remain used; report creation of the second loan.
void overlappingMutable() {
  int value = 1;
  tbc::view<int &> first = value;
  tbc::view<int &> second = value; // expected-error [tbc-conflicting-borrow]
  first += 1;
  second += 1;
  spec::observe(value);
}

// END CASE

// CASE: core.derived_reborrow
// PAIR: core.reborrow
// SOURCE: services/runtime-cpp/memory/byte_queue.hpp :: appendUninitialized
// STATUS: pending
// CONTRACT: A derived exclusive reborrow temporarily suspends conflicting parent access.
// SCENARIO: Use the child, end its scope, then resume the parent; accept.
void derivedReborrow() {
  int value = 1;
  tbc::view<int &> parent = value;
  {
    tbc::view<int &> child = parent;
    child += 1;
  }
  parent += 1;
}

// END CASE
