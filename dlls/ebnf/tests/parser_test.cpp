#include "parser.hpp"
#include "tests/parser_assertions.hpp"

#include <gtest/gtest.h>
#include <tbc/view.hpp>

#include <string_view>

namespace {
  TEST(Grammar, SingleRuleisAValidSentence) {
    const auto sentence = std::string_view{"letters = \"abcdefghi\";"};
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    auto tree = parser.parse(sentence);
    const auto root = tree.getRoot();

    EXPECT_EQ(tree.getKind(root), ebnf::node_kind::Root);
    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getKind(rule), ebnf::node_kind::Rule);
    EXPECT_EQ(tree.getText(rule), "letters");
    ASSERT_TRUE(tree.getText(rule).has_value());
    EXPECT_EQ(tree.getText(rule)->data(), sentence.data());
    EXPECT_TRUE(parser_testing::nextTokenIs(parser, ebnf::token_kind::End));
  }

  TEST(Grammar, LexerHandlesWhitespaceAndBothQuoteStyles) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    auto tree = parser.parse(" \n\tletters = 'a b';\r\ndigits=\"012\". \f\b");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 2u);

    const auto first = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(first, ebnf::none_handle);
    EXPECT_EQ(tree.getText(first), "letters");

    const auto second = parser_testing::nthChild(tree, root, 1);
    ASSERT_NE(second, ebnf::none_handle);
    EXPECT_EQ(tree.getText(second), "digits");
  }

  TEST(Grammar, EscapedLiteralBorrowsItsOriginalSourceSpelling) {
    constexpr auto source = std::string_view{R"ebnf(a = "a\n\"b\\c" ;)ebnf"};
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    auto tree = parser.parse(source);
    const auto rule = tree.getFirstChild(tree.getRoot());
    const auto literal = tree.getFirstChild(rule);

    ASSERT_EQ(tree.getKind(literal), ebnf::node_kind::Literal);
    ASSERT_TRUE(tree.getText(literal).has_value());
    EXPECT_EQ(*tree.getText(literal), R"(a\n\"b\\c)");
    EXPECT_EQ(tree.getText(literal)->data(), source.data() + source.find('"') + 1);
    EXPECT_TRUE(parser_testing::nextTokenIs(parser, ebnf::token_kind::End));
  }

  TEST(Grammar, EmptyInputProducesAnEmptyRoot) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    auto tree = parser.parse(" \n\t\r\f\b");
    const auto root = tree.getRoot();

    EXPECT_EQ(tree.getKind(root), ebnf::node_kind::Root);
    EXPECT_EQ(parser_testing::childCount(tree, root), 0u);
  }

  TEST(Grammar, ParserCanBeReusedAfterLexicalFailure) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};

    EXPECT_THROW(parser.parse("letters = 'unfinished"), std::invalid_argument);

    auto tree = parser.parse("letters = 'a';");
    const auto root = tree.getRoot();

    ASSERT_EQ(parser_testing::childCount(tree, root), 1u);

    const auto rule = parser_testing::nthChild(tree, root, 0);
    ASSERT_NE(rule, ebnf::none_handle);
    EXPECT_EQ(tree.getText(rule), "letters");
  }

  TEST(Grammar, EndCanBeConsumedWithoutAdvancingPastTheBuffer) {
    auto tokenizer = ebnf::Lexer{};
    ebnf::parser parser{tokenizer};
    parser.parse("");

    EXPECT_FALSE(parser.consume(ebnf::token_kind::Identifier));
    EXPECT_TRUE(parser.consume(ebnf::token_kind::End));
    EXPECT_TRUE(parser.consume(ebnf::token_kind::End));
    EXPECT_TRUE(parser_testing::nextTokenIs(parser, ebnf::token_kind::End));
  }

  struct InvalidTokenizer {
    std::size_t count;

    auto tokenizeSourceIntoBuffer(tbc::view<std::string_view, tbc::lt::a>, tbc::view<ebnf::parsing_ring_buffer &, tbc::lt::a> buffer, std::size_t) const -> std::size_t {
      buffer[0] = ebnf::token{
          .kind = ebnf::token_kind::Identifier,
          .text = {},
      };

      return count;
    }
  };

  TEST(Grammar, RejectsInvalidTokenizerCountsAndMissingEnd) {
    for (const auto count : {std::size_t{0}, std::size_t{1}, ebnf::max_tokens_in_ring_buffer + 1}) {
      SCOPED_TRACE(count);
      auto tokenizer = InvalidTokenizer{.count = count};
      ebnf::parser parser{tokenizer};

      EXPECT_THROW(parser.parse(""), std::logic_error);
      EXPECT_EQ(parser.peek().kind, ebnf::token_kind::End);
    }
  }
}
