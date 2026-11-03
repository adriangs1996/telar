#pragma once

#include "framing.hpp"
#include "number.hpp"
#include "telar_base/text/fields.hpp"
#include <cstdint>

namespace telar::runtime {

struct Http1Head {
  static constexpr std::size_t capacity = 64 * 1024;

  Http1Framing framing;
  std::uint16_t status = 0;
  bool head_request = false;
  bool informational = false;
  bool upgrade = false;
  bool closes = false;

  static std::optional<Http1Head> analyze(std::string_view bytes, bool response, bool response_to_head = false) noexcept {
    const auto boundary = bytes.find("\r\n");
    if (boundary == std::string_view::npos) {
      return std::nullopt;
    }

    const auto start_line = bytes.substr(0, boundary);
    const auto status = response ? parseStatus(start_line) : std::optional<std::uint16_t>{0};
    if (!status) {
      return std::nullopt;
    }
    const bool bodyless = response && (response_to_head || (*status >= 100 && *status < 200) || *status == 204 || *status == 205 || *status == 304);
    const auto framing = bodyFraming(bytes, response, bodyless);
    if (!framing) {
      return std::nullopt;
    }

    const auto method_end = start_line.find(' ');
    return Http1Head{
        .framing = *framing,
        .status = *status,
        .head_request = !response && method_end != std::string_view::npos && start_line.substr(0, method_end) == "HEAD",
        .informational = response && *status >= 100 && *status < 200 && *status != 101,
        .upgrade = response && *status == 101,
        .closes = framing->kind == Http1Framing::Kind::until_close || connectionCloses(bytes),
    };
  }

private:
  static std::optional<Http1Framing> bodyFraming(std::string_view bytes, bool response, bool bodyless) noexcept {
    using Kind = Http1Framing::Kind;
    if (bodyless) {
      return Http1Framing{};
    }

    std::optional<std::size_t> content_length;
    std::optional<std::string_view> transfer_encoding;
    TextFields lines{bytes, "\r\n"};
    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon == std::string_view::npos) {
        continue;
      }
      const auto name = trimText(line->substr(0, colon), " \t");
      const auto value = trimText(line->substr(colon + 1), " \t");
      if (equals(name, "transfer-encoding")) {
        if (transfer_encoding || value.empty()) {
          return std::nullopt;
        }
        transfer_encoding = value;
      }
      if (equals(name, "content-length")) {
        TextFields lengths{value, ","};
        while (const auto part = lengths.next()) {
          const auto length = parseHttpNumber<10>(trimText(*part, " \t"));
          if (!length || (content_length && *content_length != *length)) {
            return std::nullopt;
          }
          content_length = length;
        }
      }
    }

    if (transfer_encoding) {
      if (content_length) {
        return std::nullopt;
      }
      if (endsWithChunked(*transfer_encoding)) {
        return Http1Framing{Kind::chunked};
      }
      return response ? std::optional{Http1Framing{Kind::until_close}} : std::nullopt;
    }
    if (content_length) {
      return Http1Framing{Kind::content_length, *content_length};
    }
    return Http1Framing{response ? Kind::until_close : Kind::none};
  }

  static bool connectionCloses(std::string_view bytes) noexcept {
    TextFields lines{bytes, "\r\n"};
    lines.next();
    while (const auto line = lines.next()) {
      const auto colon = line->find(':');
      if (colon == std::string_view::npos || !equals(trimText(line->substr(0, colon), " \t"), "connection")) {
        continue;
      }
      TextFields tokens{line->substr(colon + 1), ","};
      while (const auto token = tokens.next()) {
        if (equals(trimText(*token, " \t"), "close")) {
          return true;
        }
      }
    }
    return false;
  }

  static bool endsWithChunked(std::string_view value) noexcept {
    TextFields tokens{value, ","};
    std::string_view last;
    while (const auto token = tokens.next()) {
      last = trimText(*token, " \t");
      if (last.empty()) {
        return false;
      }
    }
    return equals(last, "chunked");
  }

  static std::optional<std::uint16_t> parseStatus(std::string_view line) noexcept {
    TextFields parts{line, " "};
    parts.next();
    const auto text = parts.next();
    if (!text || text->size() != 3) {
      return std::nullopt;
    }
    const auto status = parseHttpNumber<10>(*text);
    return status && *status >= 100 && *status <= 599 ? std::optional{static_cast<std::uint16_t>(*status)} : std::nullopt;
  }

  static bool equals(std::string_view actual, std::string_view lower) noexcept {
    if (actual.size() != lower.size()) {
      return false;
    }
    for (std::size_t index = 0; index < actual.size(); ++index) {
      if (asciiLower(actual[index]) != lower[index]) {
        return false;
      }
    }
    return true;
  }
};

}
