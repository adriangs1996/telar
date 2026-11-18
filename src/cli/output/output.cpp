module telar.cli.output;

import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime::cli {

  // Each family as it is typed, in the order of `Family`.
  constexpr std::array<std::string_view, static_cast<std::size_t>(Family::count)> family_names{
      "workspace",
      "tab",
      "pane",
      "worktree",
      "agent",
      "exec",
      "repository",
      "project",
      "file",
      "machine",
      "client",
      "sidebar",
      "workspace-list",
      "layout",
      "notification",
      "command",
      "config",
      "completions",
      "plugin",
      "integration",
      "hook",
      "cli",
      "gui",
      "server",
      "runtime",
      "diagnostics",
      "history",
      "proxy",
      "api",
      "clipboard",
      "render"
  };

  std::string_view familyName(Family family) noexcept {
    return family_names.at(static_cast<std::size_t>(family));
  }

  ds::Option<Family> parseFamily(std::string_view word) noexcept {
    for (std::size_t index = 0; index < family_names.size(); ++index) {
      if (family_names.at(index) == word) {
        return static_cast<Family>(index);
      }
    }

    return ds::none;
  }

  Failure::Failure(std::string_view message, int status, ds::Option<FailureCode> code)
      : std::runtime_error{std::string{message}},
        status_(status),
        code_(code) {}

  int Failure::status() const noexcept {
    return status_;
  }

  ds::Option<FailureCode> Failure::code() const noexcept {
    return code_;
  }

  Output::Output(Memory& memory)
      : data(AllocatorRef<char, Memory>{memory}) {}

  Output& Output::text(std::string_view value) {
    data.append(value);
    return *this;
  }

  Output& Output::boolean(bool value) {
    return text(value ? "true" : "false");
  }

  Output& Output::json(std::string_view value, JsonEscapes escapes) {
    appendJsonText(data, value, escapes);
    return *this;
  }

  void Output::flush() {
    std::fwrite(data.data(), 1, data.size(), stdout);
    std::fflush(stdout);
    data.clear();
  }

  template <typename Integer>
  Output& Output::number(Integer value) {
    std::array<char, 32> buffer;
    const auto end = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value).ptr;

    data.append(buffer.data(), end);
    return *this;
  }

  template Output& Output::number<int>(int value);
  template Output& Output::number<long>(long value);
  template Output& Output::number<long long>(long long value);
  template Output& Output::number<unsigned char>(unsigned char value);
  template Output& Output::number<unsigned short>(unsigned short value);
  template Output& Output::number<unsigned int>(unsigned int value);
  template Output& Output::number<unsigned long>(unsigned long value);
  template Output& Output::number<unsigned long long>(unsigned long long value);

}
