#ifdef __clangd__
static_assert(true);
#endif
#include <tbc/view.hpp>
#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>

#include "tests/parser_assertions.hpp"

#include <gtest/gtest.h>

import telar.ebnf.parser;
namespace {
  auto parse(std::string_view source) -> ebnf::syntax_tree {
    auto tokenizer = ebnf::Lexer{};
    auto parser = std::make_unique<ebnf::parser<ebnf::Lexer>>(tokenizer);
    return parser->parse(source);
  }

  auto ruleBody(ebnf::syntax_tree &tree, std::size_t rule) -> ebnf::node_handle {
    return tree.getFirstChild(parser_testing::nthChild(tree, tree.getRoot(), rule));
  }

  TEST(Comment, IsIgnoredBetweenTokens) {
    auto tree = parse("(* leading *) a (* inside *) = \"x\" (* before end *) ; (* trailing *)");

    ASSERT_EQ(parser_testing::childCount(tree, tree.getRoot()), 1u);
    const auto body = ruleBody(tree, 0);
    EXPECT_EQ(tree.getKind(body), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(body), "x");
  }

  TEST(Comment, NestsAndHoldsAnyByte) {
    auto tree = parse("(* outer (* inner *) still outer; \"quote @ \xc3\xa9 *) a = b ;");

    ASSERT_EQ(parser_testing::childCount(tree, tree.getRoot()), 1u);
    EXPECT_EQ(tree.getKind(ruleBody(tree, 0)), ebnf::node_kind::Reference);
  }

