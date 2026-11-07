module;
#include <stdlib.h>
#include <utility>
#include <memory>
#include <mutex>
#include <new>
#include <bit>

#include <algorithm>
#include <stdexcept>
#include <string>
#include <string_view>

#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <type_traits>
#include <cerrno>
#include <exception>
#include <charconv>
#include <unistd.h>
#include <format>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <sys/types.h>
#include <limits.h>
#include <atomic>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>

#include <cstdlib>

#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <variant>
#include <cstdio>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#include <fcntl.h>
#include <sys/stat.h>
#include <concepts>
#include <csignal>
#include <dirent.h>
#include <spawn.h>
#include <thread>
#include <filesystem>
#include <pwd.h>

#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif

#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <vector>

export module telar.cli.worktree_git;

export import telar.cli.command_limit;

export import telar.platform;


export import telar.cli.runtime_observer;
export import telar.cli.output;
export import telar.cli.server;


export import telar.base.memory;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: repository_identity.cppm
export {
namespace telar::runtime::cli::repository {

inline std::string asciiLower(std::string_view text) {
  std::string result{text};
  for (auto &byte : result) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }

  return result;
}

inline std::string_view trim(std::string_view text, std::string_view characters) {
  const auto first = text.find_first_not_of(characters);
  if (first == text.npos) {
    return {};
  }

  const auto last = text.find_last_not_of(characters);
  return text.substr(first, last - first + 1);
}

inline std::string normalize(std::string_view url) {
  url = trim(url, " \t\r\n");
  std::string_view scheme = "ssh";
  std::string_view authority;
  std::string_view path;
  const auto separator = url.find("://");
  if (separator != url.npos) {
    scheme = url.substr(0, separator);
    const auto rest = url.substr(separator + std::string_view{"://"}.size());
    const auto slash = rest.find('/');
    if (asciiLower(scheme) == "file" || slash == rest.npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    authority = rest.substr(0, slash);
    path = rest.substr(slash);
  } else {
    const auto colon = url.find(':');
    if (colon == url.npos || url.substr(0, colon).contains('/')) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    authority = url.substr(0, colon);
    path = url.substr(colon + 1);
  }

  const auto at = authority.rfind('@');
  auto host = authority.substr(at == authority.npos ? 0 : at + 1);
  std::size_t colon;
  if (host.starts_with('[')) {
    const auto close = host.find(']');
    if (close == host.npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    colon = close + 1;
    if (colon == host.size()) {
      host = host.substr(1, close - 1);
      colon = host.npos;
    }
  } else {
    colon = host.find(':');
  }

  if (colon != host.npos && colon < host.size()) {
    const auto port = host.substr(colon + 1);
    const auto lower_scheme = asciiLower(scheme);
    if ((lower_scheme == "ssh" && port == "22") || (lower_scheme == "https" && port == "443") || (lower_scheme == "http" && port == "80")) {
      host = host.starts_with('[') ? host.substr(1, colon - 2) : host.substr(0, colon);
    }
  }

  path = trim(path, "/");
  constexpr std::string_view suffix = ".git";
  if (path.ends_with(suffix)) {
    path.remove_suffix(suffix.size());
    while (path.ends_with('/')) {
      path.remove_suffix(1);
    }
  }

  if (host.empty() || path.empty()) {
    throw std::runtime_error{"UnsupportedOrigin"};
  }

  constexpr std::size_t max_identity_bytes = 2048;
  if (host.size() + 1 + path.size() > max_identity_bytes) {
    throw std::runtime_error{"OriginTooLong"};
  }

  return asciiLower(host) + '/' + std::string{path};
}

inline std::string sanitized(std::string_view origin) {
  if (origin.find_first_of("?#\r\n\t ") != origin.npos) {
    throw std::runtime_error{"UnsupportedOrigin"};
  }

  const auto separator = origin.find("://");
  if (separator != origin.npos) {
    const auto start = separator + std::string_view{"://"}.size();
    const auto slash = origin.find('/', start);
    if (slash == origin.npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    const auto authority = origin.substr(start, slash - start);
    const auto at = authority.rfind('@');
    if (at != authority.npos && !(asciiLower(origin.substr(0, separator)) == "ssh" && !authority.substr(0, at).contains(':'))) {
      return std::string{origin.substr(0, start)} + std::string{origin.substr(start + at + 1)};
    }
  }

  return std::string{origin};
}

}
}

// Interface: repository_git.cppm
export {
namespace telar::runtime::cli::repository {

inline constexpr std::size_t max_git_output = 8 * 1024 * 1024;
inline constexpr std::size_t max_bundle_bytes = 256 * 1024 * 1024;
inline constexpr std::chrono::seconds git_timeout{600};

template <Allocator Memory>
class Git {
public:
  inline Git(Memory &memory, std::string_view root)
      : memory_(memory),
        root_(root) {
    auto [status, listing] = execute({"config", "--show-scope", "-z", "--get-regexp", "^(filter\\.|extensions\\.partialclone$|remote\\..*\\.(promisor|partialclonefilter|uploadpack)$)"}, false);
    const auto facts = GitRepositoryFacts::parse(listing);
    if (status > 1 || !facts) {
      throw std::runtime_error{"GitFailed"};
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto suffix : {".clean=", ".smudge=", ".process="}) {
        overrides_.push_back("filter." + std::string{facts->drivers[index]} + suffix);
      }
    }

    if (facts->may_fetch) {
      const auto version = read({"version"});
      constexpr std::string_view prefix = "git version ";
      unsigned major = 0;
      unsigned minor = 0;
      if (!version.starts_with(prefix) || std::sscanf(version.c_str() + prefix.size(), "%u.%u", &major, &minor) != 2 || major < 2 || (major == 2 && minor < 45)) {
        throw std::runtime_error{"GitFailed"};
      }
    }
  }

  inline std::string read(std::initializer_list<std::string_view> arguments) {
    auto [status, output] = execute(arguments, true);
    if (status != 0) {
      throw std::runtime_error{"GitFailed"};
    }

    return std::string{trim(output, " \r\n")};
  }

  inline void bundle(std::string_view ref, int descriptor) {
    const std::array args{std::string_view{"bundle"}, std::string_view{"create"}, std::string_view{"-"}, ref};
    auto command = makeCommand(args);
    configure(command);
    CommandOutput output{memory_, max_git_output};
    std::size_t total = 0;
    const auto status = output.stream(command, std::chrono::steady_clock::now() + git_timeout, [&](std::span<const Byte> bytes) {
      total += bytes.size();
      if (total > max_bundle_bytes) {
        reportCommandLimit({.name = "repository.max_bundle_bytes", .noun = "bytes", .value = max_bundle_bytes, .requested = total});
        throw std::runtime_error{"RepositoryBundleLimit"};
      }

      writeBytes(descriptor, bytes);
      return true;
    });
    if (status != 0) {
      throw std::runtime_error{"GitFailed"};
    }
  }

private:
  inline Command<Memory> makeCommand(std::span<const std::string_view> arguments) {
    std::vector<std::string_view> complete(git_observation_options.begin(), git_observation_options.end());
    for (const auto &value : overrides_) {
      complete.push_back("-c");
      complete.push_back(value);
    }

    complete.insert(complete.end(), arguments.begin(), arguments.end());
    return Command<Memory>{memory_, Launch{.cwd = root_, .arguments = complete}, CommandPurpose::administration};
  }

  inline std::pair<int, std::string> execute(std::initializer_list<std::string_view> arguments, bool bounded) {
    auto command = makeCommand(std::span{arguments.begin(), arguments.size()});
    configure(command);
    constexpr std::size_t max_configuration_bytes = 64 * 1024;
    CommandOutput output{memory_, bounded ? max_git_output : max_configuration_bytes};
    const auto status = output.run(command, std::chrono::steady_clock::now() + git_timeout, true);
    if (output.truncated()) {
      if (bounded) {
        reportCommandLimit({.name = "repository.max_git_output_bytes", .noun = "bytes", .value = max_git_output});
      }

      throw std::runtime_error{bounded ? "RepositoryGitOutputLimit" : "GitFailed"};
    }

    return {status, std::string{output.text()}};
  }

  inline static void configure(Command<Memory> &command) {
    command.removeEnvironmentPrefix("GIT_");
    command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
    command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
    command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    command.setEnvironment("LC_ALL", "C");
  }

  Memory &memory_;
  std::string root_;
  std::vector<std::string> overrides_;
};

template <Allocator Memory>
void ready(Git<Memory> &git, std::string_view commit) {
  if (git.read({"rev-parse", "--is-shallow-repository"}) != "false") {
    throw std::runtime_error{"ShallowRepositoryUnsupported"};
  }

  const auto config = git.read({"config", "--local", "--name-only", "--list"});
  if (config.contains("extensions.partialclone") || config.contains(".promisor")) {
    throw std::runtime_error{"PartialRepositoryUnsupported"};
  }

  const auto tree = git.read({"ls-tree", "-rz", commit});
  std::string_view remaining = tree;
  while (!remaining.empty()) {
    const auto end = remaining.find('\0');
    const auto line = remaining.substr(0, end);
    if (line.starts_with("160000 ")) {
      throw std::runtime_error{"SubmoduleRepositoryUnsupported"};
    }

    const auto tab = line.find('\t');
    if (tab != line.npos) {
      const auto name = line.substr(tab + 1);
      if (name == ".gitattributes" || name.ends_with("/.gitattributes")) {
        const auto space = line.rfind(' ', tab);
        if (space == line.npos) {
          throw std::runtime_error{"InvalidGitTree"};
        }

        const auto attributes = git.read({"cat-file", "blob", line.substr(space + 1, tab - space - 1)});
        if (attributes.contains("filter=lfs") || attributes.contains("filter = lfs")) {
          throw std::runtime_error{"LfsRepositoryUnsupported"};
        }
      }
    }

    if (end == remaining.npos) {
      break;
    }

    remaining.remove_prefix(end + 1);
  }

  git.read({"fsck", "--connectivity-only", "--no-reflogs", commit});
}

}
}

// Interface: session_arguments.cppm
export {
namespace telar::runtime::cli::sessions {

inline constexpr std::size_t workspace_name_bytes = 256;
inline constexpr std::size_t tab_label_bytes = 128;
inline constexpr std::size_t branch_bytes = 200;
inline constexpr std::size_t title_bytes = 96;
inline constexpr std::size_t brief_bytes = 512;
inline constexpr std::size_t command_words = 32;
inline constexpr std::size_t workspace_command_words = 64;
inline constexpr unsigned default_wait_seconds = 600;
inline constexpr unsigned max_wait_seconds = 86400;
inline constexpr TerminalSize launch_size{.cols = 160, .rows = 48};
inline constexpr TerminalSize workspace_size{.cols = 80, .rows = 24};

inline void text(std::string_view value, std::size_t maximum, const char *error, bool empty = false) {
  try {
    validateUtf8(value);
  } catch (const EncodingError &) {
    usage(error);
  }

  if ((!empty && value.empty()) || value.size() > maximum) {
    usage(error);
  }
}

inline void printable(std::string_view value, std::size_t maximum) {
  text(value, maximum, "InvalidWorktreeText");
  for (const unsigned char byte : value) {
    if (byte < ' ' || byte == 0x7f) {
      usage("InvalidWorktreeText");
    }
  }
}

inline void branch(std::string_view value) {
  text(value, branch_bytes, "InvalidWorktreeBranch");
  if (value.front() == '-' || value.front() == '.' || value.contains("..")) {
    usage("InvalidWorktreeBranch");
  }

  for (const unsigned char byte : value) {
    if (byte <= ' ' || byte == 0x7f || byte == '~' || byte == '^' || byte == ':') {
      usage("InvalidWorktreeBranch");
    }
  }
}

inline void single(std::optional<std::string_view> &field, std::string_view value, const char *error) {
  if (field) {
    usage(error);
  }

  field = value;
}

struct Target {
  std::optional<std::uint64_t> id{};

  inline static Target parse(std::string_view value) {
    return {.id = value == "--current" ? std::nullopt : std::optional{positive(value, "InvalidIdentity")}};
  }

  inline std::uint64_t resolve(const char *variable) const {
    if (id) {
      return *id;
    }

    const auto value = ::getenv(variable);
    if (!value) {
      throw std::runtime_error{"MissingCurrentIdentity"};
    }

    const auto number = maybeUnsigned(value);
    if (!number || *number == 0) {
      throw std::runtime_error{"InvalidIdentity"};
    }

    return *number;
  }
};

struct WorkspaceOptions {
  enum class Action {
    create,
    list,
    get,
    rename,
    select
  };
  Action action{};
  Target target{};
  std::optional<std::string_view> name{}, directory{}, worktree{}, socket{};
  Arguments command{};
  std::optional<std::uint16_t> columns{};
  bool json = false;

  inline static WorkspaceOptions parse(Arguments words) {
    if (words.empty()) {
      usage("MissingWorkspaceAction");
    }

    WorkspaceOptions self;
    const std::string_view verb = words[0];
    if (verb == "create") {
      self.action = Action::create;
    } else if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "get") {
      self.action = Action::get;
    } else if (verb == "rename") {
      self.action = Action::rename;
    } else {
      usage("UnknownWorkspaceAction");
    }

    Cursor cursor{words.subspan(1)};
    if (self.action == Action::get || self.action == Action::rename) {
      self.target = Target::parse(cursor.take("MissingWorkspaceTarget"));
    }

    if (self.action == Action::rename) {
      self.name = cursor.take("MissingWorkspaceName");
      text(*self.name, workspace_name_bytes, "InvalidWorkspaceName");
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--" && self.action == Action::create) {
        self.command = cursor.rest();
        if (self.command.empty()) {
          usage("MissingWorkspaceCommand");
        }
        break;
      } else if (arg == "--columns" && self.action == Action::create) {
        const auto value = maybeUnsigned(cursor.take("MissingWorkspaceColumns"));
        constexpr unsigned minimum_columns = 20, maximum_columns = 1024;
        if (!value || *value < minimum_columns || *value > maximum_columns) {
          usage("InvalidWorkspaceColumns");
        }
        self.columns = static_cast<std::uint16_t>(*value);
      } else if (arg == "--worktree" && self.action == Action::create) {
        const auto value = cursor.take("MissingWorktreeBranch");
        single(self.worktree, value, "DuplicateWorktreeOption");
        branch(value);
      } else if (arg == "--name" && self.action == Action::create) {
        single(self.name, cursor.take("MissingWorkspaceName"), "DuplicateNameOption");
      } else if (arg == "--directory" && self.action == Action::create) {
        single(self.directory, cursor.take("MissingWorktreeDirectory"), "DuplicateDirectoryOption");
      } else if (arg == "--socket") {
        single(self.socket, cursor.take("MissingSocketPath"), "DuplicateSocketOption");
      } else if (arg == "--json") {
        self.json = true;
      } else {
        usage("UnknownWorkspaceOption");
      }
    }

    if (self.action == Action::create && !self.worktree && !self.directory) {
      usage("MissingWorktreeBranch");
    }
    if (self.worktree && (!self.command.empty() || self.columns)) {
      usage("UnknownWorkspaceOption");
    }
    if (self.directory && self.directory->empty()) {
      usage("EmptyWorkspaceDirectory");
    }
    return self;
  }
};

struct TabOptions {
  enum class Action {
    list,
    get,
    create,
    rename,
    close,
    move
  };
  Action action{};
  Target workspace{}, target{};
  std::optional<std::string_view> label{}, socket{};
  TabMoveDirection direction{};
  std::optional<std::uint64_t> relative{};
  bool background = false, json = false;

  inline static TabOptions parse(Arguments words) {
    if (words.empty()) {
      usage("MissingTabAction");
    }

    TabOptions self;
    const std::string_view verb = words[0];
    if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "get") {
      self.action = Action::get;
    } else if (verb == "create") {
      self.action = Action::create;
    } else if (verb == "rename") {
      self.action = Action::rename;
    } else if (verb == "close") {
      self.action = Action::close;
    } else if (verb == "move") {
      self.action = Action::move;
    } else {
      usage("UnknownTabAction");
    }

    Cursor cursor{words.subspan(1)};
    if (self.action != Action::list && self.action != Action::create) {
      self.target = Target::parse(cursor.take("MissingTabTarget"));
    }

    if (self.action == Action::rename) {
      self.label = cursor.take("MissingTabLabel");
      text(*self.label, tab_label_bytes, "InvalidTabLabel");
    }

    if (self.action == Action::move) {
      const auto direction = cursor.take("MissingMoveDirection");
      if (direction == "previous") {
        self.direction = TabMoveDirection::previous;
      } else if (direction == "next") {
        self.direction = TabMoveDirection::next;
      } else {
        usage("InvalidMoveDirection");
      }
    }

    bool workspace_seen = false;
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--relative-to" && self.action == Action::move) {
        if (self.relative) {
          usage("DuplicateRelativeTarget");
        }
        const auto target = Target::parse(cursor.take("MissingRelativeTarget"));
        if (!target.id) {
          usage("InvalidRelativeTarget");
        }
        self.relative = target.id;
      } else if (arg == "--background" && self.action == Action::create) {
        if (self.background) {
          usage("DuplicateBackgroundOption");
        }
        self.background = true;
      } else if (arg == "--label" && self.action == Action::create) {
        if (self.label) {
          usage("DuplicateLabelOption");
        }
        self.label = cursor.take("MissingTabLabel");
        text(*self.label, tab_label_bytes, "InvalidTabLabel", true);
      } else if (arg == "--workspace") {
        if (workspace_seen) {
          usage("DuplicateWorkspaceOption");
        }
        self.workspace = Target::parse(cursor.take("MissingWorkspaceTarget"));
        workspace_seen = true;
      } else if (arg == "--socket") {
        if (self.socket) {
          usage("DuplicateSocketOption");
        }
        self.socket = cursor.take("MissingSocketPath");
      } else if (arg == "--json") {
        if (self.json) {
          usage("DuplicateJsonOption");
        }
        self.json = true;
      } else {
        usage("UnknownTabOption");
      }
    }

    if (self.action == Action::create && !self.background) {
      usage("MissingClientId");
    }
    return self;
  }
};

}
}

