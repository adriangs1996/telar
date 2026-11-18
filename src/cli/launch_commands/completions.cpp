module telar.cli.launch_commands;

import std;
import telar.sys.posix;
import telar.ebnf.matcher;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.cli.command_limit;

namespace telar::runtime::cli {

  namespace {

    // As the runtime reads the user's specs: at most this much, named after the command.
    constexpr std::uintmax_t maximum_spec = 256 * 1024;

    bool commandName(std::string_view name) noexcept {
      return !name.empty() && name.size() <= 64 && name.front() != '.' && std::ranges::all_of(name, [](char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '+' || byte == '-';
      });
    }

    int fail(std::string_view path, std::string_view reason) {
      std::fprintf(stderr, "telar completions: %.*s: %.*s\n", static_cast<int>(path.size()), path.data(), static_cast<int>(reason.size()), reason.data());
      return 1;
    }

  }

  // telar completions check FILE: compiles a command's completion spec with the matcher the
  // runtime uses, so a spec that would be skipped says why before anyone relies on it.
  int runCompletionsCommand(Memory& memory, std::span<char* const> words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingCompletionsAction"};
    }

    if (std::string_view{words.front()} != "check") {
      throw std::invalid_argument{"UnknownCompletionsAction"};
    }

    if (words.size() != 2) {
      throw std::invalid_argument{"telar completions check takes one FILE"};
    }

    // The path views the command line, so it ends with a NUL.
    const std::string_view path{words[1]};
    const auto name = path.substr(path.rfind('/') + 1);
    constexpr std::string_view extension = ".ebnf";
    if (!name.ends_with(extension) || !commandName(name.substr(0, name.size() - extension.size()))) {
      return fail(path, "name the file after its command, as nmap.ebnf");
    }

    FileDescriptor file{::open(words[1], O_RDONLY | O_CLOEXEC)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0) {
      return fail(path, std::strerror(sys::lastError()));
    }

    if (static_cast<std::uintmax_t>(state.st_size) > maximum_spec) {
      return fail(path, "larger than 256 KiB");
    }

    Text source{memory};

    source.resizeForOverwrite(static_cast<std::size_t>(state.st_size));
    std::size_t done = 0;

    while (done < source.size()) {
      const auto count = ::read(file.get(), source.dataMut() + done, source.size() - done);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count < 0) {
        return fail(path, "could not be read");
      }

      if (count == 0) {
        break;
      }

      done += static_cast<std::size_t>(count);
    }

    source.truncate(done);
    try {
      static_cast<void>(ebnf::command_spec::compile(source));
    } catch (const std::exception& exception) {
      return fail(path, exception.what());
    }

    std::puts("telar completions: OK");
    return 0;
  }

}