  TEST(Comment, DelimitersInsideLiteralsAreText) {
    auto tree = parse(R"ebnf(a = "(*" , "*)" ;)ebnf");
    const auto body = ruleBody(tree, 0);

    ASSERT_EQ(parser_testing::childCount(tree, body), 2u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, body, 0)), "(*");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, body, 1)), "*)");
  }

  TEST(Comment, UnterminatedCommentThrows) {
    for (const auto source : {"(* open", "a = b ; (* (* nested *)", "(*)"}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(parse(source), std::invalid_argument);
    }
  }

  TEST(Dynamic, NamesItsProviderWithoutTheAt) {
    auto tree = parse("a = @branch , @ssh_host2 ;");
    const auto body = ruleBody(tree, 0);

    ASSERT_EQ(tree.getKind(body), ebnf::node_kind::Concatenation);
    const auto first = parser_testing::nthChild(tree, body, 0);
    const auto second = parser_testing::nthChild(tree, body, 1);
    EXPECT_EQ(tree.getKind(first), ebnf::node_kind::Dynamic);
    EXPECT_EQ(tree.getText(first), "branch");
    EXPECT_EQ(tree.getKind(second), ebnf::node_kind::Dynamic);
    EXPECT_EQ(tree.getText(second), "ssh_host2");
    EXPECT_EQ(parser_testing::childCount(tree, first), 0u);
  }

  TEST(Description, IsTheOnlyChildOfItsTerminal) {
    auto tree = parse(R"(a = "switch" : "Switch branches" | @file : 'A path, maybe "quoted"' ;)");
    const auto body = ruleBody(tree, 0);

    ASSERT_EQ(tree.getKind(body), ebnf::node_kind::Alternative);
    const auto literal = tree.getFirstChild(parser_testing::nthChild(tree, body, 0));
    const auto dynamic = tree.getFirstChild(parser_testing::nthChild(tree, body, 1));
    ASSERT_EQ(tree.getKind(literal), ebnf::node_kind::Literal);
    ASSERT_EQ(parser_testing::childCount(tree, literal), 1u);
    EXPECT_EQ(tree.getKind(tree.getFirstChild(literal)), ebnf::node_kind::Description);
    EXPECT_EQ(tree.getText(tree.getFirstChild(literal)), "Switch branches");
    ASSERT_EQ(tree.getKind(dynamic), ebnf::node_kind::Dynamic);
    EXPECT_EQ(tree.getText(tree.getFirstChild(dynamic)), R"(A path, maybe "quoted")");
  }

  TEST(Description, AllowsPostfixOperatorsAfterIt) {
    auto tree = parse(R"(a = "-v" : "verbose" * ;)");
    const auto body = ruleBody(tree, 0);

    ASSERT_EQ(tree.getKind(body), ebnf::node_kind::ZeroOrMore);
    EXPECT_EQ(tree.getKind(tree.getFirstChild(body)), ebnf::node_kind::Literal);
  }

  TEST(Description, OnlyAnnotatesTerminals) {
    for (const auto source : {R"(a = b : "x" ;)", R"(a = ( "b" ) : "x" ;)", R"(a = "b" : c ;)", R"(a = "b" : ;)"}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(parse(source), std::invalid_argument);
    }
  }

  TEST(Glue, KeepsPrefixAndValueAsOrderedChildren) {
    auto tree = parse(R"(a = "--color=" : "When to color" ~ ( "always" | "never" ) , "x" ;)");
    const auto body = ruleBody(tree, 0);

    ASSERT_EQ(tree.getKind(body), ebnf::node_kind::Concatenation);
    const auto glue = tree.getFirstChild(body);
    ASSERT_EQ(tree.getKind(glue), ebnf::node_kind::Glue);
    ASSERT_EQ(parser_testing::childCount(tree, glue), 2u);
    const auto prefix = parser_testing::nthChild(tree, glue, 0);
    EXPECT_EQ(tree.getKind(prefix), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(prefix), "--color=");
    EXPECT_EQ(tree.getText(tree.getFirstChild(prefix)), "When to color");
    const auto value = parser_testing::nthChild(tree, glue, 1);
    EXPECT_EQ(tree.getKind(value), ebnf::node_kind::Alternative);
    EXPECT_EQ(parser_testing::childCount(tree, value), 2u);
    EXPECT_EQ(tree.getText(tree.getFirstSibling(glue)), "x");
  }

  TEST(Glue, AcceptsDynamicAndReferenceValues) {
    auto tree = parse(R"(a = "--format=" ~ @any | "--when=" ~ when ;)");
    const auto body = ruleBody(tree, 0);

    const auto first = tree.getFirstChild(parser_testing::nthChild(tree, body, 0));
    const auto second = tree.getFirstChild(parser_testing::nthChild(tree, body, 1));
    ASSERT_EQ(tree.getKind(first), ebnf::node_kind::Glue);
    EXPECT_EQ(tree.getKind(parser_testing::nthChild(tree, first, 1)), ebnf::node_kind::Dynamic);
    ASSERT_EQ(tree.getKind(second), ebnf::node_kind::Glue);
    EXPECT_EQ(tree.getKind(parser_testing::nthChild(tree, second, 1)), ebnf::node_kind::Reference);
  }

  TEST(Glue, NeedsAValueTerm) {
    for (const auto source : {R"(a = "--x=" ~ ;)", R"(a = "--x=" ~ , b ;)"}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(parse(source), std::invalid_argument);
    }
  }

  TEST(SyntaxError, EverySyntaxErrorIsInvalidArgument) {
    for (const auto source : {"a b ;", "a = b", "a = ( b ;", "a = [ b ;", "a = { b ;", "a = b , ;", "a = | b ;", "= b ;"}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(parse(source), std::invalid_argument);
    }
  }

  TEST(SyntaxError, BracketNestingIsBounded) {
    const auto nested = [](std::size_t depth) {
      return "a = " + std::string(depth, '(') + "b" + std::string(depth, ')') + " ;";
    };

    EXPECT_NO_THROW(parse(nested(ebnf::max_nesting_depth)));
    EXPECT_THROW(parse(nested(ebnf::max_nesting_depth + 1)), std::invalid_argument);
  }

  TEST(Literal, AcceptsPrintableAsciiForDescriptions) {
    auto tree = parse(R"(a = "HEAD@{1}" : "Reflog: 1 move ago (see ~/.gitconfig) #!$%&^`" ;)");
    const auto body = ruleBody(tree, 0);

    EXPECT_EQ(tree.getText(body), "HEAD@{1}");
    EXPECT_EQ(tree.getText(tree.getFirstChild(body)), "Reflog: 1 move ago (see ~/.gitconfig) #!$%&^`");
  }
}
