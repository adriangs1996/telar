#include "system_macro.hpp"

#include <string_view>

namespace project {
  std::string_view opaque(std::string_view first, std::string_view second);
}

// CASE: system_macro.own_expression
// PAIR: system_macro.boundary
// SOURCE: lib/ebnf/tests/term_test.cpp :: EXPECT_EQ
// STATUS: implemented
// CONTRACT: An unannotated borrowed value created and used by a system macro's own expansion is not the project's missing contract.
// SCENARIO: The opaque call and its use are both spelled by the system header; accept.
void systemMacroOwnExpression(std::string_view source) {
  SYSTEM_MACRO_CHECK(source);
}

// END CASE

// CASE: system_macro.project_expression
// PAIR: system_macro.boundary
// SOURCE: lib/ebnf/tests/term_test.cpp :: EXPECT_EQ
// STATUS: implemented
// CONTRACT: A project expression passed to a system macro keeps its missing-contract diagnostic.
// SCENARIO: The opaque call is spelled by the project as a macro argument.
void systemMacroProjectExpression(std::string_view source) {
  SYSTEM_MACRO_CONSUME(project::opaque(source, source)); // expected-error [tbc-missing-contract]
}

// END CASE
