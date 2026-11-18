module telar.runtime.platform.session_host;

import telar.sys.posix;
import telar.config.core;
import telar.platform.paths;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  bool isCodexBatchArgument(std::string_view argument) noexcept {
    return std::ranges::any_of(codex_batch_arguments, [argument](std::string_view candidate) {
      return argument == candidate;
    });
  }

  bool codexHooksInstalled(const char* override_directory, std::string_view home) noexcept {
    const auto provider = config::IntegrationProvider::describe(AgentProvider::codex);
    ds::Array<char, PATH_MAX> path;
    int length = 0;

    if (override_directory != nullptr && *override_directory != '\0') {
      length = std::snprintf(path.dataMut(), path.size(), "%s%.*s/%.*s", override_directory, static_cast<int>(provider.environment_suffix.size()), provider.environment_suffix.data(), static_cast<int>(provider.file.size()), provider.file.data());
    } else if (!home.empty()) {
      length = std::snprintf(path.dataMut(), path.size(), "%.*s/%.*s/%.*s", static_cast<int>(home.size()), home.data(), static_cast<int>(provider.home_directory.size()), provider.home_directory.data(), static_cast<int>(provider.file.size()), provider.file.data());
    } else {
      return false;
    }

    if (length < 0 || static_cast<std::size_t>(length) >= path.size()) {
      return false;
    }

    FileDescriptor file{::open(path.data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
    struct stat metadata;
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
      return false;
    }

    constexpr std::size_t maximum_settings_bytes = 32 * 1024;
    ds::Array<char, maximum_settings_bytes> bytes;
    const auto count = ::read(file.get(), bytes.dataMut(), bytes.size());

    return count > 0 && std::string_view{bytes.data(), static_cast<std::size_t>(count)}.contains(" hook codex");
  }

  bool hooksInstalled(AgentProvider provider, SessionHost host) noexcept {
    return provider == AgentProvider::codex && host == SessionHost::shared_server && codexHooksInstalled(std::getenv(config::IntegrationProvider::describe(AgentProvider::codex).environment), processHome());
  }

}
