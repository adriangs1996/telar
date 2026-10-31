#pragma once

#include "lexer.hpp"

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

namespace ebnf {

  using binding_power = int;
  using NodeId = int;
  using node_handle = uint32_t;

  static constexpr node_handle none_handle{UINT32_MAX};

  enum class node_kind : std::uint8_t {
    Root,
    Reference,
    Literal,
    Alternative,
    Concatenation,
    Optional,
    ZeroOrMore,
    OneOrMore,
    Exception,
    Rule,
  };

  struct flat_node {
    node_kind kind_;
    std::string_view text_{};
    node_handle first_child_handle_{none_handle};
    node_handle first_sibling_handle_{none_handle};
  };

  class syntax_tree {
    std::vector<flat_node> nodes_{max_tokens_in_ring_buffer};

    [[nodiscard]] auto contains(node_handle handle) const -> bool {
      return handle < nodes_.size();
    }

  public:
    auto clear() {
      nodes_.clear();
    }

    auto addNode(flat_node &node) -> node_handle {
      nodes_.push_back(node);
      return static_cast<node_handle>(nodes_.size() - 1);
    }

    auto setParent(node_handle node, node_handle parent) {
      if (!contains(node) || !contains(parent)) {
        return;
      }

      if (nodes_.at(parent).first_child_handle_ == none_handle) {
        nodes_[parent].first_child_handle_ = node;
      }
    }

    auto setSibling(node_handle node, node_handle sibling) {
      if (!contains(node) || !contains(sibling)) {
        return;
      }

      if (nodes_.at(node).first_sibling_handle_ == none_handle) {
        nodes_[node].first_sibling_handle_ = sibling;
      }
    }

    auto getRoot() -> node_handle {
      if (nodes_.empty()) {
        return none_handle;
      }

      return 0;
    }

    auto getText(node_handle handle) -> std::optional<std::string_view> {
      if (!contains(handle)) {
        return std::nullopt;
      }

      return nodes_.at(handle).text_;
    }

    auto getKind(node_handle handle) -> std::optional<node_kind> {
      if (!contains(handle)) {
        return std::nullopt;
      }

      return nodes_.at(handle).kind_;
    }

    auto getFirstSibling(node_handle handle) -> node_handle {
      if (!contains(handle)) {
        return none_handle;
      }

      return nodes_.at(handle).first_sibling_handle_;
    }

    auto getFirstChild(node_handle handle) -> node_handle {
      if (!contains(handle)) {
        return none_handle;
      }

      return nodes_.at(handle).first_child_handle_;
    }
  };

  template <i_tokenizer Tokenizer>
  class parser {
    Tokenizer tokenizer_;

    parsing_ring_buffer tokens_;
    std::size_t token_count_{0};
    std::size_t cursor_{0};
    syntax_tree tree_{};

    struct BindingPower {
      binding_power left;
      binding_power right;
    };

    [[nodiscard]] auto infixBindingPower(token_kind) const -> std::optional<BindingPower> {
      throw std::logic_error("infixBindingPower is not implemented");
    }

    auto advance() -> token {
      const auto next_token = peek();

      if (next_token.kind != token_kind::End) {
        ++cursor_;
      }

      return next_token;
    }

    auto makeBinary(token_kind, NodeId, NodeId) -> NodeId {
      throw std::logic_error("makeBinary is not implemented");
    }

  public:
    parser(Tokenizer &tokenizer)
        : tokenizer_(tokenizer) {}

    auto parse(tbc::view<std::string_view, tbc::lt::a> source) -> tbc::view<syntax_tree, tbc::lt::a> {
      cursor_ = 0;
      token_count_ = 0;
      tree_.clear();
      const auto count = tokenizer_.tokenizeSourceIntoBuffer(source, tokens_, tokens_.size());

      if (count == 0 || count > tokens_.size() || tokens_[count - 1].kind != token_kind::End) {
        throw std::logic_error("Tokenizer must return a bounded token count including End");
      }

      token_count_ = count;

      return parseGrammar();
    }

    auto consume(token_kind tk_kind) -> bool {
      if (peek().kind != tk_kind) {
        return false;
      }

      advance();
      return true;
    }

    [[nodiscard]] auto peek() const -> token {
      if (cursor_ >= token_count_) {
        return token{
            .kind = token_kind::End,
            .text = {},
        };
      }

      return tokens_[cursor_];
    }

  private:
    // grammar = ( S , rule , S ) * ;
    auto parseGrammar() -> syntax_tree {
      auto root = flat_node{.kind_ = node_kind::Root};
      const auto root_handle = tree_.addNode(root);
      auto previous_rule_handle = none_handle;

      while (peek().kind != token_kind::End) {
        const auto rule_handle = parseRule();

        if (previous_rule_handle == none_handle) {
          tree_.setParent(rule_handle, root_handle);
        } else {
          tree_.setSibling(previous_rule_handle, rule_handle);
        }

        previous_rule_handle = rule_handle;
      }

      return std::move(tree_);
    }

    // rule = lhs , S , "=" , S , alternation , S , terminator ;
    auto parseRule() -> node_handle {
      auto rule = flat_node{.kind_ = node_kind::Rule};
      auto identifier = parseIdentifier();

      rule.text_ = identifier;
      const auto rule_handle = tree_.addNode(rule);

      if (!consume(token_kind::Equal)) {
        throw std::logic_error("Expected an =");
      }

      auto alternation_handler = parseAlternation();
      tree_.setParent(alternation_handler, rule_handle);
      parseTerminator();

      return rule_handle;
    }

