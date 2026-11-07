module;
#include <cstdio>
#include <cstdlib>
#include <new>
#include <cmath>

#include <cstddef>
#include <cstdint>

#include <cstring>



export module telar.gui.links.path_expansion;

import std;

export import telar.base.editors;
export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: links/link_text.cppm
export {
namespace telar::gui {

enum class LinkScheme : std::uint8_t {
  file,
  http,
  https,
  external,
  path,
};

struct TextRange {
  std::size_t start = 0;
  std::size_t end = 0;

  [[nodiscard]] inline std::string_view view(std::string_view text) const {
    return text.substr(start, end - start);
  }

  bool operator==(const TextRange &) const = default;
};

struct LinkTextMatch {
  LinkScheme scheme = LinkScheme::external;
  TextRange extent;
  TextRange destination;
};

struct LinkText {
  static constexpr std::size_t maximum_uri_bytes = 4096;
  static constexpr std::size_t maximum_label_bytes = 512;
  static constexpr std::size_t markdown_delimiter_bytes = 4;
  static constexpr std::size_t maximum_span_bytes = maximum_uri_bytes + maximum_label_bytes + markdown_delimiter_bytes;
  static constexpr unsigned first_non_ascii = 0x80;
  static constexpr unsigned delete_control = 0x7f;

  [[nodiscard]] static constexpr bool control(char byte) noexcept {
    return static_cast<unsigned char>(byte) < ' ' || static_cast<unsigned char>(byte) == delete_control;
  }

  [[nodiscard]] static constexpr bool digit(char byte) noexcept {
    return byte >= '0' && byte <= '9';
  }

  [[nodiscard]] static constexpr bool alphanumeric(char byte) noexcept {
    return digit(byte) || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }

  [[nodiscard]] static constexpr bool separator(char byte) noexcept {
    return control(byte) || byte == ' ' || std::string_view{"\"'<>`"}.contains(byte);
  }

  [[nodiscard]] inline static bool validUtf8(std::string_view text) noexcept {
    try {
      validateUtf8(text);

      return true;
    } catch (const EncodingError &) {
      return false;
    }
  }
};

}
}

