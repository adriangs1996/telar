#pragma once

#include <tbc/view.hpp>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace ebnf {

  inline constexpr std::size_t max_tokens_in_ring_buffer = 10000;

  enum class token_kind : std::uint8_t {
    Identifier,
    Number,
    String,
    Equal,
    Semicolon,
    Pipe,
    Comma,
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    Question,
    Plus,
    Aster,
    Minus,
    Dot,
    End,
  };

  struct token {
    token_kind kind;
    std::string_view text;
  };

  using parsing_ring_buffer = std::array<token, max_tokens_in_ring_buffer>;

  template <typename T>
  using bounded = tbc::view<T, tbc::lt::a>;

  // Implementations must put source and buffer in one tbc region, like Lexer, so a call replaces the buffer's views.
  template <typename tokenizer>
  concept i_tokenizer = requires(tokenizer &tkzer, std::string_view source, parsing_ring_buffer &buffer, std::size_t max_tokens) {
    { tkzer.tokenizeSourceIntoBuffer(source, buffer, max_tokens) } -> std::same_as<std::size_t>;
  };

  class Lexer {
  public:
    // The returned count includes End; token text borrows the source storage.
    auto tokenizeSourceIntoBuffer(bounded<std::string_view> source, bounded<parsing_ring_buffer &> buffer, std::size_t max_tokens) const -> std::size_t {
      const auto limit = std::min(max_tokens, buffer.size());

      if (limit == 0) {
        throw std::length_error("Token buffer has no room for End");
      }

      std::size_t cursor = 0;
      std::size_t count = 0;

      while (cursor < source.size()) {
        if (isWhitespace(source[cursor])) {
          ++cursor;
          continue;
        }

        if (count == limit - 1) {
          throw std::length_error("Token buffer capacity exceeded");
        }

        buffer[count] = readToken(source, cursor);
        ++count;
      }

      buffer[count] = token{
          .kind = token_kind::End,
          .text = source.substr(source.size()),
      };

      return count + 1;
    }

  private:
    static constexpr auto isLetter(char character) -> bool {
      return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z');
    }

    static constexpr auto isDigit(char character) -> bool {
      return character >= '0' && character <= '9';
    }

    static constexpr auto isWhitespace(char character) -> bool {
      return std::string_view{" \n\t\r\f\b"}.find(character) != std::string_view::npos;
    }

    static constexpr auto isEscapeCharacter(char character) -> bool {
      return std::string_view{"ntrfb\\'\""}.find(character) != std::string_view::npos;
    }

    static constexpr auto isCharacter(char character) -> bool {
      return isLetter(character) || isDigit(character) || isWhitespace(character) || std::string_view{"[]{}()<>\"'=|.,;_-+*?"}.find(character) != std::string_view::npos;
    }

    static auto readToken(std::string_view source, std::size_t &cursor) -> token {
      const auto start = cursor;
      const auto character = source[cursor];

      if (isLetter(character)) {
        do {
          ++cursor;
        } while (cursor < source.size() && (isLetter(source[cursor]) || isDigit(source[cursor]) || source[cursor] == '_'));

        return token{
            .kind = token_kind::Identifier,
            .text = source.substr(start, cursor - start),
        };
      }

      if (isDigit(character)) {
        do {
          ++cursor;
        } while (cursor < source.size() && isDigit(source[cursor]));

        return token{
            .kind = token_kind::Number,
            .text = source.substr(start, cursor - start),
        };
      }

      if (character == '\'' || character == '"') {
        return readString(source, cursor);
      }

      const auto kind = punctuationKind(character);
      ++cursor;

      return token{
          .kind = kind,
          .text = source.substr(start, 1),
      };
    }

    static auto readString(std::string_view source, std::size_t &cursor) -> token {
      const auto quote = source[cursor];
      const auto start = ++cursor;

      while (cursor < source.size() && source[cursor] != quote) {
        if (source[cursor] == '\\') {
          ++cursor;

          if (cursor == source.size()) {
            throw std::invalid_argument("Unterminated escape sequence in string literal");
          }

          if (!isEscapeCharacter(source[cursor])) {
            throw std::invalid_argument("Invalid escape sequence in string literal");
          }
        } else if (!isCharacter(source[cursor])) {
          throw std::invalid_argument("Invalid character in string literal");
        }

        ++cursor;
      }

      if (cursor == source.size()) {
        throw std::invalid_argument("Unterminated string literal");
      }

      if (cursor == start) {
        throw std::invalid_argument("Expected at least one character in string literal");
      }

      const auto text = source.substr(start, cursor - start);
      ++cursor;

      return token{
          .kind = token_kind::String,
          .text = text,
      };
    }

    static auto punctuationKind(char character) -> token_kind {
      switch (character) {
      case '=':
        return token_kind::Equal;
      case ';':
        return token_kind::Semicolon;
      case '|':
        return token_kind::Pipe;
      case ',':
        return token_kind::Comma;
      case '(':
        return token_kind::LParen;
      case ')':
        return token_kind::RParen;
      case '[':
        return token_kind::LBracket;
      case ']':
        return token_kind::RBracket;
      case '{':
        return token_kind::LBrace;
      case '}':
        return token_kind::RBrace;
      case '?':
        return token_kind::Question;
      case '+':
        return token_kind::Plus;
      case '*':
        return token_kind::Aster;
      case '-':
        return token_kind::Minus;
      case '.':
        return token_kind::Dot;
      default:
        throw std::invalid_argument("Unexpected character outside string literal");
      }
    }
  };
}
