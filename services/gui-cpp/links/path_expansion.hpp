#pragma once

#include "link_text.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <typename Environment>
concept PathEnvironment = requires(const Environment &environment, const char *name) {
  { environment(name) } -> std::same_as<std::optional<std::string_view>>;
};

struct PathExpansionInput {
  std::string_view text;
  std::string_view base;
};

class PathExpansion {
public:
  static constexpr std::size_t maximum_bytes = LinkText::maximum_uri_bytes;
  using PathText = runtime::FixedText<maximum_bytes>;

  template <PathEnvironment Environment>
  [[nodiscard]] static PathText expand(PathExpansionInput input, const Environment &environment) {
    try {
      const auto expanded = substitute(input.text, environment);
      BoundedText<maximum_bytes> anchored;
      if (!expanded.view().starts_with('/')) {
        if (!input.base.starts_with('/')) {
          throw std::invalid_argument{"BaseUnavailable"};
        }

        anchored.append(input.base);
        if (!expanded.view().empty()) {
          anchored.append("/");
        }
      }

      anchored.append(expanded.view());

      return collapse(anchored.view());
    } catch (const std::length_error &) {
      throw std::length_error{"PathTooLong"};
    }
  }

private:
  [[nodiscard]] static bool nameByte(char byte) noexcept {
    return LinkText::alphanumeric(byte) || byte == '_';
  }

  template <PathEnvironment Environment>
  [[nodiscard]] static BoundedText<maximum_bytes> substitute(std::string_view text, const Environment &environment) {
    const auto first = text.find_first_not_of(' ');
    text = first == std::string_view::npos ? std::string_view{} : text.substr(first, text.find_last_not_of(' ') - first + 1);
    BoundedText<maximum_bytes> expanded;
    if (text == "~" || text.starts_with("~/")) {
      const auto home = environment("HOME");
      if (!home) {
        throw std::invalid_argument{"HomeUnavailable"};
      }

      expanded.append(*home);
      text.remove_prefix(1);
    }

    while (!text.empty()) {
      const auto dollar = text.find('$');
      if (dollar != 0) {
        expanded.append(text.substr(0, dollar));
        text.remove_prefix(std::min(dollar, text.size()));
        continue;
      }

      const auto braced = text.starts_with("${");
      const auto name_start = braced ? 2U : 1U;
      const auto name_end = name_start + static_cast<std::size_t>(std::ranges::find_if_not(text.substr(name_start), nameByte) - text.substr(name_start).begin());
      if (name_end == name_start) {
        expanded.append("$");
        text.remove_prefix(1);
        continue;
      }

      if (braced && (name_end == text.size() || text[name_end] != '}')) {
        throw std::invalid_argument{"UnterminatedVariable"};
      }

      std::array<char, maximum_bytes + 1> name{};
      const auto variable = text.substr(name_start, name_end - name_start);
      if (variable.size() > maximum_bytes) {
        throw std::length_error{"PathTooLong"};
      }

      std::ranges::copy(variable, name.begin());
      const auto value = environment(name.data());
      if (!value) {
        throw std::invalid_argument{"UnknownVariable"};
      }

      expanded.append(*value);
      text.remove_prefix(name_end + static_cast<std::size_t>(braced));
    }

    return expanded;
  }

  [[nodiscard]] static PathText collapse(std::string_view path) {
    BoundedText<maximum_bytes> result;
    while (!path.empty()) {
      const auto separator = path.find('/');
      const auto segment = path.substr(0, separator);
      path.remove_prefix(std::min(separator, path.size()));
      if (!path.empty()) {
        path.remove_prefix(1);
      }

      if (segment.empty() || segment == ".") {
        continue;
      }

      if (segment == "..") {
        const auto previous = result.view().rfind('/');
        result.truncate(previous == std::string_view::npos ? 0 : previous);
      } else {
        result.append("/");
        result.append(segment);
      }
    }

    PathText normalized;
    normalized.assign(result.view().empty() ? "/" : result.view());

    return normalized;
  }
};

}