// Interface: session_channel.cppm
export {
namespace telar::runtime::cli::sessions {


inline std::string realDirectory(std::string_view path) {
  std::error_code error;
  auto resolved = std::filesystem::canonical(path, error);
  if (error) {
    throw Failure{error == std::errc::no_such_file_or_directory ? "FileNotFound" : error == std::errc::not_a_directory ? "NotDir"
                                                                                                                       : "AccessDenied"};
  }

  if (!std::filesystem::is_directory(resolved, error)) {
    throw Failure{"NotDir"};
  }

  return resolved.string();
}

inline std::string_view loginShell() {
  if (const auto shell = ::getenv("SHELL"); shell && *shell) {
    return shell;
  }

  if (const auto entry = ::getpwuid(::getuid()); entry && entry->pw_shell && *entry->pw_shell) {
    return entry->pw_shell;
  }

  return "/bin/sh";
}

inline void wireTabLabel(std::string_view value, bool empty = false) {
  if ((!empty && value.empty()) || value.size() > tab_label_bytes) {
    throw Failure{"InvalidByteString"};
  }
  try {
    validateUtf8(value);
  } catch (const EncodingError &) {
    throw Failure{"InvalidUtf8"};
  }
  for (const unsigned char byte : value) {
    if (byte < ' ' || byte == 0x7f) {
      throw Failure{"InvalidTabLabel"};
    }
  }
}

// Catalog subscriptions also carry unrelated broadcasts. Keep them on a separate
// connection from exchanges. The protocol is ControlSession's; Channel adds
// the sessions commands' runtime start and their descriptions of failures.
template <Allocator Memory>
class Channel {
public:
  inline Channel(Memory &memory, std::optional<std::string_view> socket, bool start)
      : paths_(memory, socketOptions(socket), ProcessEnvironment{}) {
    std::optional<RuntimeConnection> probe;
    if (start && !connectExisting(probe, paths_.socket.c_str()) && startRuntime(memory, socketOptions(socket), paths_) != RuntimeStart::listening) {
      throw Failure{"the local runtime is not reachable"};
    }

    try {
      session_.emplace(memory, paths_.socket.c_str());
    } catch (const SystemError &error) {
      throw Failure{connectionFailure(error.code())};
    }

    session_->receiveTimeout(reply_timeout_seconds);
  }

  // `reason` reports the runtime's own words for a refusal; otherwise the
  // refusal's generic description.
  template <typename Reply, typename Request>
  inline Reply exchange(Request request, bool reason = true) {
    return translated([&] { return session_->template exchange<Reply>(request); }, reason);
  }

  inline WorkspaceList catalog() {
    return translated([&] {
      session_->send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false});
      return session_->template receive<WorkspaceList>();
    });
  }

  inline const char *socket() const {
    return paths_.socket.c_str();
  }

private:
  inline static ServerOptions socketOptions(std::optional<std::string_view> socket) {
    ServerOptions options;
    options.socket = socket.value_or("");
    return options;
  }

  inline static const char *connectionFailure(int code) noexcept {
    switch (code) {
    case ENOENT:
      return "FileNotFound";
    case ECONNREFUSED:
      return "ConnectionRefused";
    case EACCES:
      return "PermissionDenied";
    case ENOTDIR:
      return "NotDir";
    case ELOOP:
      return "SymLinkLoop";
    case ENAMETOOLONG:
      return "NameTooLong";
    default:
      return "the local runtime is not reachable";
    }
  }

  template <typename Operation>
  inline static auto translated(Operation &&operation, bool reason = true) {
    try {
      return operation();
    } catch (const ControlFailure &failure) {
      throw Failure{reason ? failure.message() : std::string_view{controlFailureDescription(failure.code())}, 1, failure.code()};
    } catch (const SocketError &) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        throw Failure{"RuntimeTimeout", 3};
      }

      throw Failure{"unexpected reply from the runtime"};
    } catch (const EncodingError &) {
      throw Failure{"unexpected reply from the runtime"};
    } catch (const std::runtime_error &error) {
      if (std::string_view{error.what()} == "RuntimeStopping") {
        throw Failure{"RuntimeStopping"};
      }

      throw;
    }
  }

  static constexpr unsigned reply_timeout_seconds = 30;
  RuntimePaths<Memory> paths_;
  std::optional<ControlSession<Memory>> session_;
};


