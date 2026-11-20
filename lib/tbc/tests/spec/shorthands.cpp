#include "support.hpp"

namespace spec::shorthands {
  struct Payload {
    int value = 0;
    std::string_view name;
  };
}

// CASE: shorthands.ref_argument_return
// PAIR: shorthands.ref
// SOURCE: lib/tbc/include/tbc/view.hpp :: ref_a
// STATUS: implemented
// CONTRACT: ref_a<T> is view<const T&, lt::a>: the result borrows what the input of region a designates.
// SCENARIO: Return a field of the input, which the caller supplies.
tbc::ref_a<int> refField(tbc::ref_a<spec::shorthands::Payload> input) {
  return input.value;
}

// END CASE

// CASE: shorthands.ref_other_region
// PAIR: shorthands.ref
// SOURCE: lib/tbc/include/tbc/view.hpp :: ref_a, ref_b
// STATUS: implemented
// CONTRACT: ref_a and ref_b name independent regions, as view<const T&, lt::a> and view<const T&, lt::b> do.
// SCENARIO: The result is declared in region a but borrows the input of region b.
tbc::ref_a<int> refOther(tbc::ref_a<spec::shorthands::Payload> input, tbc::ref_b<spec::shorthands::Payload> other) {
  return other.value; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: shorthands.mut_argument_return
// PAIR: shorthands.mut
// SOURCE: lib/tbc/include/tbc/view.hpp :: mut_a
// STATUS: implemented
// CONTRACT: mut_a<T> is view<T&, lt::a>: a mutable result borrows the mutable input of region a.
// SCENARIO: Return a mutable field of the input.
tbc::mut_a<int> mutField(tbc::mut_a<spec::shorthands::Payload> input) {
  return input.value;
}

// END CASE

// CASE: shorthands.mut_local_escape
// PAIR: shorthands.mut
// SOURCE: lib/tbc/include/tbc/view.hpp :: mut_a
// STATUS: implemented
// CONTRACT: A mutable result of region a cannot borrow the callee's local storage.
// SCENARIO: Return a field of a local payload.
tbc::mut_a<int> mutLocal() {
  spec::shorthands::Payload local;
  return local.value; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: shorthands.val_argument_return
// PAIR: shorthands.val
// SOURCE: lib/tbc/include/tbc/view.hpp :: val_a
// STATUS: implemented
// CONTRACT: val_a<T> is view<T, lt::a>: a value that holds borrows of region a, as a string_view does.
// SCENARIO: Return the view the input holds, whose text the caller keeps alive.
tbc::val_a<std::string_view> valName(tbc::ref_a<spec::shorthands::Payload> input) {
  return input.name;
}

// END CASE

// CASE: shorthands.val_local_escape
// PAIR: shorthands.val
// SOURCE: lib/tbc/include/tbc/view.hpp :: val_a
// STATUS: implemented
// CONTRACT: A value of region a cannot view the callee's local storage.
// SCENARIO: Return a view of a local string.
tbc::val_a<std::string_view> valLocal() {
  const std::string local = "local";
  return local; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: shorthands.static_literal
// PAIR: shorthands.static
// SOURCE: lib/tbc/include/tbc/view.hpp :: val_static
// STATUS: implemented
// CONTRACT: val_static<T> is view<T, lt::static_storage>: the value views only storage that outlives every caller.
// SCENARIO: Return a string literal.
tbc::val_static<std::string_view> staticLiteral() {
  return "literal";
}

// END CASE

// CASE: shorthands.static_argument
// PAIR: shorthands.static
// SOURCE: lib/tbc/include/tbc/view.hpp :: val_static
// STATUS: implemented
// CONTRACT: A static result never depends on an argument.
// SCENARIO: Return the view the input holds as static storage.
tbc::val_static<std::string_view> staticArgument(tbc::ref_a<spec::shorthands::Payload> input) {
  return input.name; // expected-error [tbc-contract-violation]
}

// END CASE
