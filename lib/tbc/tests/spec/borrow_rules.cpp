#include "support.hpp"

#include <atomic>
#include <mutex>

namespace borrow_rules {
  struct pair_values {
    int first = 1;
    int second = 2;
  };

  struct owned_pair {
    std::string first = "alpha";
    std::string second = "beta";
  };

  struct mut_holder {
    int& ref;
  };

  struct drop_watcher {
    const int* watched = nullptr;
    ~drop_watcher();
  };

  void consume(std::string value);
  void touch(int& value);
}

// CASE: borrow.reborrow_parent_access
// PAIR: borrow.reborrow_suspension
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: checkExclusiveBorrowsAndMoves
// STATUS: implemented
// CONTRACT: Accessing a parent exclusive reference while its derived reborrow is still live is rejected.
// SCENARIO: Writing through parent while child is still used afterwards reports a conflicting access.
void borrowReborrowParentAccess() {
  int value = 1;
  tbc::view<int&> parent = value;
  tbc::view<int&> child = parent;
  parent += 1; // expected-error [tbc-conflicting-access]
  child += 1;
}

// END CASE

// CASE: borrow.reborrow_resumed
// PAIR: borrow.reborrow_suspension
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: checkExclusiveBorrowsAndMoves
// STATUS: implemented
// CONTRACT: Once a derived exclusive reborrow has no remaining use, the parent reference may be used again.
// SCENARIO: Child finishes before parent is accessed; accept.
void borrowReborrowResumed() {
  int value = 1;
  tbc::view<int&> parent = value;
  tbc::view<int&> child = parent;
  child += 1;
  parent += 1;
}

// END CASE

// CASE: borrow.two_phase_valid
// PAIR: borrow.two_phase
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: checkExclusiveBorrowsAndMoves
// STATUS: implemented
// CONTRACT: A two-phase method call allows reading the receiver while evaluating its arguments before activation.
// SCENARIO: Pushing the vector's own size reads the receiver before mutating it; accept.
void borrowTwoPhaseValid() {
  std::vector<std::size_t> values;
  values.push_back(values.size());
  spec::observe(values);
}

// END CASE

// CASE: borrow.two_phase_conflict
// PAIR: borrow.two_phase
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: checkExclusiveBorrowsAndMoves
// STATUS: implemented
// CONTRACT: Mutating a container while a shared reference into its storage remains live is rejected.
// SCENARIO: Reading a live reference into the vector after push_back reports invalidation.
void borrowTwoPhaseConflict() {
  std::vector<std::size_t> values{1, 2};
  const std::size_t& first = values[0];
  values.push_back(values.size()); // expected-error [tbc-invalidated-borrow]
  spec::observe(first);
}

// END CASE

// CASE: borrow.disjoint_fields_valid
// PAIR: borrow.disjoint_fields
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: placesOverlap
// STATUS: implemented
// CONTRACT: Distinct fields of the same struct may be mutably borrowed simultaneously.
// SCENARIO: Borrowing first and second fields independently and mutating both is accepted.
void borrowDisjointFieldsValid() {
  borrow_rules::pair_values pair;
  tbc::view<int&> a = pair.first;
  tbc::view<int&> b = pair.second;
  a += 1;
  b += 2;
  spec::observe(pair);
}

// END CASE

// CASE: borrow.same_field_conflict
// PAIR: borrow.disjoint_fields
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: placesOverlap
// STATUS: implemented
// CONTRACT: Two live mutable borrows of the same struct field conflict.
// SCENARIO: Creating a second mutable reference to pair.first while the first is live is rejected.
void borrowSameFieldConflict() {
  borrow_rules::pair_values pair;
  tbc::view<int&> a = pair.first;
  tbc::view<int&> b = pair.first; // expected-error [tbc-conflicting-borrow]
  a += 1;
  b += 2;
}

// END CASE

