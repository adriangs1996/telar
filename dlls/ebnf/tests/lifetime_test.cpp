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

#include <string>

import telar.ebnf.parser;
namespace {
  auto parseWithLocalParser(std::string_view source) -> ebnf::syntax_tree {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    return parser.parse(source);
  }

  TEST(Lifetime, TreeDoesNotBorrowTheParserObject) {
    const auto source = std::string{"letters = 'abc';"};
    auto tree = parseWithLocalParser(source);
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "letters");
    ASSERT_TRUE(tree.getText(rule).has_value());
    EXPECT_EQ(tree.getText(rule)->data(), source.data());
  }

  TEST(Lifetime, ShallowCopiesAndMovesKeepTheSourceBorrow) {
    const auto source = std::string{"letters = 'abc';"};
    auto tree = parseWithLocalParser(source);
    auto copied = tree;
    auto moved = std::move(copied);
    const auto root = moved.getRoot();

    const auto rule = parser_testing::nthChild(moved, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_TRUE(moved.getText(rule).has_value());
    EXPECT_EQ(moved.getText(rule)->data(), source.data());
  }

  TEST(Lifetime, DeepTextCopyOwnsItsBytes) {
    auto copied = std::string{};
    {
      const auto source = std::string{"letters = 'abc';"};
      auto tree = parseWithLocalParser(source);
      const auto root = tree.getRoot();

      const auto rule = parser_testing::nthChild(tree, root, 0);
      ASSERT_NE(rule, ebnf::none_handle);
      ASSERT_TRUE(tree.getText(rule).has_value());
      copied = std::string{*tree.getText(rule)};
    }

    EXPECT_EQ(copied, "letters");
  }

  TEST(Lifetime, ReusingParserDoesNotInvalidateEarlierTrees) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    const auto first_source = std::string{"letters = 'abc';"};
    const auto second_source = std::string{"digits = '012';"};
    auto first = parser.parse(first_source);
    auto second = parser.parse(second_source);

    const auto r0 = parser_testing::nthChild(first, first.getRoot(), 0);
    ASSERT_NE(r0, ebnf::none_handle);
    ASSERT_TRUE(first.getText(r0).has_value());
    EXPECT_EQ(first.getText(r0)->data(), first_source.data());

    const auto r1 = parser_testing::nthChild(second, second.getRoot(), 0);
    ASSERT_NE(r1, ebnf::none_handle);
    ASSERT_TRUE(second.getText(r1).has_value());
    EXPECT_EQ(second.getText(r1)->data(), second_source.data());
  }
}