inline void checkLocation(TabLocation actual, TabLocation expected) {
  if (actual.workspace.kind != expected.workspace.kind || actual.workspace.id != expected.workspace.id || actual.tab_id != expected.tab_id) {
    throw Failure{"unexpected reply from the runtime"};
  }
}

inline ClientDescriptor chooseClient(std::span<const ClientDescriptor> clients, std::uint64_t wanted) {
  std::optional<ClientDescriptor> chosen;
  for (const auto &client : clients) {
    if (wanted != 0) {
      if (client.id == wanted) {
        return client;
      }
      continue;
    }

    if (!chosen || client.last_input_sequence > chosen->last_input_sequence) {
      chosen = client;
    }
  }

  if (!chosen) {
    throw Failure{"ClientNotFound", 2};
  }
  return *chosen;
}

}
}

// Interface: workspace.cppm
export {
namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void workspaceEntry(Output<Memory> &output, const WorkspaceListEntry &entry, bool json) {
  if (json) {
    output.text("{\"workspace_id\":").number(entry.workspace).text(",\"name\":").json(entry.name).text(",\"path\":").json(entry.path).text(",\"tab_count\":").number(entry.tab_count).text(",\"branch\":").json(entry.branch).text(",\"dirty\":").boolean(entry.dirty).text("}");
  } else {
    output.number(entry.workspace).text("\t").text(entry.name).text("\t").text(entry.path).text("\t").number(entry.tab_count).text("\t").text(entry.branch).text("\t").text(entry.dirty ? "dirty" : "clean").text("\n");
  }
}

template <Allocator Memory>
int workspace(Memory &memory, const WorkspaceOptions &options) {
  try {
    using Action = WorkspaceOptions::Action;
    Output output{memory};
    if (options.action == Action::create) {
      const auto directory = realDirectory(*options.directory);
      const auto default_name = std::filesystem::path{directory}.filename().string();
      const auto name = options.name.value_or(default_name);
      if (name.empty()) {
        throw Failure{"MissingWorkspaceName"};
      }
      if (options.command.size() > workspace_command_words) {
        throw Failure{"WorkspaceCommandTooLong"};
      }

      std::array<std::string_view, workspace_command_words> command;
      std::size_t count = 0;
      for (const auto word : options.command) {
        command[count++] = word;
      }
      if (count == 0) {
        const auto configured = ::getenv("SHELL");
        command[count++] = configured && *configured ? configured : "/bin/sh";
      }

      auto size = workspace_size;
      size.cols = options.columns.value_or(size.cols);
      Channel session{memory, options.socket, true};
      wireTabLabel(name);
      const auto opened = session.template exchange<PaneOpened>(CreateWorkspace{.size = size, .name = name, .launch = {.cwd = directory, .arguments = std::span{command}.first(count)}}, false);
      if (options.json) {
        output.text("{\"workspace_id\":").number(opened.location.workspace.id).text(",\"tab_id\":").number(opened.location.tab_id).text(",\"pane_id\":").number(opened.pane_id).text(",\"directory\":").json(directory, JsonEscapes::control).text("}\n");
      } else {
        output.text("workspace ").number(opened.location.workspace.id).text(" created at ").text(directory).text("\n");
      }
    } else if (options.action == Action::rename) {
      const auto id = options.target.resolve("TELAR_WORKSPACE_ID");
      Channel session{memory, options.socket, false};
      wireTabLabel(*options.name);
      const auto reply = session.template exchange<WorkspaceSnapshot>(RenameWorkspace{.workspace = {.id = id}, .name = *options.name}, false);
      if (reply.workspace.kind != WorkspaceLocation::Kind::workspace || reply.workspace.id != id) {
        throw Failure{"unexpected reply from the runtime"};
      }
      if (options.json) {
        output.text("{\"workspace_id\":").number(id).text(",\"name\":").json(reply.name).text("}\n");
      } else {
        output.text("workspace ").number(id).text(" renamed to ").text(reply.name).text("\n");
      }
    } else {
      const auto wanted = options.action == Action::get ? std::optional{options.target.resolve("TELAR_WORKSPACE_ID")} : std::nullopt;
      Channel session{memory, options.socket, false};
      const auto catalog = session.catalog();
      if (!wanted) {
        output.text(options.json ? "[" : "ID\tNAME\tDIRECTORY\tTABS\tBRANCH\tGIT\n");
      }
      bool first = true;
      for (const auto &entry : catalog.entries) {
        if (wanted && entry.workspace != *wanted) {
          continue;
        }
        if (options.json && !first) {
          output.text(",");
        }
        workspaceEntry(output, entry, options.json);
        first = false;
      }

      if (wanted && first) {
        throw Failure{"workspace not found"};
      }
      if (options.json) {
        output.text(wanted ? "\n" : "]\n");
      }
    }

    output.flush();
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar workspace: %s\n", error.what());
    return 1;
  }
}

}
}

