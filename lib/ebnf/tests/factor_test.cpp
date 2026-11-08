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
  TEST(Factor, QuestionSuffixProducesOptional) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ? ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Optional);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(inner), "foo");
  }

  TEST(Factor, AsterSuffixProducesZeroOrMore) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo * ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(inner), "foo");
  }

  TEST(Factor, PlusSuffixProducesOneOrMore) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo + ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::OneOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(inner), "foo");
  }

  TEST(Factor, MinusProducesException) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo - bar ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Exception);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto left = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(left, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(left), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(left), "foo");

    const auto right = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(right, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(right), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(right), "bar");
  }

  TEST(Factor, BareTermPassesThroughWithoutWrapping) {
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

  TEST(Factor, SuffixOnGroupedAlternation) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( foo | bar ) * ;");
    const auto root = tree.getRoot();

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
    ASSERT_EQ(parser_testing::childCount(tree, alt), 2u);

    const auto first = parser_testing::nthChild(tree, alt, 0);
    ASSERT_EQ(tree.getKind(first), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, first), 1u);
    EXPECT_EQ(tree.getText(tree.getFirstChild(first)), "foo");

    const auto second = parser_testing::nthChild(tree, alt, 1);
    ASSERT_EQ(tree.getKind(second), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, second), 1u);
    EXPECT_EQ(tree.getText(tree.getFirstChild(second)), "bar");
  }

  TEST(Factor, SuffixOnLiteral) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = \"x\" + ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::OneOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(inner), "x");
  }

  TEST(Factor, ExceptionWithLiterals) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = character - \"'\" ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Exception);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 2u);

    const auto left = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(left, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(left), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(left), "character");

    const auto right = parser_testing::nthChild(tree, rhs, 1);
    ASSERT_NE(right, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(right), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(right), "'");
  }

  TEST(Factor, QuestionOnBracketedGroup) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = [ foo ] ? ;");
    const auto root = tree.getRoot();

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Optional);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Optional);
  }
}
