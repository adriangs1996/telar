module;

#include <tbc/view.hpp>
#include <cstddef>
#include <cstdint>

export module telar.ebnf.parser;

import std;

export import telar.ebnf.lexer;

// Interface: parser.cppm
export {
namespace ebnf {

  using node_handle = uint32_t;

  inline constexpr node_handle none_handle{UINT32_MAX};
  inline constexpr std::size_t max_nesting_depth = 64;

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
    // `@name`: one word from a provider the caller resolves. `text` is the provider name.
    Dynamic,
    // `: "text"` after a Literal or Dynamic: its only child, holding the human description.
    Description,
    // `prefix ~ value`: one word that starts with the prefix literal and ends with the value.
    Glue,
  };

  struct flat_node {
    node_kind kind_;
    std::string_view text_{};
    node_handle first_child_handle_{none_handle};
    node_handle first_sibling_handle_{none_handle};
  };

  class syntax_tree {
    std::vector<flat_node> nodes_{max_tokens_in_ring_buffer};

    [[nodiscard]] inline auto contains(node_handle handle) const -> bool {
      return handle < nodes_.size();
    }

  public:
    inline auto clear() {
      nodes_.clear();
    }

    inline auto addNode(flat_node &node) -> node_handle {
      nodes_.push_back(node);
      return static_cast<node_handle>(nodes_.size() - 1);
    }

    inline auto setParent(node_handle node, node_handle parent) {
      if (!contains(node) || !contains(parent)) {
        return;
      }

      if (nodes_.at(parent).first_child_handle_ == none_handle) {
        nodes_[parent].first_child_handle_ = node;
      }
    }

    inline auto setSibling(node_handle node, node_handle sibling) {
      if (!contains(node) || !contains(sibling)) {
        return;
      }

      if (nodes_.at(node).first_sibling_handle_ == none_handle) {
        nodes_[node].first_sibling_handle_ = sibling;
      }
    }

    inline auto getRoot() -> node_handle {
      if (nodes_.empty()) {
        return none_handle;
      }

      return 0;
    }

    inline auto getText(node_handle handle) -> std::optional<std::string_view> {
      if (!contains(handle)) {
        return std::nullopt;
      }

      return nodes_.at(handle).text_;
    }

    inline auto getKind(node_handle handle) -> std::optional<node_kind> {
      if (!contains(handle)) {
        return std::nullopt;
      }

      return nodes_.at(handle).kind_;
    }

    inline auto getFirstSibling(node_handle handle) -> node_handle {
      if (!contains(handle)) {
        return none_handle;
      }

      return nodes_.at(handle).first_sibling_handle_;
    }

    inline auto getFirstChild(node_handle handle) -> node_handle {
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
    std::size_t depth_{0};
    syntax_tree tree_{};

    inline auto advance() -> token {
      const auto next_token = peek();

      if (next_token.kind != token_kind::End) {
        ++cursor_;
      }

      return next_token;
    }

    inline auto expect(token_kind kind, const char *message) -> void {
      if (!consume(kind)) {
        throw std::invalid_argument(message);
      }
    }

    inline auto wrap(node_kind kind, node_handle child) -> node_handle {
      auto wrapper = flat_node{.kind_ = kind};
      const auto handle = tree_.addNode(wrapper);
      tree_.setParent(child, handle);
      return handle;
    }

  public:
    inline parser(Tokenizer &tokenizer)
        : tokenizer_(tokenizer) {}

    inline auto parse(tbc::view<std::string_view, tbc::lt::a> source) -> tbc::view<syntax_tree, tbc::lt::a> {
      cursor_ = 0;
      depth_ = 0;
      token_count_ = 0;
      tree_.clear();
      const auto count = tokenizer_.tokenizeSourceIntoBuffer(source, tokens_, tokens_.size());

      if (count == 0 || count > tokens_.size() || tokens_[count - 1].kind != token_kind::End) {
        throw std::logic_error("Tokenizer must return a bounded token count including End");
      }

      token_count_ = count;

      return parseGrammar();
    }

    inline auto consume(token_kind tk_kind) -> bool {
      if (peek().kind != tk_kind) {
        return false;
      }

      advance();
      return true;
    }

    [[nodiscard]] inline auto peek() const -> token {
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
    inline auto parseGrammar() -> syntax_tree {
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
    inline auto parseRule() -> node_handle {
      auto rule = flat_node{.kind_ = node_kind::Rule};
      rule.text_ = parseIdentifier();
      const auto rule_handle = tree_.addNode(rule);

      expect(token_kind::Equal, "Expected = after the rule name");

      const auto body = parseAlternation();
      tree_.setParent(body, rule_handle);
      parseTerminator();

      return rule_handle;
    }

    // Alternative branches always have a Concatenation wrapper, even for one factor.
    inline auto ensureConcatenation(node_handle handle) -> node_handle {
      if (tree_.getKind(handle) == node_kind::Concatenation) {
        return handle;
      }

      return wrap(node_kind::Concatenation, handle);
    }

    // alternation = concatenation , ( "|" , concatenation ) * ;
    inline auto parseAlternation() -> node_handle {
      const auto first = parseConcatenation();

      if (!consume(token_kind::Pipe)) {
        return first;
      }

      const auto handle = wrap(node_kind::Alternative, ensureConcatenation(first));
      auto left = tree_.getFirstChild(handle);

      do {
        const auto sibling_handle = ensureConcatenation(parseConcatenation());
        tree_.setSibling(left, sibling_handle);
        left = sibling_handle;
      } while (consume(token_kind::Pipe));

      return handle;
    }

    // concatenation = factor , ( "," , factor ) * ;
    inline auto parseConcatenation() -> node_handle {
      const auto first = parseFactor();

      if (!consume(token_kind::Comma)) {
        return first;
      }

      const auto concat_handle = wrap(node_kind::Concatenation, first);
      auto left = first;

      do {
        const auto sibling_handle = parseFactor();
        tree_.setSibling(left, sibling_handle);
        left = sibling_handle;
      } while (consume(token_kind::Comma));

      return concat_handle;
    }

    // Binary factors keep both operands as ordered children.
    inline auto makeBinary(node_kind kind, node_handle left) -> node_handle {
      const auto right = parseTerm();
      const auto handle = wrap(kind, left);
      tree_.setSibling(left, right);
      return handle;
    }

    // factor = term , S , ( "?" | "*" | "+" | "-" , S , term | "~" , S , term ) ? ;
    inline auto parseFactor() -> node_handle {
      const auto term_handle = parseTerm();

      switch (peek().kind) {
      case token_kind::Question:
        advance();
        return wrap(node_kind::Optional, term_handle);
      case token_kind::Aster:
        advance();
        return wrap(node_kind::ZeroOrMore, term_handle);
      case token_kind::Plus:
        advance();
        return wrap(node_kind::OneOrMore, term_handle);
      case token_kind::Minus:
        advance();
        return makeBinary(node_kind::Exception, term_handle);
      case token_kind::Tilde:
        advance();
        return makeBinary(node_kind::Glue, term_handle);
      case token_kind::Colon:
        throw std::invalid_argument("Descriptions annotate only literals and dynamic terminals");
      default:
        return term_handle;
      }
    }

    // Recursion depth follows bracket nesting, so it is bounded to keep the stack small.
    inline auto parseGroup(token_kind closer, const char *message) -> node_handle {
      if (++depth_ > max_nesting_depth) {
        throw std::invalid_argument("Brackets nest too deeply");
      }

      advance();
      const auto inner = parseAlternation();
      expect(closer, message);
      --depth_;
      return inner;
    }

    // A terminal may carry one description: terminal , S , ":" , S , string ;
    inline auto parseTerminal(node_kind kind, std::string_view text) -> node_handle {
      auto terminal = flat_node{.kind_ = kind, .text_ = text};
      const auto handle = tree_.addNode(terminal);

      if (consume(token_kind::Colon)) {
        auto description = flat_node{.kind_ = node_kind::Description, .text_ = parseString()};
        tree_.setParent(tree_.addNode(description), handle);
      }

      return handle;
    }

    // term = "(" , S , rhs , S , ")"
    // | "[" , S , rhs , S , "]"
    // | "{" , S , rhs , S , "}"
    // | terminal
    // | "@" , identifier
    // | identifier ;
    inline auto parseTerm() -> node_handle {
      switch (peek().kind) {
      case token_kind::LParen:
        return parseGroup(token_kind::RParen, "Expected ) to close the group");
      case token_kind::LBracket:
        return wrap(node_kind::Optional, parseGroup(token_kind::RBracket, "Expected ] to close the option"));
      case token_kind::LBrace:
        return wrap(node_kind::ZeroOrMore, parseGroup(token_kind::RBrace, "Expected } to close the repetition"));
      case token_kind::String:
        return parseTerminal(node_kind::Literal, advance().text);
      case token_kind::Dynamic:
        return parseTerminal(node_kind::Dynamic, advance().text);
      default: {
        auto ref = flat_node{.kind_ = node_kind::Reference, .text_ = parseIdentifier()};
        return tree_.addNode(ref);
      }
      }
    }

    inline auto parseString() -> std::string_view {
      if (peek().kind != token_kind::String) {
        throw std::invalid_argument("Expected a string literal");
      }

      return advance().text;
    }

    inline auto parseTerminator() -> void {
      if (!consume(token_kind::Semicolon) && !consume(token_kind::Dot)) {
        throw std::invalid_argument("Expected ; or . to end the rule");
      }
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
}