// Interface: worktree_git.cppm
export {
namespace telar::runtime::cli::sessions {

struct GitWorktree {
  std::string path, branch;
};

template <Allocator Memory>
class WorktreeGit {
public:
  inline explicit WorktreeGit(Memory &memory)
      : memory_(memory) {}

  // Mutations retain only the tail of diagnostics; diff streams both byte
  // streams. Every invocation uses literal argv and a bounded deadline.
  inline std::string run(std::span<const std::string_view> arguments, const char *failure = "NotARepository", bool stream = false, bool hardened = false, std::span<const std::pair<std::string_view, std::string_view>> environment = {}) {
    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::configured_helper};
    for (const auto &[name, value] : environment) {
      command.setEnvironment(name, value);
    }

    if (hardened) {
      command.removeEnvironmentPrefix("GIT_");
      command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
      command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
      command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    }
    constexpr std::size_t diagnostic_bytes = 64 * 1024;
    constexpr std::size_t listing_bytes = 1024 * 1024;
    constexpr unsigned git_timeout_seconds = 300;
    RetainedStream diagnostics{memory_, diagnostic_bytes};
    CommandOutput output{memory_, listing_bytes};
    std::string kept;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{git_timeout_seconds};
    const auto status = output.streamDiagnostics(command, deadline, [&](std::span<const Byte> bytes) {
      if (stream) { std::fwrite(bytes.data(), 1, bytes.size(), stdout); }
      else {
        if (bytes.size() > listing_bytes - kept.size()) { throw Failure{"StreamTooLong"}; }
        kept.append(reinterpret_cast<const char *>(bytes.data()), bytes.size());
      }
      return true; }, [&](std::span<const Byte> bytes) {
      if (stream) { std::fwrite(bytes.data(), 1, bytes.size(), stderr); }
      else { diagnostics.append(bytes); } });

    if (status != 0) {
      if (std::string_view{failure} != "NotARepository" && !stream) {
        std::array<Byte, diagnostic_bytes> bytes;
        const auto tail = diagnostics.read(diagnostics.retainedOffset(), bytes);
        if (diagnostics.retainedOffset() != 0) {
          std::fprintf(stderr, "(%llu earlier bytes of Git's output omitted)\n", static_cast<unsigned long long>(diagnostics.retainedOffset()));
        }
        std::fwrite(tail.data(), 1, tail.size(), stderr);
      }
      throw Failure{failure};
    }

    return kept;
  }

  inline std::string run(std::initializer_list<std::string_view> arguments, const char *failure = "NotARepository", bool stream = false, bool hardened = false) {
    return run(std::span{arguments.begin(), arguments.size()}, failure, stream, hardened);
  }

  inline std::string line(std::initializer_list<std::string_view> arguments, bool hardened = false) {
    auto value = run(arguments, "NotARepository", false, hardened);
    const auto start = value.find_first_not_of(" \r\n"), end = value.find_last_not_of(" \r\n");
    if (start == std::string::npos) {
      throw Failure{"NotARepository"};
    }
    return value.substr(start, end - start + 1);
  }

  inline std::string root(std::string_view directory) {
    auto common = line({"git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"});
    while (common.ends_with('/')) {
      common.pop_back();
    }
    constexpr std::string_view suffix = "/.git";
    if (!common.starts_with('/') || !common.ends_with(suffix) || common.size() <= suffix.size()) {
      throw Failure{"not inside a git repository"};
    }
    common.resize(common.size() - suffix.size());
    return common;
  }

  inline std::string currentBranch(std::string_view directory) {
    return line({"git", "-C", directory, "rev-parse", "--abbrev-ref", "HEAD"});
  }

  inline bool succeeds(std::initializer_list<std::string_view> arguments, bool hardened = false) {
    try {
      run(arguments, "NotARepository", false, hardened);
      return true;
    } catch (const std::exception &) {
      return false;
    }
  }

  inline void add(std::string_view root, std::string_view directory, std::string_view branch, std::string_view base) {
    const auto reference = "refs/heads/" + std::string{branch};
    if (succeeds({"git", "-C", root, "rev-parse", "--verify", "--quiet", reference})) {
      run({"git", "-C", root, "worktree", "add", "--", directory, branch}, "git worktree add failed");
    } else {
      run({"git", "-C", root, "worktree", "add", "-b", branch, "--", directory, base}, "git worktree add failed");
    }
  }

  template <typename Keep>
  inline std::vector<GitWorktree> listed(std::string_view directory, Keep &&keep) {
    const auto main = root(directory);
    const auto bytes = run({"git", "-C", main, "worktree", "list", "--porcelain"});
    std::vector<GitWorktree> result;
    std::string_view path, branch;
    constexpr std::size_t maximum_untracked = 256;
    bool first = true;
    std::string_view remaining = bytes;
    while (!remaining.empty()) {
      const auto end = remaining.find('\n');
      const auto line = remaining.substr(0, end);
      remaining.remove_prefix(end == std::string_view::npos ? remaining.size() : end + 1);
      if (line.starts_with("worktree ")) {
        path = line.substr(std::string_view{"worktree "}.size());
      } else if (line.starts_with("branch refs/heads/")) {
        branch = line.substr(std::string_view{"branch refs/heads/"}.size());
      } else if (line.empty()) {
        if (!first && !path.empty() && !branch.empty() && keep(path) && result.size() < maximum_untracked) {
          result.push_back(GitWorktree{.path = std::string{path}, .branch = std::string{branch}});
        }
        first = false;
        path = {};
        branch = {};
      }
    }

    return result;
  }

  // Zig's merge check runs through its untrusted Git: hooks, filters and lazy
  // fetches off. A clone that could still fetch lazily, on a Git too old to
  // switch that off, counts as not merged and asks a person.
  inline bool merged(std::string_view root, std::string_view branch) {
    try {
      repository::Git git{memory_, root};
      std::string against = "HEAD";
      try {
        against = git.read({"rev-parse", "--verify", "--quiet", "--end-of-options", std::string{branch} + "@{upstream}"});
      } catch (const std::exception &) {
      }

      git.read({"merge-base", "--is-ancestor", "refs/heads/" + std::string{branch}, against});
      return true;
    } catch (const std::exception &) {
      return false;
    }
  }


private:
  Memory &memory_;
};


}
}