    // Alternative branches always have a Concatenation wrapper, even for one factor.
    auto ensureConcatenation(node_handle handle) -> node_handle {
      if (tree_.getKind(handle) == node_kind::Concatenation) {
        return handle;
      }

      auto concatenation = flat_node{.kind_ = node_kind::Concatenation};
      const auto concat_handle = tree_.addNode(concatenation);
      tree_.setParent(handle, concat_handle);
      return concat_handle;
    }

    // alternation = concatenation , ( "|" , concatenation ) * ;
    auto parseAlternation() -> node_handle {
      const auto first = parseConcatenation();

      if (!consume(token_kind::Pipe)) {
        return first;
      }

      auto alternation = flat_node{.kind_ = node_kind::Alternative};
      const auto handle = tree_.addNode(alternation);
      auto left = ensureConcatenation(first);
      tree_.setParent(left, handle);

      do {
        const auto sibling_handle = ensureConcatenation(parseConcatenation());
        tree_.setSibling(left, sibling_handle);
        left = sibling_handle;
      } while (consume(token_kind::Pipe));

      return handle;
    }

    // concatenation = factor , ( "," , factor ) * ;
    auto parseConcatenation() -> node_handle {
      const auto first = parseFactor();

      if (!consume(token_kind::Comma)) {
        return first;
      }

      auto concatenation = flat_node{.kind_ = node_kind::Concatenation};
      const auto concat_handle = tree_.addNode(concatenation);
      tree_.setParent(first, concat_handle);

      auto left = first;
      do {
        const auto sibling_handle = parseFactor();
        tree_.setSibling(left, sibling_handle);
        left = sibling_handle;
      } while (consume(token_kind::Comma));

      return concat_handle;
    }

    // factor = term, S, ("?" | "*" | "+" | ("-", S, term ))?
    auto parseFactor() -> node_handle {
      const auto term_handle = parseTerm();

      switch (peek().kind) {
      case token_kind::Question: {
        consume(token_kind::Question);
        auto wrapper = flat_node{.kind_ = node_kind::Optional};
        const auto handle = tree_.addNode(wrapper);
        tree_.setParent(term_handle, handle);
        return handle;
      }

      case token_kind::Aster: {
        consume(token_kind::Aster);
        auto wrapper = flat_node{.kind_ = node_kind::ZeroOrMore};
        const auto handle = tree_.addNode(wrapper);
        tree_.setParent(term_handle, handle);
        return handle;
      }

      case token_kind::Plus: {
        consume(token_kind::Plus);
        auto wrapper = flat_node{.kind_ = node_kind::OneOrMore};
        const auto handle = tree_.addNode(wrapper);
        tree_.setParent(term_handle, handle);
        return handle;
      }

      case token_kind::Minus: {
        consume(token_kind::Minus);
        const auto excluded = parseTerm();
        auto exc = flat_node{.kind_ = node_kind::Exception};
        const auto handle = tree_.addNode(exc);
        tree_.setParent(term_handle, handle);
        tree_.setSibling(term_handle, excluded);
        return handle;
      }

      default:
        return term_handle;
      }
    }

    // term = "(" , S , rhs , S , ")"
    // | "[" , S , rhs , S , "]"
    // | "{" , S , rhs , S , "}"
    // | terminal
    // | identifier ;
    auto parseTerm() -> node_handle {
      const auto first_indicator = peek().kind;

      switch (first_indicator) {
      case token_kind::LParen:
      case token_kind::LBrace:
      case token_kind::LBracket: {
        consume(first_indicator);
        const auto inner = parseAlternation();

        if (first_indicator == token_kind::LParen && !consume(token_kind::RParen)) {
          throw std::logic_error("Was expecting a RParen");
        }

        if (first_indicator == token_kind::LBrace && !consume(token_kind::RBrace)) {
          throw std::logic_error("Was expecting a RBrace");
        }

        if (first_indicator == token_kind::LBracket && !consume(token_kind::RBracket)) {
          throw std::logic_error("Was expecting a RBracket");
        }

        if (first_indicator == token_kind::LBracket) {
          auto wrapper = flat_node{.kind_ = node_kind::Optional};
          const auto handle = tree_.addNode(wrapper);
          tree_.setParent(inner, handle);
          return handle;
        }

        if (first_indicator == token_kind::LBrace) {
          auto wrapper = flat_node{.kind_ = node_kind::ZeroOrMore};
          const auto handle = tree_.addNode(wrapper);
          tree_.setParent(inner, handle);
          return handle;
        }

        return inner;
      }
      case token_kind::String: {
        const auto text = parseString();
        auto literal = flat_node{.kind_ = node_kind::Literal, .text_ = text};
        return tree_.addNode(literal);
      }
      default: {
        const auto text = parseIdentifier();
        auto ref = flat_node{.kind_ = node_kind::Reference, .text_ = text};
        return tree_.addNode(ref);
      }
      }
    }

    auto parseString() -> std::string_view {
      if (peek().kind != token_kind::String) {
        throw std::invalid_argument("Expected a string literal");
      }

      return advance().text;
    }

    auto parseTerminator() {
      const auto next_token = peek().kind;
      if (!(next_token == token_kind::Semicolon || next_token == token_kind::Dot)) {
        throw std::logic_error("Expected Semicolon or Dot");
      }
      consume(next_token);
    }

    auto parseIdentifier() -> std::string_view;
  };

  template <i_tokenizer Tokenizer>
  inline auto parser<Tokenizer>::parseIdentifier() -> std::string_view {
    if (peek().kind != token_kind::Identifier) {
      throw std::invalid_argument("Expected an identifier");
    }

    return advance().text;
  }

  template <i_tokenizer Tokenizer>
  parser(Tokenizer) -> parser<Tokenizer>;
}
