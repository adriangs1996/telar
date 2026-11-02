#pragma once

#include "input/paste_encoding.hpp"
#include "limits.hpp"
#include "page.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class PathInsertion {
public:
  static constexpr std::string_view paste_begin = PasteEncoding::begin;
  static constexpr std::string_view paste_end = PasteEncoding::end;
  static constexpr std::size_t paste_capacity = PathPickerLimits::quoted_bytes + PasteEncoding::framing_bytes;
  using Text = BoundedText<paste_capacity>;
  using Quoted = BoundedText<PathPickerLimits::quoted_bytes>;
  using AbsolutePath = BoundedText<PathPickerLimits::absolute_bytes>;

  struct Choice {
    std::size_t selection = 0;
    bool absolute = false;
    bool bracketed = false;
  };

  struct JoinParts {
    std::string_view root;
    std::string_view relative;
  };

  [[nodiscard]] static AbsolutePath join(JoinParts parts) {
    AbsolutePath path;
    path.append(parts.root);
    if (parts.root.size() != 1) {
      path.append("/");
    }

    path.append(parts.relative);

    return path;
  }

  [[nodiscard]] static std::optional<std::string_view> relativeTo(std::string_view anchor, std::string_view path) noexcept {
    if (anchor.size() == 1) {
      if (path.size() <= 1) {
        return std::nullopt;
      }

      path.remove_prefix(1);

      return path;
    }

    if (path.size() <= anchor.size() + 1 || !path.starts_with(anchor) || path[anchor.size()] != '/') {
      return std::nullopt;
    }

    path.remove_prefix(anchor.size() + 1);

    return path;
  }

  [[nodiscard]] static std::optional<Quoted> quote(std::string_view word) {
    Quoted output;
    if (word.empty()) {
      return output;
    }

    try {
      if (word.front() == '-') {
        output.append("./");
      }

      if (plain(word)) {
        output.append(word);

        return output;
      }

      output.append("'");
      for (const auto byte : word) {
        if (byte == '\'') {
          output.append("'\\''");
        } else {
          output.append(std::string_view{&byte, 1});
        }
      }

      output.append("'");
    } catch (const std::length_error &) {
      return std::nullopt;
    }

    return output;
  }

  [[nodiscard]] static std::optional<Text> prepare(const PathPickerPage &page, Choice choice) {
    if (page.matches().empty()) {
      return std::nullopt;
    }

    const auto &match = page.matches()[std::min(choice.selection, page.matches().size() - 1)];
    const auto full = join({.root = page.root(), .relative = page.path(match)});
    auto word = full.view();
    if (!choice.absolute) {
      if (const auto relative = relativeTo(page.anchor(), word)) {
        word = *relative;
      }
    }

    const auto quoted = quote(word);
    if (!quoted) {
      return std::nullopt;
    }

    return PasteEncoding::encode<PathPickerLimits::quoted_bytes>(quoted->view(), choice.bracketed);
  }

private:
  [[nodiscard]] static bool plain(std::string_view word) noexcept {
    return std::ranges::all_of(word, [](char byte) {
      constexpr std::string_view literal_punctuation = "_-./+@%,:";
      const auto letter = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
      const auto digit = byte >= '0' && byte <= '9';

      return letter || digit || literal_punctuation.contains(byte);
    });
  }
};

}
