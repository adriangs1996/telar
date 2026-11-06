module;

#include "telar_platform/random_bytes.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <cerrno>
#include <exception>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <vector>


#include "telar_platform/process_environment.h"

#include <chrono>
#include <cstdio>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <cstddef>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include "telar_base/memory/allocator.hpp"
#include <bit>
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <new>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <sys/file.h>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include <sys/un.h>
#include <openssl/sha.h>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include "telar_base/text/utf8.hpp"
#include <cctype>
#include <set>


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif


#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include "telar_client/serializers/telar_protocol.hpp"
#include <sys/socket.h>
#include <sys/time.h>
#include "telar_client/codecs/telar_codec.hpp"
#include <csignal>
#include <dirent.h>
#include <pwd.h>

export module telar.cli.machine_ssh;

export import telar.cli.command_limit;
export import telar.cli.plugin;
export import telar.platform;


export import telar.cli.server;


export import telar.client;


export import telar.cli.output;


export import telar.base.text;

// Interface: config_receive.cppm
export {
namespace telar::runtime::cli::config_receive {

inline constexpr std::size_t max_file_bytes = 1024 * 1024;
inline constexpr std::size_t max_total_bytes = 16 * max_file_bytes;
inline constexpr std::size_t max_files = 4096;
inline constexpr std::size_t max_line_bytes = PATH_MAX + 64;

inline std::string lower(std::string_view text) {
  std::string result{text};
  for (auto &byte : result) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }

  return result;
}

inline bool acceptable(std::string_view path) {
  if (path.empty() || path.size() > PATH_MAX || path.front() == '/' || std::ranges::any_of(path, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f || byte == '\\'; })) {
    return false;
  }

  static constexpr auto roots = std::to_array<std::string_view>({".claude/", ".codex/", ".pi/agent/", ".config/opencode/", ".cursor/", ".agents/skills/"});
  static constexpr auto credential_directories = std::to_array<std::string_view>({".ssh", ".gnupg", ".aws", ".kube", ".docker", "keychains", "gcloud", ".password-store"});
  static constexpr auto session_directories = std::to_array<std::string_view>({"projects", "sessions", "history", "todos", "shell-snapshots", "file-history", "statsig", "logs", "cache", "plans"});
  static constexpr auto credential_names = std::to_array<std::string_view>({".claude.json", ".credentials.json", "auth.json", "mcp-auth.json", "credentials", ".netrc", ".npmrc", ".pypirc", ".pgpass", ".vault-token", ".git-credentials", "hosts.yml", "models.json", "keys.json", "sa.json"});
  static constexpr auto extensions = std::to_array<std::string_view>({".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".jsonl", ".db", ".sqlite", ".sqlite3", ".log"});
  static constexpr auto fragments = std::to_array<std::string_view>({"credential", "secret", "token", "password", "passwd"});
  const auto name = lower(path.substr(path.rfind('/') == std::string_view::npos ? 0 : path.rfind('/') + 1));
  if (std::ranges::find(credential_names, name) != credential_names.end() || std::ranges::any_of(extensions, [&](auto extension) { return name.ends_with(extension); }) || std::ranges::any_of(fragments, [&](auto fragment) { return name.contains(fragment); }) || name == ".env" || name.starts_with(".env.") || name.ends_with(".env") || name.starts_with("id_rsa") || name.starts_with("id_ed25519") || name.starts_with("id_ecdsa") || name.starts_with("id_dsa")) {
    return false;
  }

  for (const auto root : roots) {
    if (!path.starts_with(root) || path.size() == root.size()) {
      continue;
    }

    auto tail = path.substr(root.size());
    const auto first = lower(tail.substr(0, tail.find('/')));
    if (std::ranges::find(session_directories, first) != session_directories.end()) {
      return false;
    }

    while (!tail.empty()) {
      const auto separator = tail.find('/');
      const auto component = tail.substr(0, separator);
      if (component.empty() || component.front() == '.' || std::ranges::find(credential_directories, lower(component)) != credential_directories.end()) {
        return false;
      }

      if (separator == std::string_view::npos) {
        return true;
      }

      tail.remove_prefix(separator + 1);
    }

    return false;
  }

  return false;
}

inline std::string line() {
  std::string result;
  char byte;
  while (std::cin.get(byte)) {
    if (byte == '\n') {
      return result;
    }

    if (result.size() == max_line_bytes) {
      throw CommandError{"InvalidConfigStream"};
    }

    result += byte;
  }

  throw CommandError{"InvalidConfigStream"};
}

// Each directory is held by descriptor and opened with O_NOFOLLOW. A symlink
// swapped in while receiving can never redirect the write outside HOME.
inline bool place(int home, const std::string &path, std::string_view bytes, mode_t mode) {
  FileDescriptor parent{::openat(home, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
  if (!parent) {
    throw fileError(errno);
  }

  std::string_view tail{path};
  for (;;) {
    const auto slash = tail.find('/');
    if (slash == std::string_view::npos) {
      break;
    }

    const std::string component{tail.substr(0, slash)};
    auto next = ::openat(parent.get(), component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0 && errno == ENOENT) {
      if (::mkdirat(parent.get(), component.c_str(), 0700) != 0 && errno != EEXIST) {
        throw fileError(errno);
      }

      next = ::openat(parent.get(), component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }

    if (next < 0) {
      if (errno == ELOOP || errno == ENOTDIR) {
        throw CommandError{"SymlinkOnTheWay"};
      }

      throw fileError(errno);
    }

    parent.reset(next);
    tail.remove_prefix(slash + 1);
  }

  const std::string name{tail};
  struct stat state{};
  if (::fstatat(parent.get(), name.c_str(), &state, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(state.st_mode)) {
      throw CommandError{"NotARegularFile"};
    }

    if (state.st_size == static_cast<off_t>(bytes.size()) && (state.st_mode & 0777) == mode) {
      FileDescriptor existing{::openat(parent.get(), name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
      if (!existing) {
        throw fileError(errno);
      }

      std::array<char, 16 * 1024> buffer;
      std::size_t offset = 0;
      bool same = true;
      for (;;) {
        const auto count = ::read(existing.get(), buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) {
          continue;
        }

        if (count < 0) {
          throw fileError(errno);
        }

        if (count == 0) {
          break;
        }

        const auto size = static_cast<std::size_t>(count);
        if (offset > bytes.size() || size > bytes.size() - offset || bytes.substr(offset, size) != std::string_view{buffer.data(), size}) {
          same = false;
          break;
        }

        offset += size;
      }

      if (same && offset == bytes.size()) {
        return false;
      }
    }
  } else if (errno != ENOENT) {
    throw fileError(errno);
  }

  std::uint64_t nonce;
  randomBytes(&nonce, sizeof(nonce));
  std::array<char, 64> temporary;
  std::snprintf(temporary.data(), temporary.size(), ".telar-%016llx", static_cast<unsigned long long>(nonce));
  FileDescriptor file{::openat(parent.get(), temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)};
  if (!file) {
    throw fileError(errno);
  }

  try {
    const auto error = writeDescriptor(file.get(), {reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()});
    if (error != 0) {
      throw fileError(error);
    }

    if (::fchmod(file.get(), mode) != 0 || ::fsync(file.get()) != 0) {
      throw fileError(errno);
    }

    file.reset();
    if (::renameat(parent.get(), temporary.data(), parent.get(), name.c_str()) != 0) {
      throw fileError(errno);
    }
  } catch (...) {
    ::unlinkat(parent.get(), temporary.data(), 0);
    throw;
  }

  return true;
}

inline int run() {
  const auto *home_path = std::getenv("HOME");
  if (!home_path) {
    throw CommandError{"HomeUnavailable"};
  }

  FileDescriptor home{::open(home_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!home) {
    throw fileError(errno);
  }

  if (line() != "telar-config 1") {
    throw CommandError{"InvalidConfigStream"};
  }

  std::size_t files = 0;
  std::size_t total = 0;
  std::string output;
  for (;;) {
    auto header = line();
    if (header == "end") {
      std::fwrite(output.data(), 1, output.size(), stdout);
      return 0;
    }

    std::string_view fields{header};
    std::array<std::string_view, 3> prefix;
    for (auto &field : prefix) {
      const auto end = fields.find(' ');
      if (end == std::string_view::npos) {
        throw CommandError{"InvalidConfigStream"};
      }

      field = fields.substr(0, end);
      fields.remove_prefix(end + 1);
    }

    const std::string path{fields};
    if (prefix[0] != "file") {
      throw CommandError{"InvalidConfigStream"};
    }

    std::size_t size = 0;
    try {
      size = parseInt<std::size_t>(prefix[2]);
    } catch (const std::invalid_argument &) {
      throw CommandError{"InvalidConfigStream"};
    }

    if (size > max_file_bytes || size > max_total_bytes - total || ++files > max_files) {
      throw CommandError{"ConfigStreamTooLarge"};
    }

    total += size;
    const mode_t mode = prefix[1] == "644" ? 0644 : prefix[1] == "755" ? 0755
                                                                       : 0;
    if (mode == 0 || path.size() > PATH_MAX) {
      throw CommandError{"InvalidConfigStream"};
    }

    std::string bytes(size, '\0');
    char separator = 0;
    if (!std::cin.read(bytes.data(), static_cast<std::streamsize>(size)) || !std::cin.get(separator) || separator != '\n') {
      throw CommandError{"InvalidConfigStream"};
    }

    if (!acceptable(path)) {
      output += "refused " + path + ": not a path the sync may write\n";
    } else {
      try {
        const auto written = place(home.get(), path, bytes, mode);
        output += std::string{written ? "written " : "unchanged "} + path + "\n";
      } catch (const std::exception &error) {
        output += "refused " + path + ": " + error.what() + "\n";
      }
    }

    constexpr std::size_t output_buffer = 4096;
    if (output.size() >= output_buffer) {
      std::fwrite(output.data(), 1, output.size(), stdout);
      output.clear();
    }
  }
}

}
}

// Interface: launch_process.cppm
export {

namespace telar::runtime::cli::launch {

inline constexpr int ssh_failure = 255;
inline constexpr std::size_t output_limit = 256 * 1024;
inline constexpr std::size_t error_limit = 64 * 1024;
inline constexpr auto poll_interval = std::chrono::milliseconds{10};

inline std::vector<char *> pointers(const std::vector<std::string> &arguments) {
  std::vector<char *> result;
  result.reserve(arguments.size() + 1);
  for (const auto &argument : arguments) {
    result.push_back(const_cast<char *>(argument.c_str()));
  }

  result.push_back(nullptr);
  return result;
}

[[noreturn]] inline void replace(const std::vector<std::string> &arguments) {
  const auto argv = pointers(arguments);
  ::execvp(argv.front(), argv.data());
  throw CommandError{errno == ENOENT ? "FileNotFound" : errno == EACCES ? "AccessDenied"
                                                                        : "Unexpected"};
}

inline pid_t spawn(const std::vector<std::string> &arguments, posix_spawn_file_actions_t *actions) {
  const auto argv = pointers(arguments);
  posix_spawnattr_t attributes;
  ::posix_spawnattr_init(&attributes);
  sigset_t signals;
  sigemptyset(&signals);
  ::posix_spawnattr_setsigmask(&attributes, &signals);
  short flags = POSIX_SPAWN_SETSIGMASK;
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  ::posix_spawnattr_setflags(&attributes, flags);
  posix_spawn_file_actions_t inherited;
  const bool inherit_streams = actions == nullptr;
  if (inherit_streams) {
    ::posix_spawn_file_actions_init(&inherited);
#if defined(__APPLE__)
    for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; ++descriptor) {
      ::posix_spawn_file_actions_addinherit_np(&inherited, descriptor);
    }
#endif
    actions = &inherited;
  }

  pid_t process = -1;
  const auto failure = ::posix_spawnp(&process, argv.front(), actions, &attributes, argv.data(), environ);
  ::posix_spawnattr_destroy(&attributes);
  if (inherit_streams) {
    ::posix_spawn_file_actions_destroy(&inherited);
  }

  if (failure != 0) {
    throw SystemError{"Start child process", failure};
  }

  return process;
}

inline int wait(pid_t process) {
  int status = 0;
  while (::waitpid(process, &status, 0) < 0) {
    if (errno != EINTR) {
      throw SystemError{"Wait for child process"};
    }
  }

  return WIFEXITED(status) ? WEXITSTATUS(status) : ssh_failure;
}

inline int inherit(const std::vector<std::string> &arguments) {
  return wait(spawn(arguments, nullptr));
}

struct Output {
  int status = ssh_failure;
  std::string out;
  std::string err;
  std::size_t dropped = 0;

  inline std::string_view errorLine() const {
    const auto end = err.find_last_not_of(" \r\n");
    if (end == std::string::npos) {
      return {};
    }

    const auto start = err.rfind('\n', end);
    return std::string_view{err}.substr(start == std::string::npos ? 0 : start + 1, end + 1 - (start == std::string::npos ? 0 : start + 1));
  }
};

struct Pipe {
  FileDescriptor read;
  FileDescriptor write;

  inline Pipe() {
    std::array<int, 2> ends;
    if (::pipe(ends.data()) != 0) {
      throw SystemError{"Create process pipe"};
    }

    read.reset(ends[0]);
    write.reset(ends[1]);
    ::fcntl(read.get(), F_SETFD, FD_CLOEXEC);
    ::fcntl(write.get(), F_SETFD, FD_CLOEXEC);
    ::fcntl(read.get(), F_SETFL, O_NONBLOCK);
  }
};

// The input is an unlinked owner-only file, so arbitrary script/binary sizes
// cannot deadlock against a child filling either output pipe.
inline Output capture(const std::vector<std::string> &arguments, int input, std::chrono::seconds timeout) {
  Pipe out;
  Pipe err;
  posix_spawn_file_actions_t actions;
  ::posix_spawn_file_actions_init(&actions);
  if (input < 0) {
    ::posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  } else {
    ::posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
  }

  ::posix_spawn_file_actions_adddup2(&actions, out.write.get(), STDOUT_FILENO);
  ::posix_spawn_file_actions_adddup2(&actions, err.write.get(), STDERR_FILENO);
  pid_t process;
  try {
    process = spawn(arguments, &actions);
  } catch (...) {
    ::posix_spawn_file_actions_destroy(&actions);
    throw;
  }

  ::posix_spawn_file_actions_destroy(&actions);
  out.write.reset();
  err.write.reset();
  Output result;
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  std::array<pollfd, 2> descriptors{{{out.read.get(), POLLIN, 0}, {err.read.get(), POLLIN, 0}}};
  const std::array<std::string *, 2> buffers{&result.out, &result.err};
  constexpr std::array limits{output_limit, error_limit};
  std::optional<int> status;
  try {
    while (!status || descriptors[0].fd >= 0 || descriptors[1].fd >= 0) {
      if (std::chrono::steady_clock::now() >= deadline) {
        throw CommandError{"Timeout"};
      }

      const auto ready = ::poll(descriptors.data(), descriptors.size(), static_cast<int>(poll_interval.count()));
      if (ready < 0 && errno != EINTR) {
        throw SystemError{"Read child process output"};
      }

      for (std::size_t index = 0; index < descriptors.size(); ++index) {
        if (descriptors[index].fd < 0 || descriptors[index].revents == 0) {
          continue;
        }

        std::array<char, 16 * 1024> chunk;
        const auto count = ::read(descriptors[index].fd, chunk.data(), chunk.size());
        if (count == 0) {
          descriptors[index].fd = -1;
        } else if (count > 0) {
          auto &buffer = *buffers[index];
          buffer.append(chunk.data(), static_cast<std::size_t>(count));
          if (buffer.size() > limits[index]) {
            const auto dropped = buffer.size() - limits[index];
            if (index == 0) {
              result.dropped += dropped;
            }

            buffer.erase(0, dropped);
          }
        } else if (errno != EINTR && errno != EAGAIN) {
          throw SystemError{"Read child process stream"};
        }
      }

      int exited = 0;
      if (!status && ::waitpid(process, &exited, WNOHANG) == process) {
        status = WIFEXITED(exited) ? WEXITSTATUS(exited) : ssh_failure;
      }
    }
  } catch (...) {
    if (!status) {
      ::kill(process, SIGKILL);
      wait(process);
    }

    throw;
  }

  result.status = *status;
  return result;
}

inline Output captureBytes(const std::vector<std::string> &arguments, std::string_view input, std::chrono::seconds timeout) {
  const auto *temporary = std::getenv("TMPDIR");
  std::string name = std::string{temporary && *temporary ? temporary : "/tmp"} + "/telar-script-XXXXXX";
  FileDescriptor file{::mkstemp(name.data())};
  if (!file) {
    throw SystemError{"Create private process input"};
  }

  ::unlink(name.c_str());
  ::fcntl(file.get(), F_SETFD, FD_CLOEXEC);
  const auto failure = writeDescriptor(file.get(), {reinterpret_cast<const std::uint8_t *>(input.data()), input.size()});
  if (failure != 0 || ::lseek(file.get(), 0, SEEK_SET) < 0) {
    throw SystemError{"Write process input", failure != 0 ? failure : errno};
  }

  return capture(arguments, file.get(), timeout);
}

inline std::string quote(std::string_view value) {
  std::string result = "'";
  for (const auto byte : value) {
    result += byte == '\'' ? "'\\''" : std::string(1, byte);
  }

  return result + "'";
}

}
}

// Interface: machine_options.cppm
export {
namespace telar::runtime::cli {

struct MachineOptions {
  enum class Action {
    add,
    remove,
    rename,
    enable,
    disable,
    list,
    check,
    setup,
    receive_config
  };
  Action action;
  std::string_view label;
  std::string_view value;
  std::optional<std::string_view> color;
  std::optional<std::string_view> new_label;
  std::optional<std::string_view> binary;
  bool disabled = false;
  bool check = false;
  bool json = false;
  bool setup = false;
  bool confirm = false;
  std::array<bool, 3> skip{};

  inline static MachineOptions parse(std::span<char *const> args) {
    if (args.empty()) {
      throw std::invalid_argument{"MissingMachineAction"};
    }

    static constexpr std::array<std::string_view, 9> names{"add", "remove", "rename", "enable", "disable", "list", "check", "setup", "receive-config"};
    const auto found = std::ranges::find(names, std::string_view{args.front()});
    if (found == names.end()) {
      throw std::invalid_argument{"UnknownMachineAction"};
    }

    MachineOptions result{.action = static_cast<Action>(found - names.begin())};
    const auto action = result.action;
    const std::size_t positional = action == Action::list || action == Action::receive_config ? 0 : action == Action::add || action == Action::rename ? 2
                                                                                                                                                      : 1;
    if (action == Action::receive_config && args.size() != 1) {
      throw std::invalid_argument{"UnknownMachineOption"};
    }

    if (args.size() < positional + 1) {
      throw std::invalid_argument{"MissingMachineArgument"};
    }

    if (positional != 0) {
      result.label = args[1];
    }

    if (positional == 2) {
      result.value = args[2];
    }

    Cursor cursor{args.subspan(positional + 1)};
    while (const auto next = cursor.next()) {
      const std::string_view word = *next;
      const bool takes_setup = action == Action::add || action == Action::setup;
      const auto value = [&] { return cursor.take("MissingMachineArgument"); };
      if (word == "--json" && (action == Action::list || action == Action::check || takes_setup)) {
        result.json = true;
      } else if (word == "--setup" && action == Action::add) {
        result.setup = true;
      } else if (word == "--confirm" && action == Action::setup) {
        result.confirm = true;
      } else if (word == "--label" && action == Action::setup) {
        result.new_label = value();
      } else if (word == "--binary" && takes_setup) {
        result.binary = value();
      } else if (word == "--skip" && takes_setup) {
        auto names = value();
        do {
          const auto end = names.find(',');
          const auto name = names.substr(0, end);
          if (name == "agents") {
            result.skip[0] = true;
          } else if (name == "config") {
            result.skip[1] = true;
          } else if (name == "login") {
            result.skip[2] = true;
          } else {
            throw std::invalid_argument{"UnknownSetupSkip"};
          }

          if (end == std::string_view::npos) {
            break;
          }

          names.remove_prefix(end + 1);
        } while (true);
      } else if (word == "--color" && action == Action::add) {
        if (result.color) {
          throw std::invalid_argument{"DuplicateColorOption"};
        }

        result.color = cursor.take("MissingMachineColor");
      } else if (word == "--disabled" && action == Action::add) {
        result.disabled = true;
      } else if (word == "--check" && action == Action::add) {
        result.check = true;
      } else {
        throw std::invalid_argument{"UnknownMachineOption"};
      }
    }

    if (action == Action::add && !result.setup && (result.binary || std::ranges::any_of(result.skip, [](bool value) { return value; }))) {
      throw std::invalid_argument{"SetupOptionWithoutSetup"};
    }

    return result;
  }
};

}
}

// Interface: machine_store.cppm
export {
namespace telar::runtime::cli::machine {

using namespace machines;

inline std::string profilesPath() {
  const ProcessEnvironment environment;
  const auto config = environment.lookup("XDG_CONFIG_HOME");
  if (!config.empty()) {
    return std::string{config} + "/telar/machines.json";
  }

  const auto home = environment.lookup("HOME");
  if (home.empty()) {
    throw CommandError{"HomeUnavailable"};
  }

  return std::string{home} + "/.config/telar/machines.json";
}

template <Allocator Memory>
MachineProfiles load(Memory &memory, const std::string &path) {
  Vector<unsigned char, Memory> source{AllocatorRef<unsigned char, Memory>{memory}};
  try {
    if (!readPrivateFile(AT_FDCWD, path, source, MachineLimits::file_bytes)) {
      return {};
    }
  } catch (const SystemError &error) {
    if (error.code() == EACCES || error.code() == ELOOP || error.code() == EISDIR) {
      throw CommandError{"InsecureFile"};
    }

    if (error.code() == EFBIG) {
      throw CommandError{"StreamTooLong"};
    }

    throw fileError(error.code());
  }

  return MachineProfileCodec::parse(memory, {reinterpret_cast<const char *>(source.data()), source.size()});
}

inline std::string localLabel(const MachineProfiles &profiles) {
  if (const auto label = profiles.localLabel()) {
    return std::string{*label};
  }

  std::array<char, 256> name{};
  return ::gethostname(name.data(), name.size()) == 0 ? std::string{name.data()} : "localhost";
}

inline void requireNotLocal(const MachineProfiles &profiles, std::string_view label) {
  if (label == localLabel(profiles)) {
    throw MachineFailure{MachineError::duplicate_label};
  }
}

struct Random {
  inline void fill(std::span<std::uint8_t> bytes) {
    randomBytes(bytes.data(), bytes.size());
  }
};

inline MachineProfile newProfile(const MachineProfiles &profiles, const MachineOptions &options) {
  requireNotLocal(profiles, options.label);
  Random random;
  return MachineProfile::create(MachineId::generate(random), {
                                                                 .label = options.label,
                                                                 .destination = options.value,
                                                                 .color = options.color,
                                                                 .enabled = !options.disabled,
                                                             });
}

inline void change(MachineProfiles &profiles, const MachineOptions &options) {
  switch (options.action) {
  case MachineOptions::Action::add:
    profiles.add(newProfile(profiles, options));
    break;
  case MachineOptions::Action::remove:
    profiles.remove(options.label);
    break;
  case MachineOptions::Action::rename:
    requireNotLocal(profiles, options.value);
    profiles.rename(options.label, options.value);
    break;
  case MachineOptions::Action::enable:
  case MachineOptions::Action::disable:
    profiles.enable(options.label, options.action == MachineOptions::Action::enable);
    break;
  default:
    throw std::logic_error{"Expected a machine profile edit"};
  }
}

template <Allocator Memory, typename Edit>
void update(Memory &memory, const std::string &path, Edit edit) {
  const auto absolute = std::filesystem::absolute(path);
  createPrivateDirectory(absolute.parent_path().string());
  auto parent = openPrivateParent(absolute.string());
  const auto name = absolute.filename().string();
  const auto lock_name = name + ".lock";
  FileDescriptor lock{::openat(parent.get(), lock_name.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600)};
  struct stat state{};
  if (!lock || ::fstat(lock.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
    throw CommandError{"InsecureFile"};
  }

  while (::flock(lock.get(), LOCK_EX) != 0) {
    if (errno != EINTR) {
      throw fileError(errno);
    }
  }

  auto profiles = load(memory, absolute.string());
  edit(profiles);
  const auto source = MachineProfileCodec::format(memory, profiles);
  const auto error = writePrivateFile(parent.get(), name, byteView(source), PrivateFileMode::replace);
  if (error != 0) {
    throw fileError(error);
  }
}

inline const char *describe(std::string_view error) {
  if (error == "SetupBinaryCompanionsMissing") {
    return "a C++ --binary needs telar-runtime and telar-config-check beside it";
  }

  if (error == "InsecureFile") {
    return "machines.json must be a regular file only its owner can read and write (chmod 600)";
  }

  if (error == "UnknownMachine") {
    return "no saved machine has that label; see `telar machine list`";
  }

  if (error == "DuplicateMachineLabel") {
    return "that label is already taken, by a saved machine or by this machine";
  }

  if (error == "DuplicateMachineDestination") {
    return "two saved machines cannot share one SSH destination";
  }

  if (error == "TooManyMachines") {
    return "machines.json already holds the most machines it can";
  }

  if (error == "InvalidMachineLabel") {
    return "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit";
  }

  if (error == "InvalidMachineColor") {
    return "colors are #RRGGBB or a theme role such as red or accent";
  }

  if (error == "InvalidRemoteDestination") {
    return "destinations are an ssh host alias or user@host, without spaces or a leading '-'";
  }

  if (error == "InvalidRemoteTelarPath") {
    return "telar paths are absolute and hold only letters, digits, '/', '.', '_', '+' or '-'";
  }

  if (error == "InvalidMachineProfiles") {
    return "machines.json is not a file this telar can read";
  }

  if (error == "IncompatibleMachineProfiles") {
    return "machines.json was written by a newer telar; update this one to read it";
  }

  return nullptr;
}

inline int report(const std::exception &error) {
  const auto *text = describe(error.what());
  std::fprintf(stderr, "telar machine: %s\n", text ? text : error.what());
  return 1;
}

template <Allocator Memory>
int list(Memory &memory, const MachineProfiles &profiles, bool json) {
  if (json) {
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += "{\"local\":";
    appendJsonString(output, localLabel(profiles));
    output += ",\"machines\":[";
    bool first = true;
    for (const auto &profile : profiles.rows()) {
      if (!first) {
        output += ',';
      }

      first = false;
      MachineProfileCodec::appendProfile(output, profile);
    }

    output += "]}\n";
    std::fwrite(output.data(), 1, output.size(), stdout);
  } else {
    std::printf("%s\tlocal\n", localLabel(profiles).c_str());
    for (const auto &profile : profiles.rows()) {
      std::printf("%.*s\t%.*s\t%s", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), profile.enabled() ? "enabled" : "disabled");
      if (const auto color = profile.color()) {
        std::printf("\t%.*s", static_cast<int>(color->size()), color->data());
      }

      bool first = true;
      for (const auto agent : machine_agents) {
        if (const auto login = profile.login(agent)) {
          std::printf("%s%s %s", first ? "\tlogins: " : ", ", machine_agent_names.at(static_cast<std::size_t>(agent)).data(), machine_login_names.at(static_cast<std::size_t>(*login)).data());
          first = false;
        }
      }

      std::putchar('\n');
    }
  }

  return 0;
}

}
}

// Interface: machine_ssh.cppm
export {
namespace telar::runtime::cli::machine {

inline constexpr std::size_t command_limit = 64 * 1024;
inline constexpr auto endpoint_timeout = std::chrono::seconds{30};
inline constexpr auto probe_timeout = std::chrono::seconds{60};
inline constexpr auto install_timeout = std::chrono::seconds{900};
inline constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
using Discovery = machines::MachineDiscovery<PATH_MAX>;

inline std::string encode(std::string_view argument) {
  std::string result{"a"};
  unsigned value = 0;
  unsigned bits = 0;
  for (const unsigned char byte : argument) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      result += alphabet[(value >> bits) & 63];
    }
  }

  if (bits != 0) {
    result += alphabet[(value << (6 - bits)) & 63];
  }

  return result;
}

inline std::string decode(std::string_view word) {
  if (word.empty() || word.front() != 'a') {
    throw CommandError{"InvalidDispatchArgument"};
  }

  word.remove_prefix(1);
  if (word.size() % 4 == 1) {
    throw CommandError{"InvalidDispatchArgument"};
  }

  std::string result;
  unsigned value = 0;
  unsigned bits = 0;
  for (const auto byte : word) {
    const auto digit = alphabet.find(byte);
    if (digit == std::string_view::npos) {
      throw CommandError{"InvalidDispatchArgument"};
    }

    value = (value << 6) | static_cast<unsigned>(digit);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      const auto decoded = static_cast<char>((value >> bits) & 255);
      if (decoded == '\0') {
        throw CommandError{"InvalidDispatchArgument"};
      }

      result += decoded;
    }
  }

  if (bits != 0 && (value & ((1u << bits) - 1)) != 0) {
    throw CommandError{"InvalidDispatchArgument"};
  }

  return result;
}

// Zig's `SshOptions`: the options every connection to `destination` shares,
// including the control master that keeps one SSH session per machine.
template <Allocator Memory>
std::vector<std::string> sshOptions(Memory &memory, std::string_view destination) {
  MachineFieldRules::destination(destination);
  const RuntimePaths paths{memory, ServerOptions{}, ProcessEnvironment{}};
  paths.prepareSocket();
  const auto directory = std::string_view{paths.socket}.substr(0, paths.socket.rfind('/'));
  std::array<unsigned char, SHA256_DIGEST_LENGTH> digest;
  ::SHA256(reinterpret_cast<const unsigned char *>(destination.data()), destination.size(), digest.data());
  std::uint64_t hash = 0;
  constexpr unsigned bits_per_byte = 8;
  constexpr unsigned control_hash_shift = 16;
  for (std::size_t index = 0; index < sizeof(hash); ++index) {
    hash |= static_cast<std::uint64_t>(digest[index]) << (index * bits_per_byte);
  }

  std::array<char, 32> name;
  std::snprintf(name.data(), name.size(), "/ssh-%012llx", static_cast<unsigned long long>(hash >> control_hash_shift));
  return {"-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "ForwardAgent=no", "-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-o", "ControlPath=" + std::string{directory} + name.data()};
}

template <Allocator Memory>
std::vector<std::string> ssh(Memory &memory, std::string_view destination, std::string_view command) {
  auto argv = sshOptions(memory, destination);
  argv.insert(argv.begin(), {"ssh", "-T"});
  argv.insert(argv.end(), {"--", std::string{destination}, std::string{command}});
  return argv;
}

// `GIT_SSH_COMMAND` for Git traffic to `destination` over the same options.
template <Allocator Memory>
std::string gitSshCommand(Memory &memory, std::string_view destination) {
  std::string command{"ssh"};
  for (const auto &word : sshOptions(memory, destination)) {
    if (word.contains('\'')) {
      throw CommandError{"UnquotableSshOption"};
    }

    command += " '";
    command += word;
    command += '\'';
  }

  return command;
}

// The shell command that runs `words` as one telar command there.
template <typename Words>
std::string remoteCommand(const MachineProfile &profile, const Words &words) {
  std::string command = std::string{profile.program().value_or("telar")} + " dispatch-argv";
  for (const std::string_view word : words) {
    const auto encoded = encode(word);
    if (command.size() + 1 + encoded.size() > command_limit) {
      throw CommandError{"MachineCommandTooLong"};
    }

    command += ' ';
    command += encoded;
  }

  return command;
}

// Zig's `machine_dispatch.forward`: runs one telar command there with this
// terminal's streams and returns its exit status.
template <Allocator Memory, typename Words>
int forward(Memory &memory, const MachineProfile &profile, const Words &words) {
  return launch::inherit(ssh(memory, profile.destination(), remoteCommand(profile, words)));
}

// Zig's `machine_dispatch.capture` and `captureFile`: runs one telar command
// there, reading `input` (or nothing), and returns its stdout. Its stderr
// passes through; a failure throws `failure`.
template <Allocator Memory, typename Words>
std::string capture(Memory &memory, const MachineProfile &profile, const Words &words, const char *failure, int input = -1) {
  constexpr auto capture_timeout = std::chrono::seconds{900};
  const auto result = launch::capture(ssh(memory, profile.destination(), remoteCommand(profile, words)), input, capture_timeout);
  std::fwrite(result.err.data(), 1, result.err.size(), stderr);
  if (result.status != 0 || result.dropped != 0) {
    throw CommandError{failure};
  }

  return result.out;
}

// Zig's `machine_dispatch.resolve`: the saved machine `label` names, or
// nullopt for this machine's own label.
template <Allocator Memory>
std::optional<MachineProfile> resolve(Memory &memory, std::string_view label) {
  const auto profiles = load(memory, profilesPath());
  if (const auto index = profiles.find(label)) {
    return profiles.rows()[*index];
  }

  if (label != localLabel(profiles)) {
    throw CommandError{"UnknownMachine"};
  }

  return std::nullopt;
}

inline std::string_view trimmed(std::string_view text) {
  const auto start = text.find_first_not_of(" \t\r\n");
  if (start == std::string_view::npos) {
    return {};
  }

  return text.substr(start, text.find_last_not_of(" \t\r\n") + 1 - start);
}

inline MachineError sshFailure(const launch::Output &output) {
  if (output.err.contains("telar protocol mismatch")) {
    return MachineError::remote_runtime_incompatible;
  }

  if (output.status == 126 || output.status == 127) {
    return MachineError::remote_program_missing;
  }

  if (output.status == launch::ssh_failure) {
    if (output.err.contains("Host key verification failed") || output.err.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")) {
      return MachineError::host_key_rejected;
    }

    if (output.err.contains("Permission denied (") || output.err.contains("Too many authentication failures")) {
      return MachineError::authentication_failed;
    }
  }

  return MachineError::endpoint_unavailable;
}

template <Allocator Memory>
Discovery discover(Memory &memory, const MachineProfile &profile, std::string &detail) {
  launch::Output output;
  try {
    output = launch::capture(ssh(memory, profile.destination(), MachineRemoteCommand::discovery(profile.program()).view()), -1, endpoint_timeout);
  } catch (const std::exception &) {
    throw MachineFailure{MachineError::endpoint_unavailable};
  }

  constexpr std::size_t detail_limit = 1024;
  if (output.status != 0) {
    const auto failure = sshFailure(output);
    if (failure == MachineError::remote_program_missing) {
      detail = "telar is not on the PATH of non-interactive SSH sessions there: ";
    } else if (failure == MachineError::remote_runtime_incompatible) {
      detail = "the runtime there is another telar build; run `telar server stop` there: ";
    }

    if (failure == MachineError::host_key_rejected) {
      std::string_view lines{output.err};
      while (!lines.empty()) {
        const auto end = lines.find('\n');
        const auto line = lines.substr(0, end);
        if (line.contains("you have requested strict checking") || line.contains("Host key verification failed")) {
          detail += std::string{trimmed(line)} + " ";
        }

        if (end == std::string_view::npos) {
          break;
        }

        lines.remove_prefix(end + 1);
      }
    } else {
      detail += output.err;
    }

    detail.resize(std::min(detail.size(), detail_limit));
    throw MachineFailure{failure};
  }

  try {
    if (output.dropped != 0) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    return Discovery::parse(output.out);
  } catch (const MachineFailure &) {
    detail = "`telar server endpoint` there printed something this telar cannot read; install the same telar build on both machines and keep shell startup files quiet";
    throw;
  }
}

template <Allocator Memory>
int check(Memory &memory, const MachineProfile &profile, bool json) {
  std::string detail;
  std::optional<Discovery> found;
  try {
    found = discover(memory, profile, detail);
  } catch (const MachineFailure &error) {
    if (json) {
      String<Memory> output{AllocatorRef<char, Memory>{memory}};
      output += "{\"label\":";
      appendJsonText(output, profile.label(), JsonEscapes::control);
      output += ",\"reachable\":false,\"error\":";
      appendJsonText(output, error.what(), JsonEscapes::control);
      output += ",\"detail\":";
      appendJsonText(output, trimmed(detail), JsonEscapes::control);
      output += "}\n";
      std::fwrite(output.data(), 1, output.size(), stdout);
    } else {
      std::fprintf(stderr, "telar machine: %.*s (%.*s) is not reachable: %s\n%.*s\n", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), error.what(), static_cast<int>(trimmed(detail).size()), trimmed(detail).data());
    }

    return 1;
  }

  const auto schema = std::string{found->schema().begin(), found->schema().end()};
  const auto local_schema = std::string{handshake::schema_id.begin(), handshake::schema_id.end()};
  if (json) {
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += "{\"label\":";
    appendJsonText(output, profile.label(), JsonEscapes::control);
    output += ",\"reachable\":true,\"schema\":\"" + schema + "\",\"local_schema\":\"" + local_schema + "\",\"compatible\":";
    output += found->compatible() ? "true" : "false";
    for (const auto &[name, value] : std::array<std::pair<std::string_view, std::string_view>, 3>{{{"home", found->home()}, {"shell", found->shell()}, {"socket", found->endpoint()}}}) {
      output += ",\"";
      output += name;
      output += "\":";
      appendJsonText(output, value, JsonEscapes::control);
    }

    output += "}\n";
    std::fwrite(output.data(), 1, output.size(), stdout);
  } else {
    std::printf("%.*s\t%.*s\treachable\n  home\t%.*s\n  shell\t%.*s\n  socket\t%.*s\n  schema\t%s (%s)\n", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), static_cast<int>(found->home().size()), found->home().data(), static_cast<int>(found->shell().size()), found->shell().data(), static_cast<int>(found->endpoint().size()), found->endpoint().data(), schema.c_str(), found->compatible() ? "matches this telar" : ("does not match this telar " + local_schema + "; update telar on one side").c_str());
  }

  return found->compatible() ? 0 : 1;
}

}
}

// Interface: machines/config_filter.cppm
export {
namespace telar::runtime::cli::machine::filter {

using config_receive::lower;

inline bool whitespace(char byte) {
  return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\v' || byte == '\f';
}

inline std::string_view trim(std::string_view text, std::string_view characters = " \t\r\n") {
  const auto begin = text.find_first_not_of(characters);
  return begin == std::string_view::npos ? std::string_view{} : text.substr(begin, text.find_last_not_of(characters) + 1 - begin);
}

inline void noteOnce(std::vector<std::string> &notes, std::string_view name) {
  if (std::ranges::find(notes, name) == notes.end()) {
    notes.emplace_back(name);
  }
}

enum class Kind {
  scalar,
  text,
  container
};

inline bool secretKey(std::string_view name, Kind kind) {
  static constexpr auto dropped = std::to_array<std::string_view>({"env", "environment", "headers", "http_headers", "env_http_headers", "auth", "authInfo", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper", "mcpServers", "mcp", "mcp_servers", "token", "accessToken", "access_token", "refreshToken", "refresh_token", "idToken", "id_token"});
  static constexpr auto fragments = std::to_array<std::string_view>({"secret", "password", "passphrase", "apikey", "api_key", "api-key", "credential", "bearer", "private_key", "privatekey", "authorization", "cookie"});
  const auto text = lower(name);
  return std::ranges::find(dropped, name) != dropped.end() || std::ranges::any_of(fragments, [&](auto fragment) { return text.contains(fragment); }) || (kind != Kind::scalar && (text.contains("token") || text.contains("auth")));
}

inline std::string rewriteHome(std::string_view bytes, std::string_view from, std::string_view to) {
  if (from.empty()) {
    throw CommandError{"HomeUnavailable"};
  }

  std::string output;
  for (;;) {
    const auto at = bytes.find(from);
    if (at == std::string_view::npos) {
      output += bytes;
      return output;
    }

    const auto after = at + from.size();
    const bool ends = after == bytes.size() || bytes[after] == '/' || bytes[after] == '"' || bytes[after] == '\'' || whitespace(bytes[after]);
    output += bytes.substr(0, at);
    output += ends ? to : from;
    bytes.remove_prefix(after);
  }
}

inline std::string stripJsonc(std::string_view bytes) {
  std::string result;
  bool string = false;
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    const auto byte = bytes[index];
    if (string) {
      result += byte;
      if (byte == '\\' && index + 1 < bytes.size()) {
        result += bytes[++index];
      } else if (byte == '"') {
        string = false;
      }
    } else if (byte == '"') {
      string = true;
      result += byte;
    } else if (bytes.substr(index).starts_with("//")) {
      index = bytes.find('\n', index);
      if (index == std::string_view::npos) {
        break;
      }

      result += '\n';
    } else if (bytes.substr(index).starts_with("/*")) {
      const auto end = bytes.find("*/", index + 2);
      if (end == std::string_view::npos) {
        throw CommandError{"UnterminatedComment"};
      }

      index = end + 1;
    } else {
      result += byte;
    }
  }

  std::string plain;
  string = false;
  for (std::size_t index = 0; index < result.size(); ++index) {
    const auto byte = result[index];
    if (string) {
      plain += byte;
      if (byte == '\\' && index + 1 < result.size()) {
        plain += result[++index];
      } else if (byte == '"') {
        string = false;
      }
    } else if (byte == '"') {
      string = true;
      plain += byte;
    } else if (byte == ',') {
      auto next = index + 1;
      while (next < result.size() && whitespace(result[next])) {
        ++next;
      }

      if (next == result.size() || (result[next] != '}' && result[next] != ']')) {
        plain += byte;
      }
    } else {
      plain += byte;
    }
  }

  return plain;
}

template <Allocator Memory>
void json(Memory &memory, const JsonValue &value, String<Memory> &output, std::vector<std::string> &dropped) {
  const auto source = value.encoded();
  String<Memory> scratch{AllocatorRef<char, Memory>{memory}};
  if (source.starts_with('{')) {
    output += '{';
    bool first = true;
    value.eachMember([&](JsonValue key, JsonValue child) {
      key.string(scratch);
      const auto encoded = child.encoded();
      const auto kind = encoded.starts_with('"') ? Kind::text : encoded.starts_with('{') || encoded.starts_with('[') ? Kind::container
                                                                                                                     : Kind::scalar;
      if (secretKey(scratch, kind)) {
        noteOnce(dropped, scratch);
        return;
      }

      if (!first) {
        output += ',';
      }

      first = false;
      output += key.encoded();
      output += ':';
      json(memory, child, output, dropped);
    });
    output += '}';
  } else if (source.starts_with('[')) {
    output += '[';
    bool first = true;
    value.eachElement([&](JsonValue child) {
      if (!first) {
        output += ',';
      }

      first = false;
      json(memory, child, output, dropped);
    });
    output += ']';
  } else {
    output += source;
  }
}

inline std::size_t skipQuoted(std::string_view text, std::size_t start) {
  const auto quote = text[start];
  auto index = start + 1;
  while (index < text.size() && text[index] != quote) {
    index += quote == '"' && text[index] == '\\' ? 2 : 1;
  }

  return std::min(index, text.size());
}

struct TomlValue {
  char delimiter = 0;
  int depth = 0;

  inline bool open() const {
    return delimiter != 0 || depth > 0;
  }

  inline void scan(std::string_view text) {
    for (std::size_t index = 0; index < text.size();) {
      const auto tail = text.substr(index);
      if (delimiter != 0) {
        if (delimiter == '"' && text[index] == '\\') {
          index += 2;
          continue;
        }

        if ((delimiter == '"' && tail.starts_with("\"\"\"")) || (delimiter == '\'' && tail.starts_with("'''"))) {
          delimiter = 0;
          index += 3;
          continue;
        }
      } else if (tail.starts_with("\"\"\"") || tail.starts_with("'''")) {
        delimiter = text[index];
        index += 3;
        continue;
      } else {
        const auto byte = text[index];
        if (byte == '#') {
          return;
        }

        if (byte == '"' || byte == '\'') {
          index = skipQuoted(text, index);
        } else if (byte == '[' || byte == '{') {
          ++depth;
        } else if (byte == ']' || byte == '}') {
          --depth;
        }
      }

      ++index;
    }
  }
};

inline std::optional<std::string> tomlSecret(std::string_view path, Kind last) {
  constexpr std::size_t max_components = 16;
  std::vector<std::string_view> components;
  std::size_t start = 0;
  for (std::size_t index = 0; index <= path.size();) {
    if (index == path.size() || path[index] == '.') {
      if (components.size() == max_components) {
        return std::string{path};
      }

      components.push_back(trim(trim(path.substr(start, index - start), " \t"), "\"'"));
      start = ++index;
    } else {
      index = path[index] == '"' || path[index] == '\'' ? skipQuoted(path, index) + 1 : index + 1;
    }
  }

  static constexpr auto tables = std::to_array<std::string_view>({"mcp_servers", "projects", "shell_environment_policy"});
  if (std::ranges::find(tables, components.front()) != tables.end()) {
    return std::string{components.front()};
  }

  for (std::size_t index = 0; index < components.size(); ++index) {
    if (secretKey(components[index], index + 1 == components.size() ? last : Kind::container)) {
      return std::string{components[index]};
    }
  }

  return std::nullopt;
}

inline std::string toml(std::string_view bytes, std::vector<std::string> &dropped) {
  bool skipping_table = false;
  bool dropping_value = false;
  bool first = true;
  TomlValue value;
  std::string output;
  for (;;) {
    const auto newline = bytes.find('\n');
    const auto line = bytes.substr(0, newline);
    bool keep = !skipping_table;
    if (value.open()) {
      value.scan(line);
      keep = keep && !dropping_value;
    } else {
      const auto text = trim(line, " \t\r");
      if (text.starts_with('[')) {
        auto inner = text;
        while (inner.starts_with('[')) {
          inner.remove_prefix(1);
        }

        std::size_t index = 0;
        while (index < inner.size() && inner[index] != ']') {
          index = inner[index] == '"' || inner[index] == '\'' ? skipQuoted(inner, index) + 1 : index + 1;
        }

        const auto offending = tomlSecret(inner.substr(0, std::min(index, inner.size())), Kind::container);
        skipping_table = offending.has_value();
        keep = !skipping_table;
        if (offending) {
          noteOnce(dropped, *offending);
        }
      } else if (!text.empty() && !text.starts_with('#')) {
        std::size_t equals = 0;
        while (equals < text.size() && text[equals] != '=') {
          equals = text[equals] == '"' || text[equals] == '\'' ? skipQuoted(text, equals) + 1 : equals + 1;
        }

        if (equals < text.size()) {
          const auto rest = trim(text.substr(equals + 1), " \t");
          const auto kind = rest.empty() || rest.front() == '"' || rest.front() == '\'' ? Kind::text : rest.front() == '[' || rest.front() == '{' ? Kind::container
                                                                                                                                                  : Kind::scalar;
          const auto offending = tomlSecret(text.substr(0, equals), kind);
          dropping_value = offending.has_value();
          value.scan(rest);
          if (offending) {
            keep = false;
            if (!skipping_table) {
              noteOnce(dropped, *offending);
            }
          }
        }
      }
    }

    if (keep) {
      if (!first) {
        output += '\n';
      }

      first = false;
      output += line;
    }

    if (newline == std::string_view::npos) {
      break;
    }

    bytes.remove_prefix(newline + 1);
  }

  return output;
}

inline bool tokenByte(char byte) {
  return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
}

inline bool placeholder(char byte) {
  return std::string_view{"$<{%[(*"}.contains(byte);
}

inline bool secretName(std::string_view name) {
  if (name.size() > 128) {
    return false;
  }

  const auto text = lower(name);
  static constexpr auto names = std::to_array<std::string_view>({"key", "auth", "pat", "pwd"});
  static constexpr auto fragments = std::to_array<std::string_view>({"token", "secret", "passw", "api_key", "apikey", "api-key", "access_key", "accesskey", "private_key", "authorization", "credential", "webhook", "cookie"});
  static constexpr auto suffixes = std::to_array<std::string_view>({"_key", "-key", "_header", "-header", "_app", "-app"});
  return std::ranges::find(names, text) != names.end() || std::ranges::any_of(fragments, [&](auto fragment) { return text.contains(fragment); }) || std::ranges::any_of(suffixes, [&](auto suffix) { return text.ends_with(suffix); }) || text.starts_with("auth_") || text.starts_with("auth-");
}

inline std::optional<std::string_view> nextWord(std::string_view &rest) {
  rest = trim(rest, " \t");
  if (!rest.empty() && (rest.front() == '"' || rest.front() == '\'')) {
    rest.remove_prefix(1);
  }

  if (rest.empty() || placeholder(rest.front())) {
    return std::nullopt;
  }

  const auto end = rest.find_first_of(" \t\r\n\v\f\"',;");
  const auto word = rest.substr(0, end);
  rest.remove_prefix(end == std::string_view::npos ? rest.size() : end);
  return word;
}

inline bool literalValue(std::string_view rest, bool numbers) {
  auto word = nextWord(rest);
  if (!word) {
    return false;
  }

  const auto scheme = lower(*word);
  if (scheme == "bearer" || scheme == "basic" || scheme == "token" || scheme == "digest") {
    word = nextWord(rest);
  }

  if (!word || word->size() < 3) {
    return false;
  }

  const auto text = lower(*word);
  if (text == "true" || text == "false" || text == "null" || text == "none" || text == "undefined") {
    return false;
  }

  return numbers || std::ranges::any_of(*word, [](char byte) { return (byte < '0' || byte > '9') && byte != '.' && byte != '_'; });
}

inline std::optional<std::string_view> finding(std::string_view line) {
  const auto lowered = lower(line);
  if (line.contains("PRIVATE KEY-----")) {
    return "a private key";
  }

  static constexpr auto webhooks = std::to_array<std::string_view>({"hooks.slack.com/services/", "hooks.slack.com/workflows/", "hooks.slack.com/triggers/", "discord.com/api/webhooks/", "discordapp.com/api/webhooks/", ".webhook.office.com/", "outlook.office.com/webhook", "hooks.zapier.com/hooks/", "api.telegram.org/bot", "chat.googleapis.com/v1/spaces/", "ntfy.sh/"});
  if (std::ranges::any_of(webhooks, [&](auto marker) { return lowered.contains(marker); })) {
    return "a webhook URL, whose path is its key";
  }

  static constexpr auto prefixes = std::to_array<std::pair<std::string_view, std::size_t>>({{"ghp_", 20}, {"gho_", 20}, {"ghu_", 20}, {"ghs_", 20}, {"ghr_", 20}, {"github_pat_", 20}, {"glpat-", 20}, {"sk-", 20}, {"xoxb-", 10}, {"xoxp-", 10}, {"xoxa-", 10}, {"xoxr-", 10}, {"xoxs-", 10}, {"AKIA", 16}, {"ASIA", 16}, {"AIza", 30}, {"npm_", 30}, {"pypi-", 30}, {"hf_", 30}, {"r8_", 30}, {"tvly-", 20}});
  for (const auto &[prefix, minimum] : prefixes) {
    for (std::size_t start = 0;;) {
      const auto at = line.find(prefix, start);
      if (at == std::string_view::npos) {
        break;
      }

      start = at + 1;
      if (at != 0 && tokenByte(line[at - 1])) {
        continue;
      }

      auto end = at + prefix.size();
      while (end < line.size() && tokenByte(line[end])) {
        ++end;
      }

      if (end - at - prefix.size() >= minimum) {
        return "a token of a well-known format";
      }
    }
  }

  for (std::size_t start = 0;;) {
    const auto at = lowered.find("bearer", start);
    if (at == std::string::npos) {
      break;
    }

    start = at + 1;
    auto index = at + std::string_view{"bearer"}.size();
    const auto spaces = index;
    while (index < line.size() && (line[index] == ' ' || line[index] == '\t')) {
      ++index;
    }

    if (index == spaces || index == line.size() || placeholder(line[index])) {
      continue;
    }

    const auto begin = index;
    while (index < line.size() && (tokenByte(line[index]) || std::string_view{"._~+/="}.contains(line[index]))) {
      ++index;
    }

    if (index - begin >= 8) {
      return "a bearer token";
    }
  }

  for (std::size_t start = 0;;) {
    const auto at = line.find("://", start);
    if (at == std::string_view::npos) {
      break;
    }

    start = at + 3;
    const auto end = line.find_first_of("/?# \t\"'`<>", start);
    const auto authority = line.substr(start, end == std::string_view::npos ? line.size() - start : end - start);
    const auto sign = authority.rfind('@');
    const auto colon = authority.substr(0, sign).find(':');
    if (sign != std::string_view::npos && colon != std::string_view::npos && colon + 1 < sign && !placeholder(authority[colon + 1])) {
      return "a password inside a URL";
    }
  }

  const bool database = lowered.contains("mysql") || lowered.contains("mariadb");
  auto words = line;
  bool after_user = false;
  while (!words.empty()) {
    words = trim(words, " \t");
    const auto end = words.find_first_of(" \t");
    const auto word = trim(words.substr(0, end), "\"'");
    const auto user_password = [](std::string_view text) {
      const auto colon = text.find(':');
      return colon != std::string_view::npos && colon + 1 < text.size() && !placeholder(text[colon + 1]);
    };
    if (after_user && user_password(word)) {
      return "a password on a command line";
    }

    after_user = word == "-u" || word == "--user";
    if ((word.starts_with("--user=") && user_password(word.substr(7))) || (database && word.starts_with("-p") && word.size() > 2 && !placeholder(word[2]))) {
      return "a password on a command line";
    }

    if (end == std::string_view::npos) {
      break;
    }

    words.remove_prefix(end + 1);
  }

  const auto name_byte = [](char byte) { return tokenByte(byte) || byte == '.'; };
  for (std::size_t index = 0; index < line.size();) {
    if (!name_byte(line[index])) {
      ++index;
      continue;
    }

    const auto begin = index;
    while (index < line.size() && name_byte(line[index])) {
      ++index;
    }

    const auto name = line.substr(begin, index - begin);
    auto cursor = index;
    if (cursor < line.size() && (line[cursor] == '"' || line[cursor] == '\'')) {
      ++cursor;
    }

    while (cursor < line.size() && (line[cursor] == ' ' || line[cursor] == '\t')) {
      ++cursor;
    }

    if (cursor == line.size() || (line[cursor] != '=' && line[cursor] != ':') || line.substr(cursor).starts_with("://")) {
      continue;
    }

    ++cursor;
    if (cursor < line.size() && line[cursor] == '=') {
      continue;
    }

    if (secretName(name) && literalValue(line.substr(cursor), !lower(name).contains("token"))) {
      return "a value assigned to a secret-looking name";
    }
  }

  return std::nullopt;
}

inline std::optional<std::pair<std::size_t, std::string_view>> findSecret(std::string_view bytes) {
  std::size_t number = 1;
  for (;;) {
    const auto end = bytes.find('\n');
    if (const auto found = finding(bytes.substr(0, end))) {
      return std::pair{number, *found};
    }

    if (end == std::string_view::npos) {
      return std::nullopt;
    }

    bytes.remove_prefix(end + 1);
    ++number;
  }
}

}
}

// Interface: window_launch_options.cppm
export {
namespace telar::runtime::cli {

struct WindowOptions {
  std::optional<std::string> config;
  std::optional<std::string> profile;
  std::optional<std::string> theme;
  std::optional<std::string> remote;
  std::optional<std::string> machine;
  bool no_config = false;
  bool fresh = false;
  bool login_shell = false;
  std::vector<std::string> command;

  inline static std::string canonicalTheme(std::string_view name) {
    std::string text{name};
    for (auto &byte : text) {
      if (byte >= 'A' && byte <= 'Z') {
        byte += 'a' - 'A';
      }
    }

    static constexpr auto aliases = std::to_array<std::pair<std::string_view, std::string_view>>({{"osaka-jade", "shade"}, {"osaka_jade", "shade"}, {"osakajade", "shade"}, {"catppuccin-mocha", "catppuccin"}, {"mocha", "catppuccin"}, {"tokyonight", "tokyo-night"}, {"tokyo_night", "tokyo-night"}, {"kanagawa-wave", "kanagawa"}, {"kanagawa_wave", "kanagawa"}, {"kanagawa_dragon", "kanagawa-dragon"}, {"default", "terminal"}});
    for (const auto &[alias, canonical] : aliases) {
      if (text == alias) {
        return std::string{canonical};
      }
    }

    static constexpr auto names = std::to_array<std::string_view>({"shade", "vesper", "catppuccin", "tokyo-night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-dragon", "terminal", "cybervenom"});
    if (std::ranges::find(names, text) == names.end()) {
      throw std::invalid_argument{"UnknownTheme"};
    }

    return text;
  }

  inline static WindowOptions parse(std::span<char *const> input, bool gui = false) {
    constexpr std::size_t maximum_arguments = 64;
    WindowOptions result;
    if (gui && input.size() > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    std::vector<std::string_view> args;
    for (const std::string_view word : input) {
      if (gui && word == "--login-shell") {
        result.login_shell = true;
      } else {
        args.push_back(word);
      }
    }

    std::size_t index = 0;
    for (; index < args.size(); ++index) {
      const auto word = args[index];
      if (word == "--") {
        if (++index == args.size()) {
          throw std::invalid_argument{"MissingCommand"};
        }

        break;
      }

      if (word == "--fresh") {
        if (result.fresh) {
          throw std::invalid_argument{"DuplicateFreshOption"};
        }

        result.fresh = true;
        continue;
      }

      if (word == "--no-config") {
        if (result.no_config || result.config) {
          throw std::invalid_argument{"DuplicateConfigOption"};
        }

        result.no_config = true;
        continue;
      }

      const auto equals = word.find('=');
      const auto flag = word.substr(0, equals);
      std::optional<std::string> *value = nullptr;
      const char *missing = nullptr;
      const char *duplicate = nullptr;
      if (flag == "--config") {
        value = &result.config;
        missing = "MissingConfigPath";
        duplicate = "DuplicateConfigOption";
      } else if (flag == "--profile") {
        value = &result.profile;
        missing = "MissingProfileName";
        duplicate = "DuplicateProfileOption";
      } else if (flag == "--theme") {
        value = &result.theme;
        missing = "MissingThemeName";
        duplicate = "DuplicateThemeOption";
      } else if (flag == "--remote") {
        value = &result.remote;
        missing = "MissingRemoteDestination";
        duplicate = "DuplicateRemoteOption";
      } else if (flag == "--machine") {
        value = &result.machine;
        missing = "MissingMachineLabel";
        duplicate = "DuplicateMachineOption";
      } else {
        break;
      }

      if (*value || (flag == "--config" && result.no_config)) {
        throw std::invalid_argument{duplicate};
      }

      std::string_view text;
      if (equals != std::string_view::npos) {
        text = word.substr(equals + 1);
        if (text.empty() && flag != "--theme") {
          throw std::invalid_argument{missing};
        }
      } else {
        if (++index == args.size()) {
          throw std::invalid_argument{missing};
        }

        text = args[index];
      }

      *value = flag == "--theme" ? canonicalTheme(text) : std::string{text};
    }

    if (args.size() - index > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    for (; index < args.size(); ++index) {
      result.command.emplace_back(args[index]);
    }

    if (result.no_config && result.profile) {
      throw std::invalid_argument{"ProfileWithoutConfig"};
    }

    if (result.fresh && result.remote) {
      throw std::invalid_argument{"FreshWithRemote"};
    }

    if (result.machine && result.remote) {
      throw std::invalid_argument{"MachineWithRemote"};
    }

    return result;
  }
};

}
}

// Interface: window_launch.cppm
export {
namespace telar::runtime::cli {

inline std::string guiProgram() {
  const auto directory = std::filesystem::path{ExecutablePath{}.c_str()}.parent_path();
  for (const auto &candidate : {directory / "telar-gui", directory / ".." / ".." / "MacOS" / "telar-gui"}) {
    struct stat state{};
    if (::stat(candidate.c_str(), &state) == 0 && S_ISREG(state.st_mode) && ::access(candidate.c_str(), X_OK) == 0) {
      return candidate.lexically_normal().string();
    }
  }

  return "telar-gui";
}

inline std::string loginShell() {
  if (const auto *shell = std::getenv("SHELL"); shell && *shell) {
    return shell;
  }

  if (const auto *account = ::getpwuid(::getuid()); account && account->pw_shell) {
    return account->pw_shell;
  }

  return "/bin/sh";
}

inline std::optional<std::string_view> shellScript(const std::string &shell) {
  const auto name = std::filesystem::path{shell}.filename().string();
  if (name == "bash" || name == "zsh" || name == "ksh") {
    return R"(exec -- "$0" "$@")";
  }

  if (name == "sh" || name == "dash") {
    return R"(exec "$0" "$@")";
  }

  if (name == "fish") {
    return "exec $argv";
  }

  return std::nullopt;
}

inline void relaunchLogin(std::span<char *const> words) {
  if (std::getenv("TELAR_LOGIN_SHELL")) {
    return;
  }

  const auto shell = loginShell();
  const auto script = shellScript(shell);
  if (!script) {
    return;
  }

  std::vector<std::string> arguments{shell, "-l", "-c", std::string{*script}, ExecutablePath{}.c_str(), "gui"};
  for (const std::string_view word : words) {
    if (word != "--login-shell") {
      arguments.emplace_back(word);
    }
  }

  ::setenv("TELAR_LOGIN_SHELL", "1", 1);
  launch::replace(arguments);
}

template <Allocator Memory>
int openWindow(Memory &memory, const WindowOptions &options) {
#if defined(__APPLE__)
  const bool display = std::getenv("SSH_CONNECTION") == nullptr && std::getenv("SSH_TTY") == nullptr;
#else
  const auto *wayland = std::getenv("WAYLAND_DISPLAY");
  const bool display = wayland && *wayland;
#endif
  if (!display) {
    std::fputs("telar: no display to open a window here (an SSH login, or Linux without WAYLAND_DISPLAY).\n"
               "From a terminal, reach the panes and agents through the CLI:\n"
               "  telar pane read|watch|send-keys, telar agent prompt, telar --machine LABEL COMMAND\n",
               stderr);
    return 1;
  }

  if (options.machine) {
    try {
      const auto profiles = machine::load(memory, machine::profilesPath());
      if (!profiles.find(*options.machine) && machine::localLabel(profiles) != *options.machine) {
        std::fputs("telar gui: no saved machine or local label has that name; see telar machine list\n", stderr);
        return 1;
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar gui: %s\n", error.what());
      return 1;
    }
  }

  ServerOptions server;
  server.config = options.config ? std::string_view{*options.config} : std::string_view{};
  server.no_config = options.no_config;
  server.profile = options.profile ? std::string_view{*options.profile} : std::string_view{};
  server.fresh = options.fresh;
  const RuntimePaths paths{memory, server, ProcessEnvironment{}};
  std::optional<RuntimeConnection> connection;
  if (connectExisting(connection, paths.socket.c_str()) && options.fresh) {
    std::fprintf(stderr, "telar: a runtime is already running; stop it first (telar server stop) or drop --fresh\n");
    throw CommandError{"RuntimeAlreadyRunning"};
  }

  if (!connection) {
    paths.prepareSocket();
    const auto child = launchDaemon(memory, server, paths, ExecutablePath{runtime_program});
    constexpr auto start_timeout = std::chrono::seconds{10};
    constexpr auto retry_interval = std::chrono::milliseconds{10};
    const auto deadline = std::chrono::steady_clock::now() + start_timeout;
    while (!connectExisting(connection, paths.socket.c_str())) {
      int status = 0;
      if (::waitpid(child, &status, WNOHANG) == child || std::chrono::steady_clock::now() >= deadline) {
        throw CommandError{"RuntimeUnavailable"};
      }

      std::this_thread::sleep_for(retry_interval);
    }
  }

  connection.reset();
  std::vector<std::string> arguments{guiProgram(), "--socket", std::string{paths.socket}, "--cwd", std::filesystem::current_path().string()};
  for (const auto &[flag, value] : std::array<std::pair<std::string_view, const std::optional<std::string> *>, 5>{{{"--config", &options.config}, {"--profile", &options.profile}, {"--theme", &options.theme}, {"--remote", &options.remote}, {"--machine", &options.machine}}}) {
    if (*value) {
      arguments.emplace_back(flag);
      arguments.push_back(**value);
    }
  }

  if (options.no_config) {
    arguments.emplace_back("--no-config");
  }

  if (options.fresh) {
    arguments.emplace_back("--fresh");
  }

  if (!options.command.empty()) {
    arguments.emplace_back("--");
    arguments.insert(arguments.end(), options.command.begin(), options.command.end());
  }

  launch::replace(arguments);
}

}
}
