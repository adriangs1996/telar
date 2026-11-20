module telar.runtime.host.session_host;

import telar.sys.posix;
import telar.config.core;
import telar.platform.paths;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // Joins `parts` into `path`, terminated; false when they do not fit.
    bool joinPath(std::span<char> path, std::initializer_list<std::string_view> parts) noexcept {
      std::size_t length = 0;

      for (const auto part : parts) {
        if (part.size() >= path.size() - length) {
          return false;
        }

        std::ranges::copy(part, path.subspan(length).begin());
        length += part.size();
      }

      path[length] = '\0';
      return true;
    }

  }

  bool isCodexBatchArgument(std::string_view argument) noexcept {
    return std::ranges::any_of(codex_batch_arguments, [argument](std::string_view candidate) {
      return argument == candidate;
    });
  }

  bool codexHooksInstalled(const char* override_directory, std::string_view home) noexcept {
    const auto provider = config::IntegrationProvider::describe(AgentProvider::codex);
    ds::Array<char, PATH_MAX> path{};
    bool joined = false;

    if (override_directory != nullptr && *override_directory != '\0') {
      joined = joinPath(path.viewMut(), {override_directory, provider.environment_suffix, "/", provider.file});
    } else if (!home.empty()) {
      joined = joinPath(path.viewMut(), {home, "/", provider.home_directory, "/", provider.file});
    }

    if (!joined) {
      return false;
    }

    FileDescriptor file{::open(path.data(), combineFlags(O_RDONLY, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat metadata{};
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
      return false;
    }

    constexpr std::size_t maximum_settings_bytes = std::size_t{32} * 1024;
    ds::Array<char, maximum_settings_bytes> bytes; // NOLINT(cppcoreguidelines-pro-type-member-init): read writes the bytes it reports, and only those are read, so zeroing 32 KiB per check is work no read needs
    const auto count = ::read(file.get(), bytes.dataMut(), bytes.size());

    return count > 0 && std::string_view{bytes.data(), static_cast<std::size_t>(count)}.contains(" hook codex");
  }

  bool hooksInstalled(AgentProvider provider, SessionHost host) noexcept {
    return provider == AgentProvider::codex && host == SessionHost::shared_server && codexHooksInstalled(std::getenv(config::IntegrationProvider::describe(AgentProvider::codex).environment), processHome()); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
  }

}
