#include "tbc/view.hpp"

#include <cstdlib>
#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace inferred {
  struct record {
    std::string_view text;
    std::vector<record> children;
  };

  void observe(std::string_view text) {
    static_cast<void>(text.size());
  }

  std::string_view prefix(std::string_view source) {
    const auto alias = source;
    return alias.substr(0, 3);
  }

  record leaf(std::string_view source) {
    return {.text = prefix(source), .children = {}};
  }

  record branch(std::string_view source) {
    auto parent = record{};
    auto child = leaf(source);
    parent.children.push_back(std::move(child));
    return parent;
  }

  record copyRecord(const record &input) {
    const auto &alias = input;
    return alias;
  }

  const record &borrowRecord(const record &input) {
    return input;
  }

  std::string_view fromOwner(const std::string &input) {
    return input;
  }

  std::string_view preferFirst(std::string_view first, std::string_view second) {
    observe(second);
    return first;
  }

  std::string_view choose(std::string_view first, std::string_view second, bool pick_first) {
    return pick_first ? first : second;
  }

  std::string_view recursiveRight(std::string_view source, int depth);

  std::string_view recursiveLeft(std::string_view source, int depth) {
    if (depth == 0) {
      return source;
    }
    return recursiveRight(source, depth - 1);
  }

  std::string_view recursiveRight(std::string_view source, int depth) {
    return recursiveLeft(source, depth);
  }

  struct reader {
    std::string_view borrowed;
    std::string owned;

    std::string_view readBorrowed() const {
      return borrowed;
    }

    std::string_view readOwned() const {
      return owned;
    }
  };

  struct source_parser {
    std::string_view source;

    record parse(std::string_view input) {
      source = input;
      return parseRule();
    }

    record parseRule() const {
      return branch(source);
    }
  };

  record parse(std::string_view source) {
    auto parser = source_parser{};
    return parser.parse(source);
  }

  void write(record &destination, std::string_view source) {
    auto &alias = destination;
    alias = branch(source);
  }

  struct constructed_view {
    std::string_view text;

    explicit constructed_view(const std::string &source)
        : text(source) {}
  };

  struct constructed_reference {
    const std::string &source;

    explicit constructed_reference(const std::string &input)
        : source(input) {}

    std::string_view read() const {
      return source;
    }
  };

  struct self_reference {
    const self_reference *get() const {
      return this;
    }
  };

  void clearOwner(std::string &source) {
    source.clear();
  }

  std::string_view defaultText(std::string_view source = std::string{"abc"}) {
    return prefix(source);
  }

  using source_a = tbc::view<std::string_view, tbc::lt::a>;

  source_a explicitChoice(source_a first, source_a second) {
    return choose(first, second, true);
  }

  std::string_view opaque(std::string_view input);

  struct text_list {
    std::vector<std::string_view> items;

    void clear() {
      items.clear();
    }

    void add(std::string_view item) {
      items.push_back(item);
    }
  };

  struct text_slot {
    std::string_view text;

    void store(std::string_view next) {
      text = next;
    }

    std::string_view exchange(std::string_view next) {
      const auto previous = text;
      text = next;
      return previous;
    }
  };

  struct labeled_slot {
    source_a text;

    source_a exchange(source_a next) {
      const auto previous = text;
      text = next;
      return previous;
    }
  };

  struct opaque_holder {
    source_a held;

    void hold(source_a text);
    source_a probe(source_a candidate);
    source_a read() const;
  };
}

// CASE: inference.temporary_leaf
// PAIR: inference.leaf
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: A native aggregate result retains the inferred source dependency.
// SCENARIO: A leaf borrows a temporary string and is observed after its full expression.
void inferredTemporaryLeaf() {
  const auto value = inferred::leaf(std::string{"abc"}); // expected-error [tbc-dangling-borrow]
  inferred::observe(value.text);
}

// END CASE

// CASE: inference.retained_leaf
// PAIR: inference.leaf
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: A native aggregate may borrow an owner that remains alive through every use.
// SCENARIO: A leaf's source remains in scope.
void inferredRetainedLeaf() {
  const auto source = std::string{"abc"};
  const auto value = inferred::leaf(source);
  inferred::observe(value.text);
}

