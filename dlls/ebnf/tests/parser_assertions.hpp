#pragma once

#include "parser.hpp"

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <ostream>
#include <string>

namespace ebnf {
  constexpr auto tokenKindName(token_kind kind) -> std::string_view {
    switch (kind) {
    case token_kind::Identifier:
      return "Identifier";
    case token_kind::Number:
      return "Number";
    case token_kind::String:
      return "String";
    case token_kind::Equal:
      return "Equal";
    case token_kind::Semicolon:
      return "Semicolon";
    case token_kind::Pipe:
      return "Pipe";
    case token_kind::Comma:
      return "Comma";
    case token_kind::LParen:
      return "LParen";
    case token_kind::RParen:
      return "RParen";
    case token_kind::LBracket:
      return "LBracket";
    case token_kind::RBracket:
      return "RBracket";
    case token_kind::LBrace:
      return "LBrace";
    case token_kind::RBrace:
      return "RBrace";
    case token_kind::Question:
      return "Question";
    case token_kind::Plus:
      return "Plus";
    case token_kind::Aster:
      return "Aster";
    case token_kind::Minus:
      return "Minus";
    case token_kind::Dot:
      return "Dot";
    case token_kind::End:
      return "End";
    }

    return "Unknown";
  }

  constexpr auto nodeKindName(node_kind kind) -> std::string_view {
    switch (kind) {
    case node_kind::Root:
      return "Root";
    case node_kind::Reference:
      return "Reference";
    case node_kind::Literal:
      return "Literal";
    case node_kind::Alternative:
      return "Alternative";
    case node_kind::Concatenation:
      return "Concatenation";
    case node_kind::Optional:
      return "Optional";
    case node_kind::ZeroOrMore:
      return "ZeroOrMore";
    case node_kind::OneOrMore:
      return "OneOrMore";
    case node_kind::Exception:
      return "Exception";
    case node_kind::Rule:
      return "Rule";
    }

    return "Unknown";
  }

  inline void PrintTo(token_kind kind, std::ostream *out) {
    *out << "TokenKind::" << tokenKindName(kind);
  }

  inline void PrintTo(node_kind kind, std::ostream *out) {
    *out << "NodeKind::" << nodeKindName(kind);
  }

  inline void PrintTo(const token &token, std::ostream *out) {
    PrintTo(token.kind, out);
    *out << " with text " << testing::PrintToString(token.text);
  }
}

namespace parser_testing {
  enum class DiagnosticColor : uint8_t {
    Expected,
    Actual,
  };

  inline auto colorsEnabled() -> bool {
    if (std::getenv("NO_COLOR") != nullptr) {
      return false;
    }

    const auto mode = GTEST_FLAG_GET(color);

    if (mode == "yes" || mode == "true" || mode == "t" || mode == "1") {
      return true;
    }

    if (mode != "auto") {
      return false;
    }

    const auto *term = std::getenv("TERM");

    return term != nullptr && std::string_view(term) != "dumb" && testing::internal::posix::IsATTY(testing::internal::posix::FileNo(stdout)) != 0;
  }

  inline auto diagnosticLine(std::string_view text, DiagnosticColor color, bool enabled = colorsEnabled()) -> std::string {
    if (!enabled) {
      return std::string(text);
    }

    const auto prefix = color == DiagnosticColor::Expected ? "\x1b[32m" : "\x1b[31m";

    return std::string(prefix) + std::string(text) + "\x1b[0m";
  }

  inline auto tokenIs(const ebnf::token &actual, ebnf::token_kind expected) -> testing::AssertionResult {
    if (actual.kind == expected) {
      return testing::AssertionSuccess();
    }

    return testing::AssertionFailure()
           << diagnosticLine("Expected next token: " + testing::PrintToString(expected), DiagnosticColor::Expected)
           << '\n'
           << diagnosticLine("Actual next token: " + testing::PrintToString(actual), DiagnosticColor::Actual);
  }

  inline auto childCount(ebnf::syntax_tree &tree, ebnf::node_handle parent) -> std::size_t {
    std::size_t count = 0;
    auto child = tree.getFirstChild(parent);

    while (child != ebnf::none_handle) {
      count++;
      child = tree.getFirstSibling(child);
    }

    return count;
  }

  inline auto nthChild(ebnf::syntax_tree &tree, ebnf::node_handle parent, std::size_t n) -> ebnf::node_handle {
    auto child = tree.getFirstChild(parent);

    for (std::size_t i = 0; i < n && child != ebnf::none_handle; i++) {
      child = tree.getFirstSibling(child);
    }

    return child;
  }

  template <typename T>
  inline auto nextTokenIs(ebnf::parser<T> &parser, ebnf::token_kind expected) -> testing::AssertionResult {
    try {
      return tokenIs(parser.peek(), expected);
    } catch (const std::exception &error) {
      return testing::AssertionFailure()
             << diagnosticLine("Expected next token: " + testing::PrintToString(expected), DiagnosticColor::Expected)
             << '\n'
             << diagnosticLine(std::string("Actual: peek() threw an exception: ") + error.what(), DiagnosticColor::Actual);
    } catch (...) {
      return testing::AssertionFailure()
             << diagnosticLine("Expected next token: " + testing::PrintToString(expected), DiagnosticColor::Expected)
             << '\n'
             << diagnosticLine("Actual: peek() threw a non-standard exception", DiagnosticColor::Actual);
    }
  }
}
