module telar.cli.launch_commands;

import std;
import telar.sys.posix;
import telar.ebnf.matcher;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.cli.command_limit;
import telar.base.ds;

namespace telar::runtime::cli {

  namespace {

    // As the runtime reads the user's specs: at most this much, named after the command.
    constexpr std::uintmax_t maximum_spec = std::uintmax_t{256} * 1024;
    constexpr std::size_t maximum_command_name = 64;
    constexpr std::size_t error_message_bytes = 128;

    bool commandName(std::string_view name) noexcept {
      return !name.empty() && name.size() <= maximum_command_name && name.front() != '.' && std::ranges::all_of(name, [](char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '+' || byte == '-';
      });
    }

    // POSIX's strerror_r writes the message and returns 0; glibc's returns the message itself.
    template <typename Result>
    const char* errorMessage(Result result, const char* buffer) noexcept {
      if constexpr (std::is_pointer_v<Result>) {
        return result;
      } else {
        return result == 0 ? buffer : "Unknown error";
      }
    }

    int fail(std::string_view path, std::string_view reason) {
      std::println(stderr, "telar completions: {}: {}", path, reason);
      return 1;
    }

    // strerror's buffer is shared by every thread; strerror_r writes the message into this one.
    int failWithError(std::string_view path, int code) {
      ds::Array<char, error_message_bytes> buffer{};
      const auto view = buffer.viewMut();
      // strerror_r writes at most the size it is given, and both come from the one span.
#pragma clang unsafe_buffer_usage begin
      const char* const message = errorMessage(::strerror_r(code, view.data(), view.size()), view.data());
#pragma clang unsafe_buffer_usage end

      return fail(path, message);
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

    FileDescriptor file{::open(words[1], combineFlags(O_RDONLY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0) {
      return failWithError(path, sys::lastError());
    }

    if (std::cmp_greater(state.st_size, maximum_spec)) {
      return fail(path, "larger than 256 KiB");
    }

    Text source{memory};

    source.resizeForOverwrite(static_cast<std::size_t>(state.st_size));
    std::size_t done = 0;

    while (done < source.size()) {
      const auto rest = source.viewMut().subspan(done);
      const auto count = ::read(file.get(), rest.data(), rest.size());
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