// Interface: links/editor_launch.cppm
export {
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

  [[nodiscard]] inline std::span<const std::string_view> arguments(std::string_view executable, std::string_view path, std::uint32_t line, std::uint32_t column) {
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

  [[nodiscard]] inline static std::string_view columnSeparator(Convention convention) noexcept {
    switch (convention) {
    case Convention::vim:
      return ", ";
    case Convention::nano:
      return ",";
    default:
      return ":";
    }
  }

  [[nodiscard]] inline static Convention conventionOf(std::string_view executable) {
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

  inline void writePosition(Position position, Convention convention) {
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
}

// Interface: links/editor_opening.cppm
export {
namespace telar::gui {

struct EditorSource {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  std::uint64_t attachment_generation = 0;
  TabLocation location{};
};

class EditorTarget {
public:
  inline EditorTarget(std::string_view editor, std::string_view path, std::uint32_t line, std::uint32_t column)
      : line_(line),
        column_(column) {
    DisplayText16<LinkText::maximum_uri_bytes, false>::validate(editor);
    DisplayText16<LinkText::maximum_uri_bytes, false>::validate(path);
    if (editor.starts_with('-') || !path.starts_with('/') || (column != 0 && line == 0)) {
      throw std::invalid_argument{"InvalidEditorTarget"};
    }

    editor_.assign(editor);
    path_.assign(path);
  }

  [[nodiscard]] inline std::string_view editor() const noexcept {
    return editor_.view();
  }

  [[nodiscard]] inline std::string_view path() const noexcept {
    return path_.view();
  }

  [[nodiscard]] inline std::uint32_t line() const noexcept {
    return line_;
  }

  [[nodiscard]] inline std::uint32_t column() const noexcept {
    return column_;
  }

private:
  runtime::FixedText<LinkText::maximum_uri_bytes> editor_;
  runtime::FixedText<LinkText::maximum_uri_bytes> path_;
  std::uint32_t line_;
  std::uint32_t column_;
};

struct EditorRequest {
  std::uint64_t request_id;
  EditorSource source;
  EditorTarget target;

  [[nodiscard]] inline OpenEditor message() const noexcept {
    return {.request_id = request_id, .pane_id = source.pane_id, .pane_generation = source.pane_generation, .editor = target.editor(), .path = target.path(), .line = target.line(), .column = target.column()};
  }
};

class EditorOpening {
public:
  inline void begin(const EditorRequest &request) {
    if (pending_) {
      throw std::runtime_error{"EditorOpenBusy"};
    }

    pending_ = request;
  }

  [[nodiscard]] inline std::optional<EditorRequest> complete(std::uint64_t request_id) {
    if (!owns(request_id)) {
      return {};
    }

    return std::exchange(pending_, std::nullopt);
  }

  [[nodiscard]] inline bool owns(std::uint64_t request_id) const noexcept {
    return pending_ && pending_->request_id == request_id;
  }

  inline void reset() noexcept {
    pending_.reset();
  }

private:
  std::optional<EditorRequest> pending_;
};

}
}

// Interface: links/link_grid.cppm
export {
namespace telar::gui {

struct LinkGrid {
  std::span<const CellValue> cells;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  Scroll scroll{};
  std::span<const Byte> row_flags;

  [[nodiscard]] inline std::optional<std::size_t> cellIndex(CellPosition point) const noexcept {
    if (columns == 0 || cells.size() != static_cast<std::size_t>(columns) * rows || point.x >= columns || point.y < scroll.offset || point.y - scroll.offset >= rows) {
      return {};
    }

    auto index = (static_cast<std::size_t>(point.y - scroll.offset) * columns) + point.x;
    if (padding(index)) {
      return {};
    }

    if (cells[index].width == CellWidth::continuation) {
      if (point.x == 0 || cells[index - 1].width != CellWidth::wide) {
        return {};
      }

      --index;
    }

    return index;
  }

  [[nodiscard]] inline std::optional<std::size_t> previous(std::size_t index) const noexcept {
    while (index != 0) {
      if (index % columns == 0 && !joins((index / columns) - 1)) {
        return {};
      }

      --index;
      if (!padding(index)) {
        return index;
      }
    }

    return {};
  }

  [[nodiscard]] inline std::optional<std::size_t> next(std::size_t index) const noexcept {
    while (index + 1 < cells.size()) {
      if ((index + 1) % columns == 0 && !joins(index / columns)) {
        return {};
      }

      ++index;
      if (!padding(index)) {
        return index;
      }
    }

    return {};
  }

  [[nodiscard]] inline CellPosition position(std::size_t index) const noexcept {
    return {.x = static_cast<std::uint16_t>(index % columns), .y = scroll.offset + static_cast<std::uint32_t>(index / columns)};
  }

  [[nodiscard]] inline CellPosition cellEnd(std::size_t index) const noexcept {
    auto result = position(index);
    result.x = static_cast<std::uint16_t>(std::min<unsigned>(columns, result.x + std::max(1U, static_cast<unsigned>(cells[index].width))));

    return result;
  }

  [[nodiscard]] inline bool complete(CellPosition first, CellPosition last) const noexcept {
    if (row_flags.empty()) {
      return true;
    }

    if (first.y == scroll.offset && first.x == 0 && flag(0, RowFlag::continuation)) {
      return false;
    }

    const auto last_row = row_flags.size() - 1;
    const auto last_column = columns - static_cast<unsigned>(flag(last_row, RowFlag::wide_padding));

    return last.y - scroll.offset != last_row || last.x != last_column || !flag(last_row, RowFlag::wrap);
  }

private:
  [[nodiscard]] inline bool flag(std::size_t row, RowFlag value) const noexcept {
    return row < row_flags.size() && (row_flags[row] & static_cast<Byte>(value)) != 0;
  }

  [[nodiscard]] inline bool padding(std::size_t index) const noexcept {
    return flag(index / columns, RowFlag::wide_padding) && index % columns == columns - 1;
  }

  [[nodiscard]] inline bool joins(std::size_t row) const noexcept {
    return row + 1 < row_flags.size() && flag(row, RowFlag::wrap) && flag(row + 1, RowFlag::continuation);
  }
};

}
}

// Interface: links/path_expansion.cppm
export {
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
  [[nodiscard]] inline static PathText expand(PathExpansionInput input, const Environment &environment) {
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
  [[nodiscard]] inline static bool nameByte(char byte) noexcept {
    return LinkText::alphanumeric(byte) || byte == '_';
  }

  template <PathEnvironment Environment>
  [[nodiscard]] inline static BoundedText<maximum_bytes> substitute(std::string_view text, const Environment &environment) {
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

  [[nodiscard]] inline static PathText collapse(std::string_view path) {
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
}

// Interface: links/pointer_policy.cppm
export {
namespace telar::gui {

struct LinkModifiers {
  bool native = false;
  bool shift = false;
  bool alt = false;

  bool operator==(const LinkModifiers &) const = default;
};

enum class LinkAffordance : std::uint8_t {
  text,
  pointer,
  link,
};

enum class LinkButton : std::uint8_t {
  left,
  middle,
  right,
};

enum class LinkPress : std::uint8_t {
  passthrough,
  arm_shared,
  arm_exclusive,
  copy,
  discard,
};

struct LinkPressInput {
  LinkButton button = LinkButton::left;
  LinkModifiers modifiers{};
  bool child_tracking = false;
  bool has_link = false;
  bool openable = false;
  bool frame_presented = false;
};

class LinkPointerPolicy {
public:
  [[nodiscard]] static constexpr LinkAffordance hover(std::optional<LinkScheme> scheme, LinkModifiers modifiers, bool eligible = true) noexcept {
    if (!eligible || !scheme) {
      return LinkAffordance::text;
    }

    if (modifiers.alt) {
      return LinkAffordance::pointer;
    }

    return *scheme == LinkScheme::path && !modifiers.native ? LinkAffordance::text : LinkAffordance::link;
  }

  [[nodiscard]] static constexpr LinkPress press(LinkPressInput input) noexcept {
    if (!input.has_link || input.button == LinkButton::middle) {
      return LinkPress::passthrough;
    }

    if (input.button == LinkButton::right) {
      return input.frame_presented ? LinkPress::copy : LinkPress::discard;
    }

    if (input.child_tracking && !input.modifiers.shift) {
      return LinkPress::passthrough;
    }

    if (input.modifiers.native) {
      return input.openable ? LinkPress::arm_exclusive : LinkPress::discard;
    }

    return input.openable ? LinkPress::arm_shared : LinkPress::passthrough;
  }
};

}
}