// Interface: worktree_options.cppm
export {
namespace telar::runtime::cli::sessions {

inline constexpr std::size_t machine_label_bytes = 32;

inline CoordinatorReference coordinatorReference(std::string_view value) {
  constexpr std::size_t session_hex_bytes = 32;
  if (value.size() <= session_hex_bytes || value[session_hex_bytes] != ':') {
    usage("InvalidCoordinatorReference");
  }
  CoordinatorReference result;
  bool nonzero = false;
  for (std::size_t index = 0; index < result.session_id.size(); ++index) {
    unsigned byte{};
    const auto begin = value.data() + index * 2;
    const auto parsed = std::from_chars(begin, begin + 2, byte, 16);
    if (parsed.ec != std::errc{} || parsed.ptr != begin + 2) {
      usage("InvalidCoordinatorReference");
    }
    result.session_id[index] = static_cast<Byte>(byte);
    nonzero |= byte != 0;
  }

  value.remove_prefix(session_hex_bytes + 1);
  const auto colon = value.find(':');
  if (colon == std::string_view::npos || !nonzero) {
    usage("InvalidCoordinatorReference");
  }
  result.pane_id = positive(value.substr(0, colon), "InvalidCoordinatorReference");
  result.pane_generation = positive(value.substr(colon + 1), "InvalidCoordinatorReference");
  return result;
}

inline void machineLabel(std::string_view value) {
  const auto alphanumeric = [](unsigned char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9'); };
  if (value.empty() || value.size() > machine_label_bytes || !alphanumeric(value.front())) {
    usage("InvalidMachineLabel");
  }
  for (const auto byte : value) {
    if (!alphanumeric(byte) && byte != '-' && byte != '_' && byte != '.') {
      usage("InvalidMachineLabel");
    }
  }
}

struct WorktreeOptions {
  enum class Action {
    create,
    exec,
    list,
    open,
    diff,
    remove,
    fetch,
    resolve
  };
  Action action{};
  std::optional<std::string_view> branch{}, title{}, from{}, label{}, workspace{}, directory{}, machine{}, dispatched_from{}, repository{}, socket{};
  std::optional<CoordinatorReference> coordinator{};
  Arguments command{};
  std::uint64_t client = 0;
  unsigned timeout = default_wait_seconds;
  bool json = false, setup = false, uncommitted = false, stat = false, force = false, delete_branch = false, wait = false;

  inline static WorktreeOptions parse(Arguments words) {
    if (words.empty()) {
      usage("MissingWorktreeAction");
    }
    WorktreeOptions self;
    const std::string_view verb = words.front();
    if (verb == "create") {
      self.action = Action::create;
    } else if (verb == "exec") {
      self.action = Action::exec;
    } else if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "open") {
      self.action = Action::open;
    } else if (verb == "diff") {
      self.action = Action::diff;
    } else if (verb == "remove") {
      self.action = Action::remove;
    } else if (verb == "fetch") {
      self.action = Action::fetch;
    } else if (verb == "resolve") {
      self.action = Action::resolve;
    } else {
      usage("UnknownWorktreeAction");
    }

    Cursor cursor{words.subspan(1)};
    if (self.action != Action::list && self.action != Action::resolve) {
      const auto value = cursor.take("MissingWorktreeBranch");
      if (value.starts_with('-')) {
        usage("MissingWorktreeBranch");
      }
      if (self.action == Action::create || self.action == Action::fetch) {
        sessions::branch(value);
      } else {
        printable(value, branch_bytes);
      }
      self.branch = value;
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--") {
        if (self.action != Action::create && self.action != Action::exec) {
          usage("UnexpectedWorktreeCommand");
        }
        self.command = cursor.rest();
        if (self.command.empty()) {
          usage("MissingWorktreeCommand");
        }
        if (self.command.size() > command_words) {
          usage("TooManyCommandArguments");
        }
        break;
      } else if (arg == "--setup" && self.action == Action::create) {
        self.setup = true;
      } else if (arg == "--title" && self.action == Action::create) {
        single(self.title, cursor.take("MissingWorktreeTitle"), "DuplicateWorktreeOption");
        printable(*self.title, title_bytes);
      } else if (arg == "--from" && self.action == Action::create) {
        single(self.from, cursor.take("MissingWorktreeBase"), "DuplicateWorktreeOption");
        sessions::branch(*self.from);
      } else if (arg == "--directory" && self.action == Action::create) {
        single(self.directory, cursor.take("MissingWorktreeDirectory"), "DuplicateWorktreeOption");
        if (!self.directory->starts_with('/')) {
          usage("RelativeWorktreeDirectory");
        }
      } else if (arg == "--label" && (self.action == Action::create || self.action == Action::exec)) {
        single(self.label, cursor.take("MissingTabLabel"), "DuplicateWorktreeOption");
        printable(*self.label, tab_label_bytes);
      } else if (arg == "--machine" && (self.action == Action::create || self.action == Action::fetch)) {
        single(self.machine, cursor.take("MissingMachineLabel"), "DuplicateWorktreeOption");
        machineLabel(*self.machine);
      } else if (arg == "--dispatched-from" && self.action == Action::create) {
        single(self.dispatched_from, cursor.take("MissingMachineLabel"), "DuplicateWorktreeOption");
        printable(*self.dispatched_from, machine_label_bytes);
      } else if (arg == "--coordinator" && self.action == Action::create) {
        const auto value = cursor.take("MissingCoordinatorReference");
        if (self.coordinator) {
          usage("DuplicateWorktreeOption");
        }
        self.coordinator = coordinatorReference(value);
      } else if (arg == "--repository" && self.action == Action::resolve) {
        single(self.repository, cursor.take("MissingRepository"), "DuplicateWorktreeOption");
        constexpr std::size_t repository_bytes = 512;
        printable(*self.repository, repository_bytes);
      } else if (arg == "--workspace" && (self.action == Action::create || self.action == Action::list || self.action == Action::resolve)) {
        single(self.workspace, cursor.take("MissingWorkspaceTarget"), "DuplicateWorktreeOption");
      } else if (arg == "--client" && self.action == Action::open) {
        self.client = positive(cursor.take("MissingClientId"), "InvalidClientId");
      } else if (arg == "--uncommitted" && self.action == Action::diff) {
        self.uncommitted = true;
      } else if (arg == "--stat" && self.action == Action::diff) {
        self.stat = true;
      } else if (arg == "--force" && self.action == Action::remove) {
        self.force = true;
      } else if (arg == "--delete-branch" && self.action == Action::remove) {
        self.delete_branch = true;
      } else if (arg == "--wait" && self.action == Action::exec) {
        self.wait = true;
      } else if (arg == "--timeout" && self.action == Action::exec) {
        auto value = cursor.take("MissingTimeout");
        while (value.ends_with('s')) {
          value.remove_suffix(1);
        }
        const auto seconds = maybeUnsigned(value);
        if (!seconds || *seconds == 0 || *seconds > max_wait_seconds) {
          usage("InvalidTimeout");
        }
        self.timeout = static_cast<unsigned>(*seconds);
      } else if (arg == "--json") {
        self.json = true;
      } else if (arg == "--socket") {
        single(self.socket, cursor.take("MissingSocketPath"), "DuplicateWorktreeOption");
      } else {
        usage("UnknownWorktreeOption");
      }
    }

    if (self.action == Action::exec && self.command.empty()) {
      usage("MissingWorktreeCommand");
    }
    if (self.action == Action::create && !self.command.empty() && !self.title) {
      usage("MissingWorktreeTitle");
    }
    if (self.action == Action::fetch && !self.machine) {
      usage("MissingMachineLabel");
    }
    if (self.action == Action::resolve && !self.repository) {
      usage("MissingRepository");
    }
    if (self.machine && self.directory) {
      usage("DirectoryOnAnotherMachine");
    }
    return self;
  }
};

}
}
