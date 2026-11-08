#ifdef __clangd__
static_assert(true);
#endif
#include <tbc/view.hpp>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>
#include <optional>
#include <utility>
#include <vector>

#include "tests/parser_assertions.hpp"

#include <gtest/gtest.h>

import telar.ebnf.parser;
namespace {
  TEST(AST, IdentifierRuleProducesExpectedShape) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(R"(identifier = letter , { letter | digit | "_" } ;)");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "identifier");
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto first = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(first, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(first), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(first), "letter");

    const auto rep = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(rep, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rep), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rep), 1u);

    const auto alt = parser_testing::nthChild(tree, rep, 0);
    ASSERT_NE(alt, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(alt), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, alt), 3u);

    const auto expected_texts = {"letter", "digit", "_"};
    std::size_t index = 0;

    for (const auto text : expected_texts) {
      SCOPED_TRACE(index);
      const auto branch = parser_testing::nthChild(tree, alt, index);
      ASSERT_EQ(tree.getKind(branch), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, branch), 1u);
      const auto factor = tree.getFirstChild(branch);
      EXPECT_EQ(tree.getKind(factor), index == 2 ? ebnf::node_kind::Literal : ebnf::node_kind::Reference);
      EXPECT_EQ(tree.getText(factor), text);
      ++index;
    }
  }

  TEST(AST, TerminalRuleWithExceptionAndRepetition) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(R"(terminal = "'" , character - "'" , { character - "'" } , "'" ;)");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "terminal");
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 4u);

    const auto c0 = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(c0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c0), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(c0), "'");

    const auto c1 = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(c1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c1), ebnf::node_kind::Exception);
    ASSERT_EQ(parser_testing::childCount(tree, c1), 2u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, c1, 0)), "character");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, c1, 1)), "'");

    const auto c2 = parser_testing::nthChild(tree, rhs, 2);
    ASSERT_NE(c2, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c2), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, c2), 1u);

    const auto inner = parser_testing::nthChild(tree, c2, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Exception);

    const auto c3 = parser_testing::nthChild(tree, rhs, 3);
    ASSERT_NE(c3, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c3), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(c3), "'");
  }

  TEST(AST, FactorRuleFiveAlternatives) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(
        "factor = term , \"?\" "
        "| term , \"*\" "
        "| term , \"+\" "
        "| term , \"-\" , term "
        "| term ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "factor");
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 5u);

    for (std::size_t index = 0; index < 4; ++index) {
      SCOPED_TRACE(index);

      const auto child = parser_testing::nthChild(tree, rhs, index);
      ASSERT_NE(child, ebnf::none_handle);
      EXPECT_EQ(tree.getKind(child), ebnf::node_kind::Concatenation);
    }

    const auto last = parser_testing::nthChild(tree, rhs, 4);
    ASSERT_EQ(tree.getKind(last), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, last), 1u);
    const auto factor = tree.getFirstChild(last);
    EXPECT_EQ(tree.getKind(factor), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(factor), "term");
  }

  TEST(AST, ConcatenationWithOneOrMore) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(R"(concatenation = ( factor , "," ? ) + ;)");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "concatenation");
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::OneOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto group = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(group, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(group), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, group), 2u);

    const auto g0 = parser_testing::nthChild(tree, group, 0);
    ASSERT_NE(g0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(g0), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(g0), "factor");

    const auto g1 = parser_testing::nthChild(tree, group, 1);
    ASSERT_NE(g1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(g1), ebnf::node_kind::Optional);
  }

  TEST(AST, GrammarRuleWithZeroOrMore) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("grammar = ( rule ) * ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "grammar");
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(inner), "rule");
  }

  TEST(AST, TwoRulesPreserveIndependentTrees) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(
        "lhs = identifier ;\n"
        "rhs = alternation ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 2u);

    const auto r0 = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(r0, ebnf::none_handle);
    EXPECT_EQ(tree.getText(r0), "lhs");
    ASSERT_EQ(parser_testing::childCount(tree, r0), 1u);

    const auto rhs0 = parser_testing::nthChild(tree, r0, 0);
    ASSERT_NE(rhs0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs0), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(rhs0), "identifier");

    const auto r1 = parser_testing::nthChild(tree, root, 1);
    ASSERT_NE(r1, ebnf::none_handle);
    EXPECT_EQ(tree.getText(r1), "rhs");
    ASSERT_EQ(parser_testing::childCount(tree, r1), 1u);

    const auto rhs1 = parser_testing::nthChild(tree, r1, 0);
    ASSERT_NE(rhs1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs1), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(rhs1), "alternation");
  }

  TEST(AST, TermRuleWithFiveAlternatives) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(
        "term = \"(\" , rhs , \")\" "
        "| \"[\" , rhs , \"]\" "
        "| \"{\" , rhs , \"}\" "
        "| terminal "
        "| identifier ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 5u);

    const auto first_concat = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(first_concat, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(first_concat), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, first_concat), 3u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, first_concat, 0)), "(");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, first_concat, 1)), "rhs");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, first_concat, 2)), ")");

    const auto fourth = parser_testing::nthChild(tree, rhs, 3);
    ASSERT_EQ(tree.getKind(fourth), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, fourth), 1u);
    const auto terminal = tree.getFirstChild(fourth);
    EXPECT_EQ(tree.getKind(terminal), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(terminal), "terminal");

    const auto fifth = parser_testing::nthChild(tree, rhs, 4);
    ASSERT_EQ(tree.getKind(fifth), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, fifth), 1u);
    const auto identifier = tree.getFirstChild(fifth);
    EXPECT_EQ(tree.getKind(identifier), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(identifier), "identifier");
  }

  TEST(AST, RuleRuleConcatenation) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(R"(rule = lhs , "=" , rhs , terminator ;)");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 4u);

    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 0)), "lhs");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 1)), "=");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 2)), "rhs");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 3)), "terminator");
  }

  TEST(AST, WhitespaceRuleAlternativeOfLiterals) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("S = { \" \" | \"\n\" | \"\t\" } ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto alt = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(alt, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(alt), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, alt), 3u);

    for (std::size_t index = 0; index < 3; ++index) {
      SCOPED_TRACE(index);

      const auto child = parser_testing::nthChild(tree, alt, index);
      ASSERT_EQ(tree.getKind(child), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, child), 1u);
      const auto literal = tree.getFirstChild(child);
      EXPECT_EQ(tree.getKind(literal), ebnf::node_kind::Literal);
      EXPECT_EQ(tree.getText(literal), std::string_view{" \n\t"}.substr(index, 1));
    }
  }

  TEST(AST, FullMiniGrammarParsesAllRules) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(
        R"(digit = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;)"
        "\n"
        R"(identifier = letter , { letter | digit | "_" } ;)"
        "\n"
        R"(terminal = "'" , character - "'" , { character - "'" } , "'" ;)"
        "\n"
        R"(grammar = ( rule ) * ;)");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 4u);

    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 0)), "digit");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 1)), "identifier");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 2)), "terminal");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 3)), "grammar");

    const auto digit_rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(digit_rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, digit_rule), 1u);

    const auto digit_rhs = parser_testing::nthChild(tree, digit_rule, 0);
    ASSERT_NE(digit_rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(digit_rhs), ebnf::node_kind::Alternative);
    EXPECT_EQ(parser_testing::childCount(tree, digit_rhs), 10u);

    const auto grammar_rule = parser_testing::nthChild(tree, root, 3);
    ASSERT_NE(grammar_rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, grammar_rule), 1u);

    const auto grammar_rhs = parser_testing::nthChild(tree, grammar_rule, 0);
    ASSERT_NE(grammar_rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(grammar_rhs), ebnf::node_kind::ZeroOrMore);
  }
}
