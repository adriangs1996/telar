module telar.gui.features.terminal.links;

import std;
import telar.tbc;
import telar.base.editors;
import telar.gui.foundation.text;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::links {

  PathExpansion::PathText PathExpansion::expandWith(PathExpansionInput input, const Variables& environment) {
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
    } catch (const std::length_error&) {
      throw std::length_error{"PathTooLong"};
    }
  }

  bool PathExpansion::nameByte(char byte) noexcept {
    return LinkText::alphanumeric(byte) || byte == '_';
  }

  BoundedText<PathExpansion::maximum_bytes> PathExpansion::substitute(std::string_view text, const Variables& environment) {
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

      ds::Array<char, maximum_bytes + 1> name{};
      const auto variable = text.substr(name_start, name_end - name_start);
      if (variable.size() > maximum_bytes) {
        throw std::length_error{"PathTooLong"};
      }

      std::ranges::copy(variable, name.viewMut().begin());
      const auto value = environment(name.data());
      if (!value) {
        throw std::invalid_argument{"UnknownVariable"};
      }

      expanded.append(*value);
      text.remove_prefix(name_end + static_cast<std::size_t>(braced));
    }

    return expanded;
  }

  PathExpansion::PathText PathExpansion::collapse(std::string_view path) {
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

  std::span<const std::string_view> EditorLaunch::arguments(std::string_view executable, std::string_view path, std::uint32_t line, std::uint32_t column) {
    const auto convention = conventionOf(executable);

    executable_.truncate(0);
    executable_.append(executable);
    path_.truncate(0);
    path_.append(path);
    arguments_.atMut(0) = executable_.view();
    if (line == 0 || convention == Convention::none) {
      arguments_.atMut(1) = path_.view();

      return std::span{arguments_}.first(2);
    }

    position_.truncate(0);
    writePosition({.path = path, .line = line, .column = column}, convention);
    if (convention == Convention::path_suffix) {
      arguments_.atMut(1) = position_.view();

      return std::span{arguments_}.first(2);
    }

    arguments_.atMut(1) = convention == Convention::goto_flag ? "-g" : position_.view();
    arguments_.atMut(2) = convention == Convention::goto_flag ? position_.view() : path_.view();

    return arguments_;
  }

  std::string_view EditorLaunch::columnSeparator(Convention convention) noexcept {
    switch (convention) {
    case Convention::vim:
      return ", ";
    case Convention::nano:
      return ",";
    default:
      return ":";
    }
  }

  EditorLaunch::Convention EditorLaunch::conventionOf(std::string_view executable) {
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

  void EditorLaunch::writePosition(Position position, Convention convention) {
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

  EditorTarget::EditorTarget(std::string_view editor, std::string_view path, std::uint32_t line, std::uint32_t column)
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

  std::string_view EditorTarget::editor() const noexcept {
    return editor_.view();
  }

  std::string_view EditorTarget::path() const noexcept {
    return path_.view();
  }

  std::uint32_t EditorTarget::line() const noexcept {
    return line_;
  }

  std::uint32_t EditorTarget::column() const noexcept {
    return column_;
  }

  OpenEditor EditorRequest::message() const noexcept {
    return {.request_id = request_id, .pane_id = source.pane_id, .pane_generation = source.pane_generation, .editor = target.editor(), .path = target.path(), .line = target.line(), .column = target.column()};
  }

}