// END CASE

// CASE: inference.temporary_branch
// PAIR: inference.branch
// SOURCE: dlls/ebnf/parser.cppm :: node::children
// STATUS: implemented
// CONTRACT: Moving a child into a vector preserves the child's source dependency.
// SCENARIO: A parent is observed after the source temporary dies.
void inferredTemporaryBranch() {
  const auto value = inferred::branch(std::string{"abc"}); // expected-error [tbc-dangling-borrow]
  inferred::observe(value.children.front().text);
}

// END CASE

// CASE: inference.retained_branch
// PAIR: inference.branch
// SOURCE: dlls/ebnf/parser.cppm :: node::children
// STATUS: implemented
// CONTRACT: Copies and moves of descriptors do not borrow the local descriptor objects.
// SCENARIO: A copied and moved parent still borrows its live source.
void inferredRetainedBranch() {
  const auto source = std::string{"abc"};
  const auto parent = inferred::branch(source);
  auto copied = parent;
  const auto moved = std::move(copied);
  inferred::observe(moved.children.front().text);
}

// END CASE

// CASE: inference.local_owner_escape
// PAIR: inference.owner
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: A native string_view return cannot escape its local owner.
// SCENARIO: An inferred helper returns a substring of a local string.
std::string_view inferredLocalOwnerEscape() {
  const auto source = std::string{"abc"};
  return inferred::prefix(source); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.caller_owner
// PAIR: inference.owner
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: A reference input can supply the storage borrowed by a native value result.
// SCENARIO: A view borrows caller-owned string bytes through an inferred helper.
std::string_view inferredCallerOwner(const std::string &source) {
  return inferred::fromOwner(source);
}

// END CASE

// CASE: inference.temporary_reference
// PAIR: inference.reference
// SOURCE: dlls/ebnf/parser.cppm :: node
// STATUS: implemented
// CONTRACT: A returned reference borrows its descriptor object, not just its text.
// SCENARIO: A reference to a temporary record is read after the record dies.
void inferredTemporaryReference() {
  const auto &reference = inferred::borrowRecord(inferred::record{.text = "abc", .children = {}}); // expected-error [tbc-dangling-borrow]
  inferred::observe(reference.text);
}

// END CASE

// CASE: inference.descriptor_copy
// PAIR: inference.reference
// SOURCE: dlls/ebnf/parser.cppm :: node
// STATUS: implemented
// CONTRACT: Copying borrowed fields does not keep a borrow of the source descriptor.
// SCENARIO: A copied record can outlive a local record when the text source stays alive.
inferred::record inferredDescriptorCopy(std::string_view source) {
  const auto local = inferred::leaf(source);
  const auto &alias = local;
  return inferred::copyRecord(alias);
}

// END CASE

// CASE: inference.temporary_selected_argument
// PAIR: inference.selected_argument
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: A native result depends on the argument actually returned.
// SCENARIO: The selected input is temporary despite another input remaining alive.
void inferredTemporarySelectedArgument() {
  const auto source = std::string{"retained"};
  const auto value = inferred::preferFirst(std::string{"abc"}, source); // expected-error [tbc-dangling-borrow]
  inferred::observe(value);
}

// END CASE

// CASE: inference.unselected_temporary
// PAIR: inference.selected_argument
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: Reading a second argument during the call does not make it a result dependency.
// SCENARIO: An unused result origin is temporary, while the selected input remains alive.
void inferredUnselectedTemporary() {
  const auto source = std::string{"retained"};
  const auto value = inferred::preferFirst(source, std::string{"abc"});
  inferred::observe(value);
}

// END CASE

// CASE: inference.branch_temporary
// PAIR: inference.control_flow
// SOURCE: dlls/ebnf/parser.cppm :: parseRule
// STATUS: implemented
// CONTRACT: A result returned from either branch depends on both possible origins.
// SCENARIO: One branch may return a temporary string's view.
void inferredBranchTemporary(bool pick_first) {
  const auto source = std::string{"retained"};
  const auto value = inferred::choose(source, std::string{"abc"}, pick_first); // expected-error [tbc-dangling-borrow]
  inferred::observe(value);
}

// END CASE

// CASE: inference.branch_retained
// PAIR: inference.control_flow
// SOURCE: dlls/ebnf/parser.cppm :: parseRule
// STATUS: implemented
// CONTRACT: Multiple possible inferred input origins are valid while both owners live.
// SCENARIO: The function may return either retained source without explicit regions.
void inferredBranchRetained(bool pick_first) {
  const auto first = std::string{"first"};
  const auto second = std::string{"second"};
  inferred::observe(inferred::choose(first, second, pick_first));
}

// END CASE

// CASE: inference.recursive_temporary
// PAIR: inference.recursion
// SOURCE: dlls/ebnf/parser.cppm :: parseAlternation
// STATUS: implemented
// CONTRACT: Mutually recursive summaries propagate their base-case dependency.
// SCENARIO: A recursive helper's source temporary expires before the result's use.
void inferredRecursiveTemporary() {
  const auto value = inferred::recursiveRight(std::string{"abc"}, 3); // expected-error [tbc-dangling-borrow]
  inferred::observe(value);
}

// END CASE

// CASE: inference.recursive_retained
// PAIR: inference.recursion
// SOURCE: dlls/ebnf/parser.cppm :: parseAlternation
// STATUS: implemented
// CONTRACT: Recursive summary solving must preserve a valid caller dependency.
// SCENARIO: A recursive helper returns a view of its retained input.
std::string_view inferredRecursiveRetained(std::string_view source) {
  return inferred::recursiveRight(source, 3);
}

// END CASE

// CASE: inference.receiver_owned_escape
// PAIR: inference.receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: A getter of receiver-owned bytes borrows the receiver's storage.
// SCENARIO: Returning a local receiver's owned string view escapes the receiver.
std::string_view inferredReceiverOwnedEscape() {
  const auto reader = inferred::reader{.borrowed = "", .owned = "abc"};
  return reader.readOwned(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.receiver_borrowed_copy
// PAIR: inference.receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: Copying a borrowed field need not borrow the receiver object itself.
// SCENARIO: A getter's result outlives a local descriptor but not its caller-owned bytes.
std::string_view inferredReceiverBorrowedCopy(std::string_view source) {
  const auto reader = inferred::reader{.borrowed = source, .owned = ""};
  return reader.readBorrowed();
}

// END CASE

// CASE: inference.parser_temporary
// PAIR: inference.ebnf
// SOURCE: dlls/ebnf/parser.cppm :: parseRule
// STATUS: implemented
// CONTRACT: Parser helper chains propagate the source without result annotations.
// SCENARIO: An AST is used after the source temporary expires.
void inferredEbnfTemporary() {
  const auto tree = inferred::parse(std::string{"rule = 'abc';"}); // expected-error [tbc-dangling-borrow]
  inferred::observe(tree.children.front().text);
}

// END CASE

// CASE: inference.parser_retained
// PAIR: inference.ebnf
// SOURCE: dlls/ebnf/parser.cppm :: parseRule
// STATUS: implemented
// CONTRACT: The AST borrows source bytes rather than the local parser object.
// SCENARIO: An AST returned through an inferred helper retains a live source.
void inferredEbnfRetained() {
  const auto source = std::string{"rule = 'abc';"};
  const auto tree = inferred::parse(source);
  inferred::observe(tree.children.front().text);
}

// END CASE

// CASE: inference.explicit_contract_mismatch
// PAIR: inference.explicit_contract
// SOURCE: dlls/ebnf/parser.cppm :: parse
// STATUS: implemented
// CONTRACT: An explicit region is checked even when the returned helper has an inferred summary.
// SCENARIO: Inferred propagation must not bypass a mismatched public contract.
tbc::view<std::string_view, tbc::lt::a> inferredExplicitMismatch(tbc::view<std::string_view, tbc::lt::a> first, tbc::view<std::string_view, tbc::lt::b> second) {
  inferred::observe(first);
  return inferred::prefix(second); // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: inference.explicit_contract_match
// PAIR: inference.explicit_contract
// SOURCE: dlls/ebnf/parser.cppm :: parse
// STATUS: implemented
// CONTRACT: A helper's inferred result can satisfy an explicit public region.
// SCENARIO: The public result returns the input named by its region.
tbc::view<std::string_view, tbc::lt::a> inferredExplicitMatch(tbc::view<std::string_view, tbc::lt::a> source) {
  return inferred::prefix(source);
}

// END CASE

// CASE: inference.opaque_boundary
// PAIR: inference.boundary
// SOURCE: dlls/ebnf/parser.cppm :: i_tokenizer
// STATUS: implemented
// CONTRACT: An unavailable implementation without a contract must not imply a static result.
// SCENARIO: A native borrowed result crosses an opaque boundary.
void inferredOpaqueBoundary(std::string_view source) {
  const auto value = inferred::opaque(source); // expected-error [tbc-missing-contract]
  inferred::observe(value);
}

// END CASE

// CASE: inference.static_result
// PAIR: inference.boundary
// SOURCE: dlls/ebnf/parser.cppm :: peek
// STATUS: implemented
// CONTRACT: A visible body returning literal-backed text has no expiring input dependency.
// SCENARIO: An inferred constant result requires no artificial lifetime parameter.
std::string_view inferredStaticResult() {
  return "abc";
}

// END CASE

// CASE: inference.receiver_write_temporary
// PAIR: inference.receiver_write
// SOURCE: dlls/ebnf/parser.cppm :: parse
// STATUS: implemented
// CONTRACT: A call's inferred writes update the receiver's borrowed fields.
// SCENARIO: A later getter reads state retained from a temporary source.
void inferredReceiverWriteTemporary() {
  auto parser = inferred::source_parser{};
  parser.parse(std::string{"abc"}); // expected-error [tbc-dangling-borrow]
  const auto tree = parser.parseRule();
  inferred::observe(tree.children.front().text);
}

// END CASE

// CASE: inference.receiver_write_retained
// PAIR: inference.receiver_write
// SOURCE: dlls/ebnf/parser.cppm :: parse
// STATUS: implemented
// CONTRACT: Inferred receiver writes preserve a live caller dependency.
// SCENARIO: A later getter reads a source retained by an earlier call.
void inferredReceiverWriteRetained() {
  const auto source = std::string{"abc"};
  auto parser = inferred::source_parser{};
  parser.parse(source);
  const auto tree = parser.parseRule();
  inferred::observe(tree.children.front().text);
}

// END CASE

// CASE: inference.initializer_list_escape
// PAIR: inference.initializer_list
// SOURCE: dlls/ebnf/tests/lexer_test.cpp :: Lexer.RejectsInvalidCharactersOutsideLiterals
// STATUS: implemented
// CONTRACT: An initializer list's backing array is borrowed, not owned by its descriptor.
// SCENARIO: A local initializer list is returned by value.
std::initializer_list<int> inferredInitializerListEscape() {
  const auto values = {1, 2, 3};
  return values; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.initializer_list_retained
// PAIR: inference.initializer_list
// SOURCE: dlls/ebnf/tests/lexer_test.cpp :: Lexer.RejectsInvalidCharactersOutsideLiterals
// STATUS: implemented
// CONTRACT: A range-for initializer list remains valid throughout the loop.
// SCENARIO: Literal-backed strings are observed through a live initializer-list range.
void inferredInitializerListRetained() {
  for (const auto *text : {"a", "b"}) {
    inferred::observe(text);
  }
}

// END CASE

// CASE: inference.environment_requery
// PAIR: inference.environment
// SOURCE: dlls/ebnf/tests/parser_assertions.hpp :: colorsEnabled
// STATUS: implemented
// CONTRACT: Requerying the environment may overwrite a previously returned string.
// SCENARIO: An inferred getenv borrow is used after another environment query.
void inferredEnvironmentRequery() {
  const auto *text = std::getenv("TERM");
  if (text == nullptr) {
    return;
  }
  static_cast<void>(std::getenv("NO_COLOR")); // expected-error [tbc-invalidated-borrow]
  inferred::observe(text);
}

// END CASE

// CASE: inference.environment_immediate_read
// PAIR: inference.environment
// SOURCE: dlls/ebnf/tests/parser_assertions.hpp :: colorsEnabled
// STATUS: implemented
// CONTRACT: The standard environment query yields borrowed process-managed bytes.
// SCENARIO: A non-null environment value is read before another environment operation.
void inferredEnvironmentImmediateRead() {
  const auto *text = std::getenv("TERM");
  if (text != nullptr) {
    inferred::observe(text);
  }
}

// END CASE

// CASE: inference.output_argument_temporary
// PAIR: inference.output_argument
// SOURCE: dlls/ebnf/lexer.cppm :: tokenizeSourceIntoBuffer
// STATUS: implemented
// CONTRACT: Inferred output-argument writes retain their actual source dependency.
// SCENARIO: An aggregate is filled through a reference alias from a temporary source.
void inferredOutputArgumentTemporary() {
  auto value = inferred::record{};
  inferred::write(value, std::string{"abc"}); // expected-error [tbc-dangling-borrow]
  inferred::observe(value.children.front().text);
}

// END CASE

// CASE: inference.output_argument_retained
// PAIR: inference.output_argument
// SOURCE: dlls/ebnf/lexer.cppm :: tokenizeSourceIntoBuffer
// STATUS: implemented
// CONTRACT: An inferred write through a local reference alias updates the actual argument.
// SCENARIO: A retained source supplies a borrowed output aggregate without annotations.
void inferredOutputArgumentRetained() {
  const auto source = std::string{"abc"};
  auto value = inferred::record{};
  inferred::write(value, source);
  inferred::observe(value.children.front().text);
}

// END CASE

// CASE: inference.explicit_choice_temporary
// PAIR: inference.explicit_choice
// SOURCE: dlls/ebnf/parser.cppm :: parse
// STATUS: implemented
// CONTRACT: An explicit public region remains authoritative rather than narrowing to the body.
// SCENARIO: A shared-region contract permits returning a temporary second input.
void inferredExplicitChoiceTemporary() {
  const auto source = std::string{"retained"};
  const auto value = inferred::explicitChoice(source, std::string{"abc"}); // expected-error [tbc-dangling-borrow]
  inferred::observe(value);
}

// END CASE

// CASE: inference.explicit_choice_retained
// PAIR: inference.explicit_choice
// SOURCE: dlls/ebnf/parser.cppm :: parse
// STATUS: implemented
// CONTRACT: Explicit shared-region inputs may both supply the result while they remain alive.
// SCENARIO: Both inputs satisfy the explicit result contract.
void inferredExplicitChoiceRetained() {
  const auto first = std::string{"first"};
  const auto second = std::string{"second"};
  inferred::observe(inferred::explicitChoice(first, second));
}

// END CASE

// CASE: inference.independent_calls_bad
// PAIR: inference.independent_calls
// SOURCE: dlls/ebnf/parser.cppm :: parseRule
// STATUS: implemented
// CONTRACT: Reusing a cached summary must not overwrite a previous call's result dependencies.
// SCENARIO: A later valid call must not erase an earlier temporary borrow.
void inferredIndependentCallsBad() {
  const auto first = inferred::leaf(std::string{"abc"}); // expected-error [tbc-dangling-borrow]
  const auto second = inferred::leaf("static");
  inferred::observe(second.text);
  inferred::observe(first.text);
}

// END CASE

// CASE: inference.independent_calls_good
// PAIR: inference.independent_calls
// SOURCE: dlls/ebnf/parser.cppm :: parseRule
// STATUS: implemented
// CONTRACT: Each call instantiates an inferred summary using its own actual arguments.
// SCENARIO: An unused expired borrow must not poison a later independent result.
void inferredIndependentCallsGood() {
  [[maybe_unused]] const auto first = inferred::leaf(std::string{"abc"});
  const auto second = inferred::leaf("static");
  inferred::observe(second.text);
}

// END CASE

// CASE: inference.reachable_local_return
// PAIR: inference.reachability
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: A reachable local-reference return is rejected without an annotation.
// SCENARIO: One branch returns a local reference instead of the input.
const int &inferredReachableLocalReturn(const int &input, bool bad) {
  if (bad) {
    const int local = 1;
    return local; // expected-error [tbc-dangling-borrow]
  }
  return input;
}

// END CASE

// CASE: inference.unreachable_local_return
// PAIR: inference.reachability
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: Inference uses reachable CFG paths rather than every syntactic return.
// SCENARIO: A statically unreachable local return must not contaminate the input dependency.
const int &inferredUnreachableLocalReturn(const int &input) {
  if (false) {
    const int local = 1;
    return local;
  }
  return input;
}

// END CASE

// CASE: inference.default_argument_escape
// PAIR: inference.default_argument
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: A default argument's temporary belongs to the caller's full expression.
// SCENARIO: A default temporary source expires before the inferred result is observed.
void inferredDefaultArgumentEscape() {
  const auto value = inferred::defaultText(); // expected-error [tbc-dangling-borrow]
  inferred::observe(value);
}

// END CASE

// CASE: inference.default_argument_immediate
// PAIR: inference.default_argument
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: A default source temporary remains alive throughout the full expression.
// SCENARIO: The borrowed result is consumed immediately without escaping the expression.
void inferredDefaultArgumentImmediate() {
  inferred::observe(inferred::defaultText());
}

// END CASE

// CASE: inference.constructor_escape
// PAIR: inference.constructor
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: Constructor member initializers propagate actual borrowed data dependencies.
// SCENARIO: An object returned by value retains a view of a local string.
inferred::constructed_view inferredConstructorEscape() {
  const auto source = std::string{"abc"};
  return inferred::constructed_view{source}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.constructor_retained
// PAIR: inference.constructor
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: An inferred constructor may retain bytes owned by its caller.
// SCENARIO: A constructed view borrows an external source rather than a local descriptor.
inferred::constructed_view inferredConstructorRetained(const std::string &source) {
  return inferred::constructed_view{source};
}

// END CASE

// CASE: inference.reference_member_escape
// PAIR: inference.reference_member
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: A reference member and its getter retain the referent's dependency.
// SCENARIO: An inferred getter returns bytes of a local string through a reference member.
std::string_view inferredReferenceMemberEscape() {
  const auto source = std::string{"abc"};
  const auto holder = inferred::constructed_reference{source};
  return holder.read(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.reference_member_retained
// PAIR: inference.reference_member
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: A local descriptor with a reference member does not own the referenced string.
// SCENARIO: A getter can return caller-owned bytes independently of the local descriptor.
std::string_view inferredReferenceMemberRetained(const std::string &source) {
  const auto holder = inferred::constructed_reference{source};
  return holder.read();
}

// END CASE

// CASE: inference.self_pointer_escape
// PAIR: inference.self_pointer
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: Returning this borrows the receiver object rather than its borrowed fields.
// SCENARIO: An inferred self pointer escapes a local receiver that has no borrowed fields.
const inferred::self_reference *inferredSelfPointerEscape() {
  const auto local = inferred::self_reference{};
  return local.get(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.self_pointer_retained
// PAIR: inference.self_pointer
// SOURCE: dlls/ebnf/parser.cppm :: parser
// STATUS: implemented
// CONTRACT: A self pointer may borrow a caller-owned receiver.
// SCENARIO: A method's inferred object dependency propagates through a reference input.
const inferred::self_reference *inferredSelfPointerRetained(const inferred::self_reference &input) {
  return input.get();
}

// END CASE

// CASE: inference.declaration_contract_mismatch
// PAIR: inference.declaration_contract
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: An explicit declaration remains binding when its definition omits the aliases.
// SCENARIO: A plain definition returns the origin excluded by its prior declaration.
tbc::view<std::string_view, tbc::lt::a> inferredDeclarationMismatch(tbc::view<std::string_view, tbc::lt::a> first, tbc::view<std::string_view, tbc::lt::b> second);

std::string_view inferredDeclarationMismatch(std::string_view renamed_first, std::string_view renamed_second) {
  inferred::observe(renamed_first);
  return inferred::prefix(renamed_second); // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: inference.declaration_contract_match
// PAIR: inference.declaration_contract
// SOURCE: dlls/ebnf/parser.cppm :: parseIdentifier
// STATUS: implemented
// CONTRACT: The contract may be written once on the declaration rather than repeated in the definition.
// SCENARIO: A plain definition satisfies its annotated declaration after renaming parameters.
tbc::view<std::string_view, tbc::lt::a> inferredDeclarationMatch(tbc::view<std::string_view, tbc::lt::a> source);

std::string_view inferredDeclarationMatch(std::string_view renamed) {
  return inferred::prefix(renamed);
}

// END CASE

// CASE: inference.helper_invalidates_borrow
// PAIR: inference.helper_invalidation
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: A modeled invalidation propagates through an inferred helper summary.
// SCENARIO: A source is cleared by a helper before its borrowed text is read.
void inferredHelperInvalidatesBorrow() {
  auto source = std::string{"abc"};
  const auto value = inferred::leaf(source);
  inferred::clearOwner(source); // expected-error [tbc-invalidated-borrow]
  inferred::observe(value.text);
}

// END CASE

// CASE: inference.helper_preserves_owned_copy
// PAIR: inference.helper_invalidation
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: An owning text copy does not depend on the source invalidated by a helper.
// SCENARIO: A deep copy is observed after the helper clears its original source.
void inferredHelperPreservesOwnedCopy() {
  auto source = std::string{"abc"};
  const auto value = inferred::leaf(source);
  const auto owned = std::string{value.text};
  inferred::clearOwner(source);
  inferred::observe(owned);
}

// END CASE

// CASE: inference.moved_aggregate_escape
// PAIR: inference.moved_aggregate
// SOURCE: dlls/ebnf/parser.cppm :: node::children
// STATUS: implemented
// CONTRACT: Moving an aggregate preserves borrowed contents without projecting them a second time.
// SCENARIO: A move must not erase the dependency on a local owning string.
inferred::record inferredMovedAggregateEscape() {
  const auto source = std::string{"abc"};
  auto value = inferred::branch(source);
  return std::move(value); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: inference.moved_aggregate_retained
// PAIR: inference.moved_aggregate
// SOURCE: dlls/ebnf/parser.cppm :: node::children
// STATUS: implemented
// CONTRACT: Moving an aggregate preserves the source dependency rather than the local descriptor's address.
// SCENARIO: A moved result may borrow caller-owned text after the local descriptor dies.
inferred::record inferredMovedAggregateRetained(const std::string &source) {
  auto value = inferred::branch(source);
  return std::move(value);
}

// END CASE

// CASE: inference.cleared_receiver_refill
// PAIR: inference.cleared_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::parse
// STATUS: implemented
// CONTRACT: Clearing a container discards its previous loans before a declared result region is checked.
// SCENARIO: A builder clears its retained list through a helper, refills it from the source, and returns it; accept.
struct cleared_builder {
  inferred::text_list list;

  tbc::view<inferred::text_list, tbc::lt::a> rebuild(tbc::view<std::string_view, tbc::lt::a> source) {
    list.clear();
    list.add(source);
    return std::move(list);
  }
};

// END CASE

// CASE: inference.uncleared_receiver_refill
// PAIR: inference.cleared_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::parse
// STATUS: implemented
// CONTRACT: Items retained by an earlier call can reach a declared result unless the container is cleared.
// SCENARIO: The builder appends to a list that may still hold items from a previous source.
struct uncleared_builder {
  inferred::text_list list;

  tbc::view<inferred::text_list, tbc::lt::a> extend(tbc::view<std::string_view, tbc::lt::a> source) {
    list.add(source);
    return std::move(list); // expected-error [tbc-contract-violation]
  }
};

// END CASE

// CASE: inference.exchanged_receiver_escape
// PAIR: inference.exchanged_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::parse
// STATUS: implemented
// CONTRACT: A call result is substituted with the receiver state before that call overwrites the receiver.
// SCENARIO: The exchanged previous value views a source that dies before the read.
void inferredExchangedReceiverEscape() {
  auto slot = inferred::text_slot{};
  const auto second = std::string{"two"};
  std::string_view previous;
  {
    const auto first = std::string{"one"};
    slot.store(first);
    previous = slot.exchange(second);
  } // expected-error [tbc-invalidated-borrow]
  inferred::observe(previous);
}

// END CASE

// CASE: inference.exchanged_receiver_retained
// PAIR: inference.exchanged_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::parse
// STATUS: implemented
// CONTRACT: An exchanged previous value may be read while its own source is alive.
// SCENARIO: Both sources outlive every read; accept.
void inferredExchangedReceiverRetained() {
  auto slot = inferred::text_slot{};
  const auto first = std::string{"one"};
  const auto second = std::string{"two"};
  slot.store(first);
  const auto previous = slot.exchange(second);
  inferred::observe(previous);
}

// END CASE

// CASE: inference.labeled_receiver_escape
// PAIR: inference.labeled_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::tokens_
// STATUS: implemented
// CONTRACT: A receiver field in the declared result region can supply the result even when a parameter shares the region.
// SCENARIO: The declared result is the previous field value, which views a source that dies before the read.
void inferredLabeledReceiverEscape() {
  auto slot = inferred::labeled_slot{};
  const auto second = std::string{"two"};
  std::string_view previous;
  {
    const auto first = std::string{"one"};
    static_cast<void>(slot.exchange(first));
    previous = slot.exchange(second);
  } // expected-error [tbc-invalidated-borrow]
  inferred::observe(previous);
}

// END CASE

// CASE: inference.labeled_receiver_retained
// PAIR: inference.labeled_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::tokens_
// STATUS: implemented
// CONTRACT: A result supplied by a receiver field may be read while that field's source is alive.
// SCENARIO: Both sources outlive every read; accept.
void inferredLabeledReceiverRetained() {
  auto slot = inferred::labeled_slot{};
  const auto first = std::string{"one"};
  const auto second = std::string{"two"};
  static_cast<void>(slot.exchange(first));
  const auto previous = slot.exchange(second);
  inferred::observe(previous);
}

// END CASE

// CASE: inference.opaque_receiver_retains_argument
// PAIR: inference.opaque_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::tokens_
// STATUS: implemented
// CONTRACT: A mutating declaration with a parameter in a receiver field's region may retain that argument, whatever it returns.
// SCENARIO: A void setter keeps a view of a source that dies before a later read.
void inferredOpaqueReceiverRetainsArgument() {
  auto holder = inferred::opaque_holder{};
  {
    const auto first = std::string{"one"};
    holder.hold(first);
  } // expected-error [tbc-invalidated-borrow]
  inferred::observe(holder.read());
}

// END CASE

// CASE: inference.opaque_receiver_accumulates
// PAIR: inference.opaque_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::tokens_
// STATUS: implemented
// CONTRACT: A later mutating call does not erase an argument retained by an earlier call.
// SCENARIO: A probe with a live source follows a setter whose source dies before the read.
void inferredOpaqueReceiverAccumulates() {
  auto holder = inferred::opaque_holder{};
  const auto second = std::string{"two"};
  {
    const auto first = std::string{"one"};
    holder.hold(first);
    static_cast<void>(holder.probe(second));
  } // expected-error [tbc-invalidated-borrow]
  inferred::observe(holder.read());
}

// END CASE

// CASE: inference.opaque_receiver_retained
// PAIR: inference.opaque_receiver
// SOURCE: dlls/ebnf/parser.cppm :: parser::tokens_
// STATUS: implemented
// CONTRACT: Arguments retained by the receiver may be read while every retained source is alive.
// SCENARIO: Both sources outlive the receiver's last read; accept.
void inferredOpaqueReceiverRetained() {
  auto holder = inferred::opaque_holder{};
  const auto first = std::string{"one"};
  const auto second = std::string{"two"};
  holder.hold(first);
  static_cast<void>(holder.probe(second));
  inferred::observe(holder.read());
}

// END CASE
