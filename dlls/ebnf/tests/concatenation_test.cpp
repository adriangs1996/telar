#include "parser.hpp"
#include "tests/parser_assertions.hpp"

#include <gtest/gtest.h>

namespace {
  TEST(Concatenation, SingleFactorUnwrapsToDirectNode) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(rhs), "foo");
  }

  TEST(Concatenation, TwoFactorsWithComma) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo , bar ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto first = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(first, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(first), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(first), "foo");

    const auto second = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(second, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(second), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(second), "bar");
  }

  TEST(Concatenation, ThreeFactorsAreFlatNotNested) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo , bar , baz ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 3u);

    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 0)), "foo");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 1)), "bar");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, rhs, 2)), "baz");
  }

  TEST(Concatenation, MixedTermTypes) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo , \"x\" , bar ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 3u);

    const auto c0 = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(c0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c0), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(c0), "foo");

    const auto c1 = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(c1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c1), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(c1), "x");

    const auto c2 = parser_testing::nthChild(tree, rhs, 2);
    ASSERT_NE(c2, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c2), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(c2), "bar");
  }

  TEST(Concatenation, FactorsWithSuffixes) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ? , bar * ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto c0 = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(c0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c0), ebnf::node_kind::Optional);

    const auto c1 = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(c1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c1), ebnf::node_kind::ZeroOrMore);
  }

  TEST(Concatenation, FactorWithGroupedExpression) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = \"(\" , foo , \")\" ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 3u);

    const auto c0 = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(c0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c0), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(c0), "(");

    const auto c1 = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(c1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c1), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(c1), "foo");

    const auto c2 = parser_testing::nthChild(tree, rhs, 2);
    ASSERT_NE(c2, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c2), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(c2), ")");
  }

  TEST(Concatenation, GroupedAlternativeRemainsOneFactor) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( foo | bar ) , baz ;");
    const auto rule = tree.getFirstChild(tree.getRoot());
    const auto concat = tree.getFirstChild(rule);
    ASSERT_EQ(tree.getKind(concat), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, concat), 2u);

    const auto alt = tree.getFirstChild(concat);
    ASSERT_EQ(tree.getKind(alt), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, alt), 2u);

    for (std::size_t index = 0; index < 2; ++index) {
      SCOPED_TRACE(index);
      const auto branch = parser_testing::nthChild(tree, alt, index);
      ASSERT_EQ(tree.getKind(branch), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, branch), 1u);
      EXPECT_EQ(tree.getText(tree.getFirstChild(branch)), index == 0 ? "foo" : "bar");
    }

    const auto last = tree.getFirstSibling(alt);
    EXPECT_EQ(tree.getKind(last), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(last), "baz");
  }

  TEST(Concatenation, GroupedConcatenationDoesNotAbsorbOuterSibling) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( foo , bar ) , baz ;");
    const auto rule = tree.getFirstChild(tree.getRoot());
    const auto concat = tree.getFirstChild(rule);
    ASSERT_EQ(tree.getKind(concat), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, concat), 2u);

    const auto inner = tree.getFirstChild(concat);
    ASSERT_EQ(tree.getKind(inner), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, inner), 2u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, inner, 0)), "foo");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, inner, 1)), "bar");

    const auto last = tree.getFirstSibling(inner);
    EXPECT_EQ(tree.getKind(last), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(last), "baz");
  }

  TEST(Concatenation, ExceptionInsideConcatenation) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = x - y , z ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto c0 = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(c0, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c0), ebnf::node_kind::Exception);

    const auto c1 = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(c1, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(c1), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(c1), "z");
  }
}
