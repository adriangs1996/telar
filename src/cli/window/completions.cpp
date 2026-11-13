module;
#include <cstdio>

module telar.cli.window;

import std;
import telar.ebnf.matcher;

namespace telar::runtime::cli {

namespace {

// As the runtime reads the user's specs: at most this much, named after the command.
constexpr std::uintmax_t maximum_spec = 256 * 1024;

bool commandName(std::string_view name) noexcept {
  return !name.empty() && name.size() <= 64 && name.front() != '.' && std::ranges::all_of(name, [](char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '+' || byte == '-'; });
}

int fail(const std::filesystem::path &path, std::string_view reason) {
  std::fprintf(stderr, "telar completions: %s: %.*s\n", path.c_str(), static_cast<int>(reason.size()), reason.data());
  return 1;
}

}

// telar completions check FILE: compiles a command's completion spec with the matcher the
// runtime uses, so a spec that would be skipped says why before anyone relies on it.
int runCompletionsCommand(std::span<char *const> words) {
  if (words.empty()) {
    throw std::invalid_argument{"MissingCompletionsAction"};
  }
  if (std::string_view{words.front()} != "check") {
    throw std::invalid_argument{"UnknownCompletionsAction"};
  }
  if (words.size() != 2) {
    throw std::invalid_argument{"telar completions check takes one FILE"};
  }

  const std::filesystem::path path{words[1]};
  if (path.extension() != ".ebnf" || !commandName(path.stem().string())) {
    return fail(path, "name the file after its command, as nmap.ebnf");
  }
  std::error_code error;
  const auto size = std::filesystem::file_size(path, error);
  if (error) {
    return fail(path, error.message());
  }
  if (size > maximum_spec) {
    return fail(path, "larger than 256 KiB");
  }
  std::ifstream file{path, std::ios::binary};
  const std::string source{std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
  if (!file && !file.eof()) {
    return fail(path, "could not be read");
  }
  try {
    static_cast<void>(ebnf::command_spec::compile(source));
  } catch (const std::exception &exception) {
    return fail(path, exception.what());
  }
  std::puts("telar completions: OK");
  return 0;
}

}
