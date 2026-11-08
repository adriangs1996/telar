#include "elision.hpp"
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

// CASE: contract.elided_call_temporary
// PAIR: contract.elided_call
// SOURCE: services/gui-cpp/qt/application.hpp :: Application::session
// STATUS: implemented
// CONTRACT: A method declared without a contract and without a visible body returns a borrow of its receiver, as Rust's lifetime elision gives it.
// SCENARIO: The receiver is a temporary that dies before the result is read.
void elidedCallTemporary() {
  const auto &label = elision::registry{}.label(); // expected-error [tbc-dangling-borrow]
  spec::observe(std::string_view{label});
}

// END CASE

// CASE: contract.elided_call_receiver
// PAIR: contract.elided_call
// SOURCE: services/gui-cpp/qt/application.hpp :: Application::session
// STATUS: implemented
// CONTRACT: A method declared without a contract and without a visible body returns a borrow of its receiver, as Rust's lifetime elision gives it.
// SCENARIO: The receiver outlives the result; accept.
void elidedCallReceiver(const elision::registry &registry) {
  spec::observe(std::string_view{registry.label()});
}

// END CASE

// CASE: contract.elided_definition_parameter
// PAIR: contract.elided_definition
// SOURCE: services/gui-cpp/qt/application.hpp :: Application::session
// STATUS: implemented
// CONTRACT: An out-of-line definition keeps the elided contract its callers assume without the body.
// SCENARIO: A method returns its parameter, which callers that only see the declaration take for a borrow of the receiver.
const std::string &elision::registry::pick(const std::string &fallback) const {
  return fallback; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: contract.elided_definition_receiver
// PAIR: contract.elided_definition
// SOURCE: services/gui-cpp/qt/application.hpp :: Application::session
// STATUS: implemented
// CONTRACT: An out-of-line definition keeps the elided contract its callers assume without the body.
// SCENARIO: A method returns its receiver's field; accept.
const std::string &elision::registry::name() const {
  return name_;
}

// END CASE

// CASE: contract.self_field_internal
// PAIR: contract.self_field
// SOURCE: services/gui-cpp/qt/font_asset.hpp :: FontAsset
// STATUS: implemented
// CONTRACT: A field labeled lt::self borrows only its own pinned object, so the object holds no borrow of anything else.
// SCENARIO: Shared pinned objects whose only borrow is internal cross an opaque two-input call without a contract; accept.
namespace contracts {
  class self_text {
  public:
    self_text()
        : cursor_(storage_.data()) {}

    self_text(const self_text &) = delete;
    self_text &operator=(const self_text &) = delete;

  private:
    std::string storage_{"abc"};
    tbc::view<const char *, tbc::lt::self> cursor_;
  };

  std::shared_ptr<const self_text> chooseSelf(const std::shared_ptr<const self_text> &first, const std::shared_ptr<const self_text> &second);
  void keep(const std::shared_ptr<const self_text> &text);
}

void selfFieldInternal(const std::shared_ptr<const contracts::self_text> &first, const std::shared_ptr<const contracts::self_text> &second) {
  contracts::keep(contracts::chooseSelf(first, second));
}

// END CASE

// CASE: contract.self_field_unlabeled
// PAIR: contract.self_field
// SOURCE: services/gui-cpp/qt/font_asset.hpp :: FontAsset
// STATUS: implemented
// CONTRACT: A field labeled lt::self borrows only its own pinned object, so the object holds no borrow of anything else.
// SCENARIO: Without the label, the object keeps a borrow of itself, rejected where it is taken; its pointer may then borrow anything, so the opaque two-input call needs a contract.
namespace contracts {
  class borrowed_text {
  public:
    borrowed_text()
        : cursor_(storage_.data()) {} // expected-error [tbc-dangling-borrow]

    borrowed_text(const borrowed_text &) = delete;
    borrowed_text &operator=(const borrowed_text &) = delete;

  private:
    std::string storage_{"abc"};
    const char *cursor_;
  };

  std::shared_ptr<const borrowed_text> chooseBorrowed(const std::shared_ptr<const borrowed_text> &first, const std::shared_ptr<const borrowed_text> &second);
  void keep(const std::shared_ptr<const borrowed_text> &text);
}

void selfFieldUnlabeled(const std::shared_ptr<const contracts::borrowed_text> &first, const std::shared_ptr<const contracts::borrowed_text> &second) {
  contracts::keep(contracts::chooseBorrowed(first, second)); // expected-error [tbc-missing-contract]
}

// END CASE

// CASE: contract.self_field_relocatable
// PAIR: contract.self_field
// SOURCE: services/gui-cpp/qt/font_asset.hpp :: FontAsset
// STATUS: implemented
// CONTRACT: A field labeled lt::self borrows only its own pinned object, so the object holds no borrow of anything else.
// SCENARIO: A copy would carry the internal borrow away from its object; reject the labeled field's initializer.
namespace contracts {
  class copied_text {
  public:
    copied_text()
        : cursor_(storage_.data()) {} // expected-error [tbc-dangling-borrow]

  private:
    std::string storage_{"abc"};
    tbc::view<const char *, tbc::lt::self> cursor_;
  };
}

void selfFieldRelocatable() {
  const contracts::copied_text text;
  static_cast<void>(text);
}

// END CASE

// CASE: contract.self_field_mutation
// PAIR: contract.self_field
// SOURCE: services/gui-cpp/qt/application.cpp :: Application
// STATUS: implemented
// CONTRACT: A field labeled lt::self borrows only its own pinned object, so the object holds no borrow of anything else.
// SCENARIO: A pinned object's labeled field keeps the object and a sibling, and the constructor then mutates the object; the internal borrows are not the object's, so nothing is invalidated; accept.
namespace contracts {
  template <typename Host>
  class text_watcher {
  public:
    text_watcher(Host &host, std::string &text)
        : host_(host),
          text_(text) {}

  private:
    Host &host_;
    std::string &text_;
  };

  class watched_text {
  public:
    watched_text()
        : watcher_(*this, storage_) {
      grow();
      grow();
    }

    watched_text(const watched_text &) = delete;
    watched_text &operator=(const watched_text &) = delete;

    void grow();

  private:
    std::string storage_{"abc"};
    tbc::view<text_watcher<watched_text>, tbc::lt::self> watcher_;
  };
}

void selfFieldMutation() {
  contracts::watched_text text;
  text.grow();
  text.grow();
}

// END CASE

// CASE: contract.elided_constructor_escape
// PAIR: contract.elided_constructor
// SOURCE: services/gui-cpp/qt/ancestor_geometry.hpp :: AncestorGeometry
// STATUS: implemented
// CONTRACT: A constructor without a visible body and without labeled fields may retain any argument that can lend.
// SCENARIO: The object outlives the temporary text it was built from; reject.
namespace contracts {
  class labeled_text {
  public:
    explicit labeled_text(std::string_view text);
    [[nodiscard]] std::size_t size() const;

  private:
    std::string_view text_;
  };
}

std::size_t elidedConstructorEscape() {
  const contracts::labeled_text text{std::string{"abc"}}; // expected-error [tbc-dangling-borrow]
  return text.size();
}

// END CASE

// CASE: contract.elided_constructor_retained
// PAIR: contract.elided_constructor
// SOURCE: services/gui-cpp/qt/ancestor_geometry.hpp :: AncestorGeometry
// STATUS: implemented
// CONTRACT: A constructor without a visible body and without labeled fields may retain any argument that can lend.
// SCENARIO: The text outlives the object; accept.
std::size_t elidedConstructorRetained(std::string_view source) {
  const contracts::labeled_text text{source};
  return text.size();
}

// END CASE

// CASE: contract.library_override
// PAIR: contract.elided_definition
// SOURCE: services/gui-cpp/qt/native_cell_text.cpp :: NativeCellText::updatePaintNode
// STATUS: implemented
// CONTRACT: An out-of-line definition keeps the elided contract its callers assume without the body.
// SCENARIO: An override of a library virtual takes its contract from the library, whose callers are not checked; it returns the node it was given; accept.
library::node *elision::painted_item::update(library::node *previous) {
  return previous;
}

// END CASE

// CASE: contract.labeled_field_storage
// PAIR: contract.labeled_field
// SOURCE: services/gui-cpp/qt/configuration_source.hpp :: ConfigurationSource::commandTab
// STATUS: implemented
// CONTRACT: What a field labeled with the result's region owns lives in that region, as a field of `&'a self` does.
// SCENARIO: The result views the string the labeled field owns; accept.
namespace contracts {
  class owned_label {
  public:
    tbc::view<std::string_view, tbc::lt::a> text() const {
      return *text_;
    }

  private:
    tbc::view<std::unique_ptr<std::string>, tbc::lt::a> text_ = std::make_unique<std::string>("abc");
  };
}

// END CASE

// CASE: contract.labeled_field_other
// PAIR: contract.labeled_field
// SOURCE: services/gui-cpp/qt/configuration_source.hpp :: ConfigurationSource::commandTab
// STATUS: implemented
// CONTRACT: What a field labeled with the result's region owns lives in that region, as a field of `&'a self` does.
// SCENARIO: The result views a string an unlabeled field owns; reject.
namespace contracts {
  class unlabeled_owner {
  public:
    tbc::view<std::string_view, tbc::lt::a> text() const {
      return *text_; // expected-error [tbc-contract-violation]
    }

  private:
    std::unique_ptr<std::string> text_ = std::make_unique<std::string>("abc");
  };
}

// END CASE

// CASE: contract.deduced_result
// PAIR: contract.deduced_result
// SOURCE: services/gui-cpp/qt/configuration_source.cpp :: ConfigurationSource::reload
// STATUS: implemented
// CONTRACT: A deduced return type repeats the label of what it returns, which is not a contract of the deducing function.
// SCENARIO: A lambda returns a labeled result built from what it captured; accept.
namespace contracts {
  text_a firstLetter(text_a source) {
    return source.substr(0, 1);
  }
}

std::size_t deducedResult(std::string_view source) {
  const auto read = [&source] { return contracts::firstLetter(source); };
  return read().size();
}

// END CASE

// CASE: contract.deduced_result_escape
// PAIR: contract.deduced_result
// SOURCE: services/gui-cpp/qt/configuration_source.cpp :: ConfigurationSource::reload
// STATUS: implemented
// CONTRACT: A deduced return type repeats the label of what it returns, which is not a contract of the deducing function.
// SCENARIO: The lambda's labeled result views a local whose scope ends before the result is read; the use is still checked.
std::size_t deducedResultEscape() {
  std::string_view kept;
  {
    const std::string source{"abc"};
    const auto read = [&source] { return contracts::firstLetter(source); };
    kept = read();
  } // expected-error [tbc-invalidated-borrow]
  return kept.size();
}

// END CASE
