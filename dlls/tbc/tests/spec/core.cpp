#include "support.hpp"

using int_view = tbc::view<const int &, tbc::lt::a>;

// CASE: core.local_escape
// PAIR: core.direct_return
// SOURCE: dlls/tbc/include/tbc/view.hpp :: view
// STATUS: implemented
// CONTRACT: A returned view cannot borrow a callee's local storage.
// SCENARIO: The result survives the local int; diagnose the escaping return.
int_view localEscape() {
  const int local = 1;
  return local; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: core.argument_return
// PAIR: core.direct_return
// SOURCE: dlls/tbc/include/tbc/view.hpp :: view
// STATUS: implemented
// CONTRACT: The input and result share region a; the caller supplies the referent.
// SCENARIO: Return the input reference without creating another owner or local referent.
int_view argumentReturn(int_view input) {
  return input;
}

// END CASE

// CASE: core.alias_escape
// PAIR: core.alias_return
// SOURCE: dlls/tbc/include/tbc/view.hpp :: view
// STATUS: implemented
// CONTRACT: Copying a view preserves its origin and cannot extend that origin's life.
// SCENARIO: Follow a local borrow through an alias and reject its return.
int_view aliasEscape() {
  const int local = 1;
  const int_view original = local;
  const auto &alias = original;
  return alias; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: core.alias_argument
// PAIR: core.alias_return
// SOURCE: dlls/tbc/include/tbc/view.hpp :: view
// STATUS: implemented
// CONTRACT: With one borrowed input, elision binds the returned reference to that input.
// SCENARIO: A local alias of the argument preserves its origin without an explicit region label.
tbc::view<const int &> aliasArgument(tbc::view<const int &> input) {
  const auto &alias = input;
  return alias;
}

// END CASE
