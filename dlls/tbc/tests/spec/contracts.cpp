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

namespace contracts {
  using static_text = tbc::view<std::string_view, tbc::lt::static_storage>;

  static_text formatName(std::string_view requested);

  constexpr std::string_view png_name = "image/png";
}

// CASE: contract.static_result_caller
// PAIR: contract.static_result
// SOURCE: dlls/clipboard/includes/clipboard.hpp :: read / content::mime_type
// STATUS: implemented
// CONTRACT: A static result borrows storage that outlives every caller, never an argument.
// SCENARIO: The declaration has no visible body; its result stays valid after the temporary argument dies.
void staticResultCaller() {
  const auto name = contracts::formatName(std::string{"image/png"});
  spec::observe(name);
}

// END CASE

// CASE: contract.static_result_definition
// PAIR: contract.static_result
// SOURCE: dlls/clipboard/src/linux/backend.hpp :: formats
// STATUS: implemented
// CONTRACT: A static result may come from a string literal or an object with static storage duration.
// SCENARIO: Both returns name storage that no caller can outlive; accept.
contracts::static_text staticResultDefinition(bool literal) {
  if (literal) {
    return "text/plain";
  }
  return contracts::png_name;
}

// END CASE

// CASE: contract.static_result_parameter
// PAIR: contract.static_result
// SOURCE: dlls/clipboard/src/clipboard.mm :: copyData
// STATUS: implemented
// CONTRACT: A static result may come from a string literal or an object with static storage duration.
// SCENARIO: Returning the caller's view would let it dangle once the caller's storage dies.
contracts::static_text contracts::formatName(std::string_view requested) {
  return requested; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: contract.opaque_constructor_escape
// PAIR: contract.opaque_constructor
// SOURCE: services/runtime-cpp/history/store.cppm :: Statement
// STATUS: implemented
// CONTRACT: A constructor without a visible body retains every argument whose parameter shares a region with a field of its class.
// SCENARIO: A prepared statement retains its local database and is returned; reject.
namespace contracts {
  struct handle {};

  class database {
  public:
    database();
    database(const database &) = delete;
    database &operator=(const database &) = delete;
  };

  class statement {
  public:
    statement(tbc::view<database &, tbc::lt::a> owner, std::string_view sql);
    statement(statement &&) noexcept;

  private:
    tbc::view<handle *, tbc::lt::a> handle_ = nullptr;
  };
}

contracts::statement opaqueConstructorEscape() {
  contracts::database owner;
  return contracts::statement{owner, "SELECT 1"}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: contract.opaque_constructor_retained
// PAIR: contract.opaque_constructor
// SOURCE: services/runtime-cpp/history/store.cppm :: Statement
// STATUS: implemented
// CONTRACT: A constructor without a visible body retains every argument whose parameter shares a region with a field of its class.
// SCENARIO: The statement borrows the caller's database and its temporary query text is not retained; accept.
contracts::statement opaqueConstructorRetained(contracts::database &owner) {
  return contracts::statement{owner, std::string{"SELECT 1"}};
}

// END CASE
