#pragma once

#include "core/unicode_scalar.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstring>
#include <string_view>

namespace telar::gui {

struct TabCaption {
  static constexpr std::size_t capacity = 128;
  static constexpr std::size_t directory_capacity = 48;
  static constexpr std::string_view separator = " · ";
  static constexpr std::string_view fallback_application = "shell";
  static constexpr std::string_view fullscreen_suffix = " ⛶";
  static constexpr std::string_view path_separators = "/\\";
  using Buffer = std::array<char, capacity>;

  struct Content {
    std::string_view manual;
    std::string_view application;
    std::string_view directory;
    std::string_view session_title;
  };

  [[nodiscard]] static std::string_view directoryName(std::string_view path) noexcept {
    if (path.empty()) {
      return {};
    }

    while (path.size() > 1 && path_separators.contains(path.back())) {
      path.remove_suffix(1);
    }

    if (path.size() != 1 || !path_separators.contains(path.front())) {
      const auto separator = path.find_last_of(path_separators);
      if (separator != std::string_view::npos && separator + 1 < path.size()) {
        path.remove_prefix(separator + 1);
      }
    }

    constexpr unsigned delete_control = 0x7f;
    if (inspectUtf8(path) != Utf8Validation::valid || std::ranges::any_of(path, [](char byte) { return static_cast<unsigned char>(byte) < ' ' || static_cast<unsigned char>(byte) == delete_control; })) {
      return {};
    }

    auto length = std::min(path.size(), directory_capacity);
    constexpr unsigned continuation_mask = static_cast<unsigned char>(~Utf8Scalar::continuation_mask);
    while (length != 0 && length < path.size() && (static_cast<unsigned char>(path[length]) & continuation_mask) == Utf8Scalar::continuation_prefix) {
      --length;
    }

    path.remove_suffix(path.size() - length);

    return path;
  }

  [[nodiscard]] static std::string_view resolve(Content content, Buffer &storage) noexcept {
    if (!content.manual.empty()) {
      return content.manual;
    }

    if (!content.session_title.empty()) {
      return content.session_title;
    }

    const auto application = content.application.empty() ? fallback_application : content.application;
    const auto directory = directoryName(content.directory);
    const auto length = directory.size() + separator.size() + application.size();
    if (directory.empty() || length > storage.size()) {
      return application;
    }

    std::memcpy(storage.data(), directory.data(), directory.size());
    std::memcpy(storage.data() + directory.size(), separator.data(), separator.size());
    std::memcpy(storage.data() + directory.size() + separator.size(), application.data(), application.size());

    return {storage.data(), length};
  }
};

}
