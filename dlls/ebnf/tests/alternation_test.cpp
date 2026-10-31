#include "parser.hpp"
#include "tests/parser_assertions.hpp"

#include <gtest/gtest.h>

namespace {
  TEST(Alternation, SingleConcatenationUnwraps) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ;");
    const auto root = tree.getRoot();
    const auto rule = parser_testing::nthChild(tree, root, 0);

    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(tree.getKind(rule), ebnf::node_kind::Rule);
    ASSERT_EQ(tree.getText(rule), "a");
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = tree.getFirstChild(rule);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(rhs), "foo");
    EXPECT_EQ(parser_testing::childCount(tree, rhs), 0u);
  }

  TEST(Alternation, ThreeAlternativesAreFlatNotNested) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo | bar | baz ;");
    const auto root = tree.getRoot();
    const auto rule = tree.getFirstChild(root);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(tree.getKind(rule), ebnf::node_kind::Rule);
    ASSERT_EQ(tree.getText(rule), "a");

    const auto alternative = tree.getFirstChild(rule);
    ASSERT_NE(alternative, ebnf::none_handle);
    const auto foo_concat = tree.getFirstChild(alternative);
    const auto foo_fact = tree.getFirstChild(foo_concat);
    ASSERT_EQ(tree.getText(foo_fact), "foo");

    const auto bar_concat = tree.getFirstSibling(foo_concat);
    const auto bar_fact = tree.getFirstChild(bar_concat);
    ASSERT_EQ(tree.getText(bar_fact), "bar");

    const auto baz_concat = tree.getFirstSibling(bar_concat);
    const auto baz_fact = tree.getFirstChild(baz_concat);
    ASSERT_EQ(tree.getText(baz_fact), "baz");
  }

  TEST(Alternation, ManyLiteralAlternatives) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(R"(d = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;)");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    auto child = tree.getFirstChild(rule);
    ASSERT_NE(child, ebnf::none_handle);
    auto concat = ebnf::none_handle;

    for (std::size_t index = 0; index < 10; ++index) {
      SCOPED_TRACE(index);

      if (concat == ebnf::none_handle) {
        concat = tree.getFirstChild(child);
      } else {
        concat = tree.getFirstSibling(concat);
      }

      ASSERT_NE(concat, ebnf::none_handle);
      const auto factor = tree.getFirstChild(concat);
      ASSERT_NE(factor, ebnf::none_handle);
      ASSERT_EQ(tree.getKind(factor), ebnf::node_kind::Literal);
      EXPECT_EQ(tree.getText(factor), std::string(1, static_cast<char>('0' + index)));
    }
  }

  TEST(Alternation, PipeBindsLooserThanComma) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo , bar | baz ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto left = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(left, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(left), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, left), 2u);
    auto foo = tree.getFirstChild(left);
    ASSERT_NE(foo, ebnf::none_handle);
    ASSERT_EQ(tree.getKind(foo), ebnf::node_kind::Reference);
    ASSERT_EQ(tree.getText(foo), "foo");

    auto bar = tree.getFirstSibling(foo);
    ASSERT_NE(bar, ebnf::none_handle);
    ASSERT_EQ(tree.getKind(bar), ebnf::node_kind::Reference);
    ASSERT_EQ(tree.getText(bar), "bar");

    const auto right = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(right, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(right), ebnf::node_kind::Concatenation);
    auto baz = tree.getFirstChild(right);
    ASSERT_NE(baz, ebnf::none_handle);
    ASSERT_EQ(tree.getKind(baz), ebnf::node_kind::Reference);
    ASSERT_EQ(tree.getText(baz), "baz");
  }

  TEST(Alternation, AlternativeOfTwoConcatenations) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo , bar | baz , qux ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto left = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(left, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(left), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, left), 2u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, left, 0)), "foo");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, left, 1)), "bar");

    const auto right = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(right, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(right), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, right), 2u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, right, 0)), "baz");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, right, 1)), "qux");
  }

  TEST(Alternation, AlternativeInsideGroup) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( foo | bar ) ;");
    const auto root = tree.getRoot();

    const auto rule = tree.getFirstChild(root);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    for (std::size_t index = 0; index < 2; ++index) {
      SCOPED_TRACE(index);
      const auto branch = parser_testing::nthChild(tree, rhs, index);
      ASSERT_EQ(tree.getKind(branch), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, branch), 1u);
      const auto factor = tree.getFirstChild(branch);
      EXPECT_EQ(tree.getKind(factor), ebnf::node_kind::Reference);
      EXPECT_EQ(tree.getText(factor), index == 0 ? "foo" : "bar");
    }
  }

  TEST(Alternation, NestedParenthesesDoNotAddWrappers) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ((( foo | bar ))) ;");
    const auto rule = tree.getFirstChild(tree.getRoot());
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto alt = tree.getFirstChild(rule);
    ASSERT_EQ(tree.getKind(alt), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, alt), 2u);

    for (std::size_t index = 0; index < 2; ++index) {
      SCOPED_TRACE(index);
      const auto branch = parser_testing::nthChild(tree, alt, index);
      ASSERT_EQ(tree.getKind(branch), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, branch), 1u);
      const auto factor = tree.getFirstChild(branch);
      EXPECT_EQ(tree.getKind(factor), ebnf::node_kind::Reference);
      EXPECT_EQ(tree.getText(factor), index == 0 ? "foo" : "bar");
    }
  }

  TEST(Alternation, GroupedAlternativeRemainsInsideItsBranch) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( foo | bar ) | baz ;");
    const auto rule = tree.getFirstChild(tree.getRoot());
    const auto alt = tree.getFirstChild(rule);
    ASSERT_EQ(tree.getKind(alt), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, alt), 2u);

    const auto first = tree.getFirstChild(alt);
    ASSERT_EQ(tree.getKind(first), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, first), 1u);
    const auto inner = tree.getFirstChild(first);
    ASSERT_EQ(tree.getKind(inner), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, inner), 2u);

    for (std::size_t index = 0; index < 2; ++index) {
      SCOPED_TRACE(index);
      const auto branch = parser_testing::nthChild(tree, inner, index);
      ASSERT_EQ(tree.getKind(branch), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, branch), 1u);
      EXPECT_EQ(tree.getText(tree.getFirstChild(branch)), index == 0 ? "foo" : "bar");
    }

    const auto second = tree.getFirstSibling(first);
    ASSERT_EQ(tree.getKind(second), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, second), 1u);
    EXPECT_EQ(tree.getText(tree.getFirstChild(second)), "baz");
  }

  TEST(Alternation, AlternativeInsideBrackets) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = [ foo | bar ] ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Optional);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto alt = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(alt, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(alt), ebnf::node_kind::Alternative);
    ASSERT_EQ(parser_testing::childCount(tree, alt), 2u);

    for (std::size_t index = 0; index < 2; ++index) {
      SCOPED_TRACE(index);
      const auto branch = parser_testing::nthChild(tree, alt, index);
      ASSERT_EQ(tree.getKind(branch), ebnf::node_kind::Concatenation);
      ASSERT_EQ(parser_testing::childCount(tree, branch), 1u);
      const auto factor = tree.getFirstChild(branch);
      EXPECT_EQ(tree.getKind(factor), ebnf::node_kind::Reference);
      EXPECT_EQ(tree.getText(factor), index == 0 ? "foo" : "bar");
    }
  }
}
