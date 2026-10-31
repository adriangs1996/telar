#include "parser.hpp"
#include "tests/parser_assertions.hpp"

#include <gtest/gtest.h>

namespace {
  TEST(Term, IdentifierProducesReference) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = foo ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(rhs), "foo");
  }

  TEST(Term, StringLiteralProducesLiteral) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = \"hello\" ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(rhs), "hello");
  }

  TEST(Term, SingleQuotedStringProducesLiteral) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = 'world' ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(rhs), "world");
  }

  TEST(Term, ParenthesesGroupWithoutCreatingNode) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( foo ) ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Reference);
    EXPECT_EQ(tree.getText(rhs), "foo");
  }

  TEST(Term, BracketsProduceOptional) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = [ foo ] ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

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

  TEST(Term, BracesProduceZeroOrMore) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = { foo } ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

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

  TEST(Term, MismatchedParensThrow) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("a = ( foo ] ;"), std::logic_error);
  }

  TEST(Term, MismatchedBracketsThrow) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("a = [ foo ) ;"), std::logic_error);
  }

  TEST(Term, MismatchedBracesThrow) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("a = { foo ) ;"), std::logic_error);
  }

  TEST(Term, NestedBracketsInsideParens) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = ( [ foo ] ) ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

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

  TEST(Term, BracesInsideBracketsNest) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = [ { foo } ] ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::Optional);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto zom = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(zom, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(zom), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, zom), 1u);

    const auto leaf = parser_testing::nthChild(tree, zom, 0);
    ASSERT_NE(leaf, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(leaf), ebnf::node_kind::Reference);
  }

  TEST(Term, LiteralInsideBraces) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse("a = { \"x\" } ;");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);

    const auto rhs = parser_testing::nthChild(tree, rule, 0);
    ASSERT_NE(rhs, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rhs), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, rhs), 1u);

    const auto inner = parser_testing::nthChild(tree, rhs, 0);
    ASSERT_NE(inner, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(inner), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(inner), "x");
  }
}
