#include "lexer.hpp"

#include <gtest/gtest.h>

#include <array>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {
  TEST(Lexer, GroupsIdentifiersAndUnquotedLiteralContents) {
    const auto source = std::string_view{"rule_12 = \"abc def\";"};
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size());

    ASSERT_EQ(count, 5u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::Identifier);
    EXPECT_EQ(buffer[0].text, "rule_12");
    EXPECT_EQ(buffer[0].text.data(), source.data());
    EXPECT_EQ(buffer[1].kind, ebnf::token_kind::Equal);
    EXPECT_EQ(buffer[2].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[2].text, "abc def");
    EXPECT_EQ(buffer[2].text.data(), source.data() + source.find("abc def"));
    EXPECT_EQ(buffer[3].kind, ebnf::token_kind::Semicolon);
    EXPECT_EQ(buffer[4].kind, ebnf::token_kind::End);
    EXPECT_TRUE(buffer[4].text.empty());
  }

  TEST(Lexer, SupportsBothQuotesAndPreservesTheOtherQuote) {
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(R"('say "hi"' "it's")", buffer, buffer.size());

    ASSERT_EQ(count, 3u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[0].text, "say \"hi\"");
    EXPECT_EQ(buffer[1].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[1].text, "it's");
    EXPECT_EQ(buffer[2].kind, ebnf::token_kind::End);
  }

  TEST(Lexer, ValidatesEveryEscapeAndPreservesItsSourceSpelling) {
    constexpr auto escapes = std::to_array<std::string_view>({R"(\n)", R"(\t)", R"(\r)", R"(\f)", R"(\b)", R"(\\)", R"(\')", R"(\")"});
    ebnf::parsing_ring_buffer buffer;

    for (const auto quote : {'\'', '"'}) {
      for (const auto escape : escapes) {
        const auto source = std::string(1, quote) + std::string(escape) + quote;
        SCOPED_TRACE(source);
        const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size());

        ASSERT_EQ(count, 2u);
        EXPECT_EQ(buffer[0].kind, ebnf::token_kind::String);
        EXPECT_EQ(buffer[0].text, escape);
        EXPECT_EQ(buffer[0].text.data(), source.data() + 1);
        EXPECT_EQ(buffer[1].kind, ebnf::token_kind::End);
      }
    }
  }

  TEST(Lexer, EscapedQuotesDoNotTerminateTheLiteral) {
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(R"ebnf("say \"hi\" and \\"; 'it\'s';)ebnf", buffer, buffer.size());

    ASSERT_EQ(count, 5u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[0].text, R"(say \"hi\" and \\)");
    EXPECT_EQ(buffer[1].kind, ebnf::token_kind::Semicolon);
    EXPECT_EQ(buffer[2].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[2].text, R"(it\'s)");
    EXPECT_EQ(buffer[3].kind, ebnf::token_kind::Semicolon);
    EXPECT_EQ(buffer[4].kind, ebnf::token_kind::End);
  }

  TEST(Lexer, RejectsUnknownOrIncompleteEscapes) {
    ebnf::parsing_ring_buffer buffer;

    for (const auto source : {R"("\q")", R"('\x41')", R"("\u0041")", R"("\0")", R"("\v")", R"("abc\)", R"('abc\)", R"("abc\")", R"('abc\')", "\"\\\n\""}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size()), std::invalid_argument);
    }

    const auto embedded_null = std::string_view{"\"\\\0\"", 4};
    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(embedded_null, buffer, buffer.size()), std::invalid_argument);
  }

  TEST(Lexer, EscapeValidationHonorsStringViewBounds) {
    constexpr auto storage = std::string_view{R"("\n")"};
    ebnf::parsing_ring_buffer buffer;

    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(storage.substr(0, 2), buffer, buffer.size()), std::invalid_argument);
    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(storage.substr(0, 3), buffer, buffer.size()), std::invalid_argument);
    ASSERT_EQ(ebnf::Lexer{}.tokenizeSourceIntoBuffer(storage, buffer, buffer.size()), 2u);
    EXPECT_EQ(buffer[0].text, R"(\n)");
  }

  TEST(Lexer, SkipsWhitespaceOutsideLiteralsButPreservesItInside) {
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(" \n\t\r\f\b\"a \n\t\r\f\bb\" \n\t\r\f\b", buffer, buffer.size());

    ASSERT_EQ(count, 2u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[0].text, "a \n\t\r\f\bb");
    EXPECT_EQ(buffer[1].kind, ebnf::token_kind::End);
  }

  TEST(Lexer, RecognizesEveryPunctuationToken) {
    const auto source = std::string_view{"=;|,()[]{}?+*-."};
    const auto kinds = std::array{
        ebnf::token_kind::Equal,
        ebnf::token_kind::Semicolon,
        ebnf::token_kind::Pipe,
        ebnf::token_kind::Comma,
        ebnf::token_kind::LParen,
        ebnf::token_kind::RParen,
        ebnf::token_kind::LBracket,
        ebnf::token_kind::RBracket,
        ebnf::token_kind::LBrace,
        ebnf::token_kind::RBrace,
        ebnf::token_kind::Question,
        ebnf::token_kind::Plus,
        ebnf::token_kind::Aster,
        ebnf::token_kind::Minus,
        ebnf::token_kind::Dot,
    };
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size());

    ASSERT_EQ(count, kinds.size() + 1);

    for (std::size_t index = 0; index < kinds.size(); ++index) {
      SCOPED_TRACE(index);
      EXPECT_EQ(buffer[index].kind, kinds[index]);
      EXPECT_EQ(buffer[index].text, source.substr(index, 1));
    }

    EXPECT_EQ(buffer[kinds.size()].kind, ebnf::token_kind::End);
  }

  TEST(Lexer, GroupsDigitsIntoNumberTokens) {
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer("12345", buffer, buffer.size());

    ASSERT_EQ(count, 2u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::Number);
    EXPECT_EQ(buffer[0].text, "12345");
  }

  TEST(Lexer, PreservesGrammarSymbolsInsideLiterals) {
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer("'AZaz09[]{}()<>\"=|.,;_-+*?'", buffer, buffer.size());

    ASSERT_EQ(count, 2u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[0].text, "AZaz09[]{}()<>\"=|.,;_-+*?");
  }

  TEST(Lexer, RejectsUnterminatedEmptyOrInvalidLiterals) {
    ebnf::parsing_ring_buffer buffer;

    for (const auto source : {"'unfinished", "\"unfinished", "'", "\"", "''", "\"\"", "\"@\""}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size()), std::invalid_argument);
    }
  }

  TEST(Lexer, RejectsInvalidCharactersOutsideLiterals) {
    ebnf::parsing_ring_buffer buffer;

    for (const auto source : {"@", "_name", "\\", "<", ">"}) {
      SCOPED_TRACE(source);
      EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size()), std::invalid_argument);
    }
  }

  TEST(Lexer, RejectsEmbeddedNullCharactersInsteadOfTreatingThemAsEnd) {
    ebnf::parsing_ring_buffer buffer;
    const auto source = std::string_view{"\"a\0b\"", 5};

    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size()), std::invalid_argument);
    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(source.substr(2, 1), buffer, buffer.size()), std::invalid_argument);
  }

  TEST(Lexer, HonorsStringViewBoundsWithoutANullTerminator) {
    const auto storage = std::string{"name=\"value\";@"};
    const auto source = std::string_view{storage.data(), storage.size() - 1};
    ebnf::parsing_ring_buffer buffer;
    const auto count = ebnf::Lexer{}.tokenizeSourceIntoBuffer(source, buffer, buffer.size());

    ASSERT_EQ(count, 5u);
    EXPECT_EQ(buffer[2].text, "value");
    EXPECT_EQ(buffer[4].kind, ebnf::token_kind::End);
    EXPECT_EQ(buffer[4].text.data(), source.data() + source.size());
  }

  TEST(Lexer, EmptyInputStillRequiresRoomForEnd) {
    ebnf::parsing_ring_buffer buffer;

    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer("", buffer, 0), std::length_error);
    ASSERT_EQ(ebnf::Lexer{}.tokenizeSourceIntoBuffer("", buffer, 1), 1u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::End);
    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer("name", buffer, 1), std::length_error);
    ASSERT_EQ(ebnf::Lexer{}.tokenizeSourceIntoBuffer(" \n\t\r\f\b", buffer, 1), 1u);
    EXPECT_EQ(buffer[0].kind, ebnf::token_kind::End);
  }

  TEST(Lexer, ReservesCapacityForEndWithoutOverwritingTheLimit) {
    ebnf::parsing_ring_buffer buffer;
    buffer[3] = ebnf::token{
        .kind = ebnf::token_kind::String,
        .text = "untouched",
    };

    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer("a=b", buffer, 3), std::length_error);
    EXPECT_EQ(buffer[3].kind, ebnf::token_kind::String);
    EXPECT_EQ(buffer[3].text, "untouched");
    ASSERT_EQ(ebnf::Lexer{}.tokenizeSourceIntoBuffer("a=b", buffer, 4), 4u);
    EXPECT_EQ(buffer[3].kind, ebnf::token_kind::End);
  }

  TEST(Lexer, EnforcesThePhysicalBufferCapacity) {
    ebnf::parsing_ring_buffer buffer;
    const auto exact_source = std::string(buffer.size() - 1, '=');

    ASSERT_EQ(ebnf::Lexer{}.tokenizeSourceIntoBuffer(exact_source, buffer, buffer.size()), buffer.size());
    EXPECT_EQ(buffer.back().kind, ebnf::token_kind::End);

    const auto overflow_source = std::string(buffer.size(), '=');

    EXPECT_THROW(ebnf::Lexer{}.tokenizeSourceIntoBuffer(overflow_source, buffer, buffer.size() + 1), std::length_error);
  }
}
