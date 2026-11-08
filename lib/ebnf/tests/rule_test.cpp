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
  TEST(Rule, SemicolonTerminator) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rule), ebnf::node_kind::Rule);
    EXPECT_EQ(tree.getText(rule), "a");
    EXPECT_TRUE(parser_testing::nextTokenIs(parser, ebnf::token_kind::End));
  }

  TEST(Rule, DotTerminator) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo .");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rule), ebnf::node_kind::Rule);
    EXPECT_EQ(tree.getText(rule), "a");
    EXPECT_TRUE(parser_testing::nextTokenIs(parser, ebnf::token_kind::End));
  }

  TEST(Rule, RuleTextBorrowsSource) {
    const auto source = std::string_view{"my_rule = foo ;"};
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(source);
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "my_rule");
    ASSERT_TRUE(tree.getText(rule).has_value());
    EXPECT_EQ(tree.getText(rule)->data(), source.data());
  }

  TEST(Rule, MissingEqualThrows) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("a foo ;"), std::logic_error);
  }

  TEST(Rule, MissingTerminatorThrows) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("a = foo"), std::logic_error);
  }

  TEST(Rule, MissingRhsWithTerminatorThrows) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("a = ;"), std::invalid_argument);
  }

  TEST(Rule, UnderscoresInIdentifier) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("my_long_rule = foo ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "my_long_rule");
  }

  TEST(Rule, RhsHasExactlyOneChild) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo | bar ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);
  }

  TEST(Rule, MultipleRulesInSequence) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ; b = bar ; c = baz ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 3u);

    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 0)), "a");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 1)), "b");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 2)), "c");
  }

  TEST(Rule, MixedTerminators) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ; b = bar . c = baz ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 3u);

    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 0)), "a");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 1)), "b");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, root, 2)), "c");
  }

  TEST(Rule, RuleCanBeReusedAcrossParses) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    auto first = parser.parse("a = foo ;");
    ASSERT_EQ(parser_testing::childCount(first, first.getRoot()), 1u);
    EXPECT_EQ(first.getText(parser_testing::nthChild(first, first.getRoot(), 0)), "a");

    auto second = parser.parse("b = bar ;");
    ASSERT_EQ(parser_testing::childCount(second, second.getRoot()), 1u);
    EXPECT_EQ(second.getText(parser_testing::nthChild(second, second.getRoot(), 0)), "b");
  }

  TEST(Rule, NumberAsLhsThrows) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("123 = foo ;"), std::invalid_argument);
  }

  TEST(Rule, StringAsLhsThrows) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("\"bad\" = foo ;"), std::invalid_argument);
  }
}
