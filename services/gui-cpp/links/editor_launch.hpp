#pragma once

#include "editors/kind.hpp"
#include "link_text.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui {

class EditorLaunch {
public:
  static constexpr std::size_t maximum_arguments = 3;
  static constexpr std::size_t position_bytes = 64;

  EditorLaunch() = default;
  ~EditorLaunch() = default;
  EditorLaunch(const EditorLaunch &) = delete;
  EditorLaunch &operator=(const EditorLaunch &) = delete;
  EditorLaunch(EditorLaunch &&) = delete;
  EditorLaunch &operator=(EditorLaunch &&) = delete;

  [[nodiscard]] std::span<const std::string_view> arguments(std::string_view executable, std::string_view path, std::uint32_t line, std::uint32_t column) {
    const auto convention = conventionOf(executable);
    arguments_[0] = executable;
    if (line == 0 || convention == Convention::none) {
      arguments_[1] = path;

      return std::span{arguments_}.first(2);
    }

    position_.truncate(0);
    writePosition({.path = path, .line = line, .column = column}, convention);
    if (convention == Convention::path_suffix) {
      arguments_[1] = position_.view();

      return std::span{arguments_}.first(2);
    }

    arguments_[1] = convention == Convention::goto_flag ? "-g" : position_.view();
    arguments_[2] = convention == Convention::goto_flag ? position_.view() : path;

    return arguments_;
  }

private:
  enum class Convention : std::uint8_t {
    vim,
    plus_line_column,
    nano,
    path_suffix,
    goto_flag,
    none,
  };

  struct Position {
    std::string_view path;
    std::uint32_t line;
    std::uint32_t column;
  };

  [[nodiscard]] static std::string_view columnSeparator(Convention convention) noexcept {
    switch (convention) {
    case Convention::vim:
      return ", ";
    case Convention::nano:
      return ",";
    default:
      return ":";
    }
  }

  [[nodiscard]] static Convention conventionOf(std::string_view executable) {
    while (executable.ends_with('/')) {
      executable.remove_suffix(1);
    }

    switch (runtime::identifyEditor(executable)) {
    case runtime::EditorKind::neovim:
    case runtime::EditorKind::vim:
      return Convention::vim;
    case runtime::EditorKind::emacs:
      return Convention::plus_line_column;
    default:
      break;
    }

    const auto separator = executable.rfind('/');
    const auto name = executable.substr(separator == std::string_view::npos ? 0 : separator + 1);
    if (name == "kak" || name == "micro") {
      return Convention::plus_line_column;
    }

    if (name == "nano") {
      return Convention::nano;
    }

    if (name == "hx" || name == "helix") {
      return Convention::path_suffix;
    }

    if (name == "code" || name == "code-insiders" || name == "codium" || name == "cursor") {
      return Convention::goto_flag;
    }

    return Convention::none;
  }

  void writePosition(Position position, Convention convention) {
    if (convention == Convention::path_suffix || convention == Convention::goto_flag) {
      position_.append(position.path);
      position_.append(":");
    } else {
      position_.append(convention == Convention::vim && position.column != 0 ? "+call cursor(" : "+");
    }

    position_.appendDecimal(position.line);
    if (position.column != 0) {
      position_.append(columnSeparator(convention));
      position_.appendDecimal(position.column);
      if (convention == Convention::vim) {
        position_.append(")");
      }
    }
  }

  BoundedText<LinkText::maximum_uri_bytes + position_bytes> position_;
  std::array<std::string_view, maximum_arguments> arguments_;
};

}