// CASE: borrow.two_objects_mut_conflict
// PAIR: borrow.two_objects_mut
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: extractAggregateBorrows
// STATUS: implemented
// CONTRACT: Two independent objects may not hold overlapping mutable references to the same place.
// SCENARIO: Constructing a second holder over the same mutable target while the first stays live is rejected.
void borrowTwoObjectsMutConflict() {
  int value = 1;
  borrow_rules::mut_holder first{value};
  borrow_rules::mut_holder second{value}; // expected-error [tbc-conflicting-borrow]
  first.ref += 1;
  second.ref += 1;
}

// END CASE

// CASE: borrow.two_objects_disjoint_valid
// PAIR: borrow.two_objects_mut
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: extractAggregateBorrows
// STATUS: implemented
// CONTRACT: Two independent objects holding mutable references to disjoint places do not conflict.
// SCENARIO: Each holder borrows a distinct variable; accept.
void borrowTwoObjectsDisjointValid() {
  int left = 1;
  int right = 2;
  borrow_rules::mut_holder first{left};
  borrow_rules::mut_holder second{right};
  first.ref += 1;
  second.ref += 1;
}

// END CASE

// CASE: move.use_after_move
// PAIR: move.ownership
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: extractMovedPlace
// STATUS: implemented
// CONTRACT: Reading an owning value after moving from it without reinitialization is rejected.
// SCENARIO: Passing std::move(text) transfers ownership; reading text afterward reports tbc-use-after-move.
void moveUseAfterMove() {
  std::string text = "hello";
  borrow_rules::consume(std::move(text));
  spec::observe(text); // expected-error [tbc-use-after-move]
}

// END CASE

// CASE: move.reassigned_after_move
// PAIR: move.ownership
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: extractMovedPlace
// STATUS: implemented
// CONTRACT: Reassigning a moved-from variable restores its initialized state.
// SCENARIO: Moving text, assigning a fresh string, and then observing it is accepted.
void moveReassignedAfterMove() {
  std::string text = "hello";
  borrow_rules::consume(std::move(text));
  text = "world";
  spec::observe(text);
}

// END CASE

// CASE: move.partial_field_move_bad
// PAIR: move.partial_fields
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: extractMovedPlace
// STATUS: implemented
// CONTRACT: Moving one field of a struct marks that field moved until reassigned.
// SCENARIO: Reading the moved field reports tbc-use-after-move.
void movePartialFieldMoveBad() {
  borrow_rules::owned_pair pair;
  borrow_rules::consume(std::move(pair.first));
  spec::observe(pair.first); // expected-error [tbc-use-after-move]
}

// END CASE

// CASE: move.partial_field_sibling_ok
// PAIR: move.partial_fields
// SOURCE: lib/tbc/linter/exclusive_borrows.cpp :: extractMovedPlace
// STATUS: implemented
// CONTRACT: Moving one field of a struct leaves its sibling fields initialized and usable.
// SCENARIO: Moving pair.first and then reading pair.second is accepted.
void movePartialFieldSiblingOk() {
  borrow_rules::owned_pair pair;
  borrow_rules::consume(std::move(pair.first));
  spec::observe(pair.second);
}

// END CASE

// CASE: drop.reverse_order_bad
// PAIR: drop.declaration_order
// SOURCE: lib/tbc/linter/lifetime_analysis.cpp :: checkDestructorDependency
// STATUS: implemented
// CONTRACT: A local with a non-trivial destructor must not hold a borrow of a local declared after it.
// SCENARIO: watcher is declared before value, so value is destroyed before ~drop_watcher runs.
void dropReverseOrderBad() {
  borrow_rules::drop_watcher watcher;
  int value = 7;
  watcher.watched = &value;
} // expected-error [tbc-destructor-dependency]

// END CASE

