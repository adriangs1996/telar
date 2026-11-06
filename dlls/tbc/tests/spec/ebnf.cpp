#include "support.hpp"

// CASE: ebnf.ast_temporary_source
// PAIR: ebnf.ast_source
// SOURCE: dlls/ebnf/parser.cppm :: node / parser::parse
// STATUS: implemented
// CONTRACT: Borrowed text in every reachable AST child is bounded by source storage.
// SCENARIO: A temporary string dies at the semicolon but the tree is read later.
void astTemporarySource() {
  auto tree = spec::parse(std::string{"rule = 'text';"}); // expected-error [tbc-dangling-borrow]
  spec::observe(tree);
}

// END CASE

// CASE: ebnf.ast_retained_source
// PAIR: ebnf.ast_source
// SOURCE: dlls/ebnf/parser.cppm :: node / parser::parse
// STATUS: implemented
// CONTRACT: Moving the AST does not move or copy the source, but may preserve valid loans.
// SCENARIO: The source outlives both AST handles and their last use; accept.
void astRetainedSource() {
  const std::string source{"rule = 'text';"};
  auto tree = spec::parse(source);
  auto transferred = std::move(tree);
  spec::observe(transferred);
}

// END CASE

// CASE: ebnf.ast_shallow_copy
// PAIR: ebnf.ast_copy
// SOURCE: dlls/ebnf/parser.cppm :: node
// STATUS: implemented
// CONTRACT: Copying vectors of nodes does not deep-copy the strings behind string_view fields.
// SCENARIO: Returning a copied aggregate still exports source-backed child views.
tbc::view<spec::node, tbc::lt::a> astShallowCopy() {
  const std::string source{"rule = 'text';"};
  const auto tree = spec::parse(source);
  auto copied = tree;
  return copied; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: ebnf.text_deep_copy
// PAIR: ebnf.ast_copy
// SOURCE: dlls/ebnf/parser.cppm :: node::text
// STATUS: implemented
// CONTRACT: An owning copy of text is independent of the source and tree.
// SCENARIO: Return an owned string instead of a borrowed view; deep-copy behavior remains a required body/model.
std::string textDeepCopy() {
  const std::string source{"rule = 'text';"};
  const auto tree = spec::parse(source);
  return spec::copyText(tree.text);
}

// END CASE
