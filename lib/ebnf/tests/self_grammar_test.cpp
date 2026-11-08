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
  TEST(Grammar, ParsesItsOwnGrammar) {
    // Preserve the grammar's escape spellings rather than substituting control characters.
    constexpr auto source = std::string_view{R"ebnf(
letter = "A" | "B" | "C" | "D" | "E" | "F" | "G"
       | "H" | "I" | "J" | "K" | "L" | "M" | "N"
       | "O" | "P" | "Q" | "R" | "S" | "T" | "U"
       | "V" | "W" | "X" | "Y" | "Z" | "a" | "b"
       | "c" | "d" | "e" | "f" | "g" | "h" | "i"
       | "j" | "k" | "l" | "m" | "n" | "o" | "p"
       | "q" | "r" | "s" | "t" | "u" | "v" | "w"
       | "x" | "y" | "z" ;

digit = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;

symbol = "[" | "]" | "{" | "}" | "(" | ")" | "<" | ">"
       | "'" | '"' | "=" | "|" | "." | "," | ";" | "-"
       | "+" | "*" | "?" | "\n" | "\t" | "\r" | "\f" | "\b" ;

character = letter | digit | symbol | "_" | " " ;
identifier = letter , { letter | digit | "_" } ;

S = { " " | "\n" | "\t" | "\r" | "\f" | "\b" } ;

escape = "\\" , ( "n" | "t" | "r" | "f" | "b" | "\\" | "'" | '"' ) ;

terminal = "'" , ( escape | character - "'" ) , { escape | character - "'" } , "'"
         | '"' , ( escape | character - '"' ) , { escape | character - '"' } , '"' ;

terminator = ";" | "." ;

term = "(" , S , rhs , S , ")"
     | "[" , S , rhs , S , "]"
     | "{" , S , rhs , S , "}"
     | terminal
     | identifier ;

factor = term , S , "?"
       | term , S , "*"
       | term , S , "+"
       | term , S , "-" , S , term
       | term , S ;

concatenation = ( S , factor , S , "," ? ) + ;
alternation = ( S , concatenation , S , "|" ? ) + ;

rhs = alternation ;
lhs = identifier ;

rule = lhs , S , "=" , S , rhs , S , terminator ;

grammar = ( S , rule , S ) * ;
)ebnf"};
    constexpr auto expected_names = std::to_array<std::string_view>({
        "letter",
        "digit",
        "symbol",
        "character",
        "identifier",
        "S",
        "escape",
        "terminal",
        "terminator",
        "term",
        "factor",
        "concatenation",
        "alternation",
        "rhs",
        "lhs",
        "rule",
        "grammar",
    });
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(source);
    const auto root = tree.getRoot();

    ASSERT_EQ(tree.getKind(root), ebnf::node_kind::Root);
    ASSERT_EQ(parser_testing::childCount(tree, root), expected_names.size());
    EXPECT_TRUE(parser_testing::nextTokenIs(parser, ebnf::token_kind::End));

    for (std::size_t index = 0; index < expected_names.size(); ++index) {
      SCOPED_TRACE(expected_names[index]);
      const auto rule = parser_testing::nthChild(tree, root, index);
      EXPECT_EQ(tree.getKind(rule), ebnf::node_kind::Rule);
      EXPECT_EQ(tree.getText(rule), expected_names[index]);
      ASSERT_EQ(parser_testing::childCount(tree, rule), 1u);
    }

    const auto letter_rule = parser_testing::nthChild(tree, root, 0);
    const auto letters = tree.getFirstChild(letter_rule);
    EXPECT_EQ(tree.getKind(letters), ebnf::node_kind::Alternative);
    EXPECT_EQ(parser_testing::childCount(tree, letters), 52u);

    const auto digit_rule = parser_testing::nthChild(tree, root, 1);
    const auto digits = tree.getFirstChild(digit_rule);
    EXPECT_EQ(tree.getKind(digits), ebnf::node_kind::Alternative);
    EXPECT_EQ(parser_testing::childCount(tree, digits), 10u);

    const auto escape_rule = parser_testing::nthChild(tree, root, 6);
    const auto escape = tree.getFirstChild(escape_rule);
    ASSERT_EQ(tree.getKind(escape), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, escape), 2u);
    const auto backslash = tree.getFirstChild(escape);
    EXPECT_EQ(tree.getKind(backslash), ebnf::node_kind::Literal);
    EXPECT_EQ(tree.getText(backslash), R"(\\)");
    const auto escape_codes = tree.getFirstSibling(backslash);
    EXPECT_EQ(tree.getKind(escape_codes), ebnf::node_kind::Alternative);
    EXPECT_EQ(parser_testing::childCount(tree, escape_codes), 8u);

    const auto grammar_rule = parser_testing::nthChild(tree, root, expected_names.size() - 1);
    const auto repetition = tree.getFirstChild(grammar_rule);
    ASSERT_EQ(tree.getKind(repetition), ebnf::node_kind::ZeroOrMore);
    ASSERT_EQ(parser_testing::childCount(tree, repetition), 1u);
    const auto sequence = tree.getFirstChild(repetition);
    EXPECT_EQ(tree.getKind(sequence), ebnf::node_kind::Concatenation);
    ASSERT_EQ(parser_testing::childCount(tree, sequence), 3u);
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, sequence, 0)), "S");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, sequence, 1)), "rule");
    EXPECT_EQ(tree.getText(parser_testing::nthChild(tree, sequence, 2)), "S");
  }
}