// CASE: drop.declaration_order_ok
// PAIR: drop.declaration_order
// SOURCE: lib/tbc/linter/lifetime_analysis.cpp :: checkDestructorDependency
// STATUS: implemented
// CONTRACT: A local declared after its referent is destroyed first, so its destructor observes live storage.
// SCENARIO: value outlives watcher in reverse destruction order; accept.
void dropDeclarationOrderOk() {
  int value = 7;
  borrow_rules::drop_watcher watcher;
  watcher.watched = &value;
}

// END CASE

// CASE: region.outlives_macro_ok
// PAIR: region.outlives_macro
// SOURCE: lib/tbc/include/tbc/annotations.hpp :: TBC_OUTLIVES
// STATUS: implemented
// CONTRACT: TBC_OUTLIVES(longer, shorter) allows returning a borrow of region longer as shorter.
// SCENARIO: b outlives a, so returning the b view as an a result is accepted.
TBC_OUTLIVES(b, a)
spec::text_a
regionOutlivesMacroOk(spec::text_a first, spec::text_b second) {
  return first.empty() ? second : first;
}

// END CASE

// CASE: region.outlives_macro_reversed
// PAIR: region.outlives_macro
// SOURCE: lib/tbc/include/tbc/annotations.hpp :: TBC_OUTLIVES
// STATUS: implemented
// CONTRACT: Outlives bounds are directional: TBC_OUTLIVES(b, a) does not imply a outlives b.
// SCENARIO: Returning an a view as a b result violates the declared directional bound.
TBC_OUTLIVES(b, a)
spec::text_b
regionOutlivesMacroReversed(spec::text_a first, spec::text_b second) {
  return second.empty() ? first : second; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: region.outlives_concept_ok
// PAIR: region.outlives_concept
// SOURCE: lib/tbc/include/tbc/view.hpp :: outlives
// STATUS: implemented
// CONTRACT: A trailing requires tbc::outlives<longer, shorter> clause establishes a directional outlives bound.
// SCENARIO: b outlives a via concept constraint, so returning second as text_a is accepted.
template <typename tag = void>
spec::text_a regionOutlivesConceptOk(spec::text_a first, spec::text_b second)
  requires tbc::outlives<tbc::lt::b, tbc::lt::a>
{
  return first.empty() ? second : first;
}

void instantiateOutlivesConceptOk(spec::text_a a, spec::text_b b) {
  spec::observe(regionOutlivesConceptOk(a, b));
}

// END CASE

// CASE: region.outlives_concept_reversed
// PAIR: region.outlives_concept
// SOURCE: lib/tbc/include/tbc/view.hpp :: outlives
// STATUS: implemented
// CONTRACT: Concept outlives bounds are directional and reject returning the shorter region as the longer one.
// SCENARIO: Returning first (region a) as text_b violates requires tbc::outlives<b, a>.
template <typename tag = void>
spec::text_b regionOutlivesConceptReversed(spec::text_a first, spec::text_b second)
  requires tbc::outlives<tbc::lt::b, tbc::lt::a>
{
  return second.empty() ? first : second; // expected-error [tbc-contract-violation]
}

void instantiateOutlivesConceptReversed(spec::text_a a, spec::text_b b) {
  spec::observe(regionOutlivesConceptReversed(a, b));
}

// END CASE

// CASE: soundness.mutable_member_bad
// PAIR: soundness.mutable_member
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkRecordSoundness
// STATUS: implemented
// CONTRACT: Plain mutable fields break shared immutability (Freeze) unless wrapped in a sync primitive or TBC_SHARED.
// SCENARIO: Declaring a mutable int member reports tbc-mutable-member.
struct bad_mutable_record {
  mutable int cached = 0; // expected-error [tbc-mutable-member]
};

// END CASE

// CASE: soundness.mutable_sync_ok
// PAIR: soundness.mutable_member
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkRecordSoundness
// STATUS: implemented
// CONTRACT: Synchronization primitives and TBC_SHARED classes explicitly opt into interior mutability.
// SCENARIO: mutable std::atomic and mutable std::mutex members are accepted.
struct good_mutable_record {
  mutable std::atomic<int> count{0};
  mutable std::mutex guard;
};

// END CASE

// CASE: soundness.const_cast_bad
// PAIR: soundness.const_cast
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkFunctionSoundness
// STATUS: implemented
// CONTRACT: Unaudited const_cast breaks shared immutability guarantees.
// SCENARIO: Stripping const directly with const_cast reports tbc-const-cast.
int* soundnessConstCastBad(const int* value) {
  return const_cast<int*>(value); // expected-error [tbc-const-cast]
}

// END CASE

// CASE: soundness.const_cast_raw_ok
// PAIR: soundness.const_cast
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkFunctionSoundness
// STATUS: implemented
// CONTRACT: Intentional FFI const_cast wrapped in tbc::raw() is explicitly audited and accepted.
// SCENARIO: Passing const_cast through tbc::raw() is accepted.
int* soundnessConstCastRawOk(const int* value) {
  return tbc::raw(const_cast<int*>(value));
}

// END CASE

// CASE: soundness.mutable_global_bad
// PAIR: soundness.mutable_global
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkFunctionSoundness
// STATUS: implemented
// CONTRACT: Unsynchronized mutable globals violate thread-safety and noalias assumptions.
// SCENARIO: Reading or writing a non-const non-atomic global reports tbc-mutable-global.
namespace {
  int global_counter = 0;
}

int soundnessMutableGlobalBad() {
  return global_counter; // expected-error [tbc-mutable-global]
}

// END CASE

// CASE: soundness.const_and_atomic_global_ok
// PAIR: soundness.mutable_global
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkFunctionSoundness
// STATUS: implemented
// CONTRACT: Immutable const globals and atomic globals are sound to access from any function.
// SCENARIO: Reading a const global and loading a std::atomic global are accepted.
namespace {
  const int fixed_limit = 16;
  std::atomic<int> atomic_counter{0};
}

int soundnessConstAndAtomicGlobalOk() {
  return fixed_limit + atomic_counter.load();
}

// END CASE

// CASE: soundness.conflicting_redecl_bad
// PAIR: soundness.redeclaration_contract
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkRedeclarationContracts
// STATUS: implemented
// CONTRACT: Redeclarations of the same function must agree on explicit region contracts.
// SCENARIO: Declaring a function with text_a and redeclaring it with text_b reports tbc-contract-violation.
spec::text_a redeclTarget(spec::text_a first, spec::text_b second);
spec::text_b redeclTarget(spec::text_a first, spec::text_b second); // expected-error [tbc-contract-violation]

// END CASE

// CASE: soundness.matching_redecl_ok
// PAIR: soundness.redeclaration_contract
// SOURCE: lib/tbc/linter/soundness_checks.cpp :: checkRedeclarationContracts
// STATUS: implemented
// CONTRACT: Redeclarations that repeat the same region contract agree and are accepted.
// SCENARIO: Matching declarations produce no diagnostic.
spec::text_a matchingRedeclTarget(spec::text_a first, spec::text_b second);
spec::text_a matchingRedeclTarget(spec::text_a first, spec::text_b second);

// END CASE

// CASE: init.uninitialized_local_read
// PAIR: init.definite_init
// SOURCE: lib/tbc/linter/access_validity.cpp :: checkAccessValidity
// STATUS: implemented
// CONTRACT: Reading an uninitialized scalar local variable is rejected.
// SCENARIO: Declaring int x without initializer and reading it reports tbc-uninitialized-read.
int initUninitializedLocalRead() {
  int uninit;
  return uninit; // expected-error [tbc-uninitialized-read]
}

// END CASE

// CASE: init.branch_initialized_local
// PAIR: init.definite_init
// SOURCE: lib/tbc/linter/access_validity.cpp :: checkAccessValidity
// STATUS: implemented
// CONTRACT: A local initialized on every reachable branch before reading is accepted.
// SCENARIO: Both branches assign value before returning it; accept.
int initBranchInitializedLocal(bool flag) {
  int value;
  if (flag) {
    value = 1;
  } else {
    value = 2;
  }
  return value;
}

// END CASE

// CASE: bounds.post_inc_second_unchecked
// PAIR: bounds.post_inc
// SOURCE: lib/tbc/linter/access_validity.cpp :: indexProvenInBounds
// STATUS: implemented
// CONTRACT: Post-incrementing an index inside a subscript consumes its proven upper bound for subsequent accesses.
// SCENARIO: The first arr[i++] is guarded, but the second arr[i] has no proof after increment.
int boundsPostIncSecondUnchecked(std::span<const int> values, std::size_t index) {
  if (index < values.size()) {
    const int first = values[index++];
    return first + values[index]; // expected-error [tbc-unproven-bounds]
  }
  return 0;
}

// END CASE

// CASE: bounds.post_inc_checked
// PAIR: bounds.post_inc
// SOURCE: lib/tbc/linter/access_validity.cpp :: indexProvenInBounds
// STATUS: implemented
// CONTRACT: A post-increment subscript evaluated under index < size() uses the pre-increment bounded index.
// SCENARIO: Returning values[index++] under index < values.size() is accepted.
int boundsPostIncChecked(std::span<const int> values, std::size_t& index) {
  if (index < values.size()) {
    return values[index++];
  }
  return 0;
}

// END CASE

// CASE: bounds.modulo_and_mask_ok
// PAIR: bounds.arithmetic_proofs
// SOURCE: lib/tbc/linter/access_validity.cpp :: indexProvenInBounds
// STATUS: implemented
// CONTRACT: Modulo by container size and bitmask below static extent prove in-bounds indices.
// SCENARIO: Indexing with modulo and power-of-two bitmask is accepted.
int boundsModuloAndMaskOk(std::span<const int> values, const std::array<int, 4>& fixed, std::size_t index) {
  if (values.empty()) {
    return fixed[index & 3U];
  }
  return values[index % values.size()] + fixed[index & 3U];
}

// END CASE

// CASE: bounds.unchecked_dynamic_bad
// PAIR: bounds.arithmetic_proofs
// SOURCE: lib/tbc/linter/access_validity.cpp :: indexProvenInBounds
// STATUS: implemented
// CONTRACT: Indexing a fixed array with an unguarded dynamic index is rejected.
// SCENARIO: Reading fixed[index] without bound check or bitmask reports tbc-unproven-bounds.
int boundsUncheckedDynamicBad(const std::array<int, 4>& fixed, std::size_t index) {
  return fixed[index]; // expected-error [tbc-unproven-bounds]
}

// END CASE

// CASE: nullability.nullable_field_bad
// PAIR: nullability.nullable_field
// SOURCE: lib/tbc/linter/access_validity.cpp :: isUnprovenNullablePointer
// STATUS: implemented
// CONTRACT: A pointer field default-initialized to nullptr must be guarded before dereferencing on this.
// SCENARIO: Dereferencing node_ without null check reports tbc-nullable-dereference.
struct nullable_field_holder {
  int* node_ = nullptr;

  int readUnchecked() const {
    return *node_; // expected-error [tbc-nullable-dereference]
  }
};

// END CASE

// CASE: nullability.nullable_field_guarded
// PAIR: nullability.nullable_field
// SOURCE: lib/tbc/linter/access_validity.cpp :: isUnprovenNullablePointer
// STATUS: implemented
// CONTRACT: Checking a nullable pointer field against nullptr proves it non-null on the guarded branch.
// SCENARIO: Guarding node_ != nullptr before dereference is accepted.
struct guarded_field_holder {
  int* node_ = nullptr;

  int readChecked() const {
    if (node_ != nullptr) {
      return *node_;
    }
    return 0;
  }
};

// END CASE
