#include "support.hpp"

using text_a = tbc::view<std::string_view, tbc::lt::a>;
using text_b = tbc::view<std::string_view, tbc::lt::b>;

void externalCall(std::span<const std::byte> input);

// CASE: contract.wrong_return_origin
// PAIR: contract.return_origin
// SOURCE: dlls/tbc/include/tbc/view.hpp :: view / lt::a / lt::b
// STATUS: implemented
// CONTRACT: The result has region a; region b has no declared outlives relationship to a.
// SCENARIO: Renaming source or other cannot change this contract. Returning other is invalid.
text_a wrongReturnOrigin(text_a source, text_b other) {
  spec::observe(source);
  return other; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: contract.correct_return_origin
// PAIR: contract.return_origin
// SOURCE: dlls/tbc/include/tbc/view.hpp :: view / lt::a
// STATUS: implemented
// CONTRACT: Both input views and the result share a caller-instantiated region a.
// SCENARIO: Either input may be returned; shared region does not mean shared storage or equal owner lifetimes.
text_a correctReturnOrigin(text_a first, text_a second) {
  return first.size() > second.size() ? first : second;
}

// END CASE

// CASE: contract.unknown_call
// PAIR: contract.call_boundary
// SOURCE: services/runtime-cpp/history/database.cpp :: Statement::bind
// STATUS: pending
// CONTRACT: Borrow-sensitive external calls need an analyzable implementation or a future boundary model.
// SCENARIO: This native declaration has neither; do not assume it cannot retain input.
void unknownCall(spec::bytes input) {
  externalCall(input); // expected-error [tbc-missing-contract]
}

// END CASE

// CASE: contract.explicit_noescape
// PAIR: contract.call_boundary
// SOURCE: services/runtime-cpp/history/database.cpp :: Statement::bind
// STATUS: pending
// CONTRACT: The visible observer body does not retain its borrowed argument.
// SCENARIO: Its view parameter is valid during this call and no state escapes it.
void explicitNoescape(spec::bytes input) {
  spec::observe(input);
}

// END CASE

namespace contracts {
  class session {
  public:
    tbc::view<const std::string &> title() const;
    tbc::view<const std::string &> pick(const std::string &other) const;

  private:
    std::string title_;
  };
}

// CASE: contract.elided_method_receiver
// PAIR: contract.elided_method
// SOURCE: services/gui-cpp/qt/configuration_source.cpp :: ConfigurationSource::input
// STATUS: implemented
// CONTRACT: A method's elided result follows its receiver, which callers in other translation units rely on.
// SCENARIO: The out-of-line definition returns the receiver's own field; accept.
tbc::view<const std::string &> contracts::session::title() const {
  return title_;
}

// END CASE

// CASE: contract.elided_method_parameter
// PAIR: contract.elided_method
// SOURCE: services/gui-cpp/qt/configuration_source.cpp :: ConfigurationSource::input
// STATUS: implemented
// CONTRACT: A method's elided result follows its receiver, which callers in other translation units rely on.
// SCENARIO: The out-of-line definition returns its parameter instead, which those callers would not track.
tbc::view<const std::string &> contracts::session::pick(const std::string &other) const {
  return other; // expected-error [tbc-contract-violation]
}

// END CASE
