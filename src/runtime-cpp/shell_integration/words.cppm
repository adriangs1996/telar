module;
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/proc_info.h>
#endif
#include "command_specs.hpp"

export module telar.runtime.shell_integration.words;

import std;

export import telar.git;
export import telar.client.protocol;
export import telar.runtime.platform.request_worker;
import telar.base.memory;
import telar.base.text;
import telar.platform;
import telar.platform.primitives;
import telar.ebnf.matcher;

// The values a completion spec leaves to the runtime, found where the shell runs: commands on
// its PATH, the repository's branches, the hosts in the SSH configuration and the targets of
// the makefile in its directory. Read on a worker, so a slow file system never stalls panes.
export namespace telar::runtime {

struct WordRequest {
  std::uint64_t client = 0;
  std::uint64_t request = 0;
  CompletionProvider provider = CompletionProvider::command;
  FixedText<256> prefix;
  FixedText<PATH_MAX> directory;
  FixedText<PATH_MAX> home;
  FixedText<8192> path;
  // The shell whose builtins and keywords count as commands, and the aliases and functions
  // it reported; without them a missing command cannot be told from an unreported one.
  IntegratedShell shell = IntegratedShell::none;
  std::shared_ptr<const std::string> names;
  // Asks for the completion spec of the command `prefix` names instead of words, and the
  // digest of the spec the client already holds.
  bool spec = false;
  std::uint64_t known_digest = 0;
};

struct Word {
  std::string text;
  std::string description;

  bool operator==(const Word &) const = default;
  auto operator<=>(const Word &) const = default;
};

struct WordResult {
  std::uint64_t client = 0;
  std::uint64_t request = 0;
  std::vector<Word> words;
  bool truncated = false;
  // For a spec request: the command, whether a spec describes it where the shell runs, and
  // the spec when the client does not hold it already.
  bool spec = false;
  std::string command;
  CommandSpecState spec_state = CommandSpecState::unavailable;
  std::uint64_t digest = 0;
  std::string source;
  // The words an alias stands for, when the command is one.
  std::string expansion;
};

class WordReader {
public:
  using Request = WordRequest;
  using Result = WordResult;

  static constexpr std::size_t maximum_words = 256;
  static constexpr std::size_t maximum_file = 1 << 20;
  static constexpr std::size_t maximum_entries = 65536;

  inline WordReader()
      : git_(memory_) {}

  inline Result observe(const Request &request) noexcept {
    Result result{.client = request.client, .request = request.request, .words = {}, .truncated = false};
    if (request.spec) {
      result.spec = true;
      result.command.assign(request.prefix.view());
      try {
        spec(request, result);
      } catch (...) {
        result.spec_state = CommandSpecState::unavailable;
        result.source.clear();
      }
      return result;
    }
    try {
      const auto prefix = request.prefix.view();
      const auto add = [&](std::string_view word, std::string_view description = {}) {
        if (word.empty() || !word.starts_with(prefix) || word.size() > 256 || !printable(word)) {
          return;
        }
        if (result.words.size() >= maximum_words * 4) {
          result.truncated = true;
          return;
        }
        result.words.push_back({std::string{word}, printable(description) ? std::string{description.substr(0, 256)} : std::string{}});
      };
      const auto add_word = [&](std::string_view word) { add(word); };
      switch (request.provider) {
      case CompletionProvider::command:
        commands(request.path.view(), prefix, add);
        builtins(request.shell, add_word);
        if (request.names) {
          words(*request.names, add_word);
        } else {
          result.truncated = true;
        }
        break;
      case CompletionProvider::branch:
        git_.read(request.directory.view());
        git_.branches(maximum_entries, add_word);
        break;
      case CompletionProvider::remote:
        git_.read(request.directory.view());
        git_.remotes(add_word);
        break;
      case CompletionProvider::stash: {
        git_.read(request.directory.view());
        const auto count = git_.stashes(maximum_words);
        for (std::size_t index = 0; index < count; ++index) {
          add("stash@{" + std::to_string(index) + "}");
        }
        break;
      }
      case CompletionProvider::process:
        processes(add);
        break;
      case CompletionProvider::ssh_host:
        sshHosts(request.home.view(), add);
        break;
      case CompletionProvider::make_target:
        makeTargets(request.directory.view(), add);
        break;
      case CompletionProvider::just_recipe:
        justRecipes(request.directory.view(), add);
        break;
      case CompletionProvider::package_script:
        packageScripts(request.directory.view(), add);
        break;
      case CompletionProvider::compose_service:
        composeServices(request.directory.view(), add);
        break;
      }
      // Processes keep the newest first; everything else reads best sorted.
      if (request.provider != CompletionProvider::process) {
        std::ranges::sort(result.words);
      }
      const auto [first, last] = std::ranges::unique(result.words, {}, &Word::text);
      result.words.erase(first, last);
      if (result.words.size() > maximum_words) {
        result.words.resize(maximum_words);
        result.truncated = true;
      }
    } catch (...) {
      result.words.clear();
    }
    return result;
  }

  inline void stop() noexcept {}

private:
  // The spec of the command the request names, when the shell runs it: the user's own from
  // the completions directory when it compiles, else the one telar ships.
  inline void spec(const Request &request, Result &result) {
    auto name = request.prefix.view();
    if (!specName(name)) {
      return;
    }
    // An alias completes as the command it stands for.
    if (request.names) {
      result.expansion = expand(*request.names, name);
      if (!result.expansion.empty()) {
        name = std::string_view{result.expansion}.substr(0, result.expansion.find(' '));
        if (!specName(name)) {
          result.expansion.clear();
          return;
        }
      }
    }
    if (!runs(request, name)) {
      result.expansion.clear();
      return;
    }
    auto source = userSpec(name);
    if (source.empty()) {
      const auto shipped = std::ranges::find(shipped::specs, name, &std::pair<std::string_view, std::string_view>::first);
      if (shipped == shipped::specs.end()) {
        return;
      }
      source.assign(shipped->second);
    }
    result.digest = digest(source);
    if (result.digest == request.known_digest) {
      result.spec_state = CommandSpecState::unchanged;
      return;
    }
    result.spec_state = CommandSpecState::available;
    result.source = std::move(source);
  }

  // What the alias `name` stands for, as the shell reported it (name=words, %-encoded),
  // followed through aliases of aliases; empty when it is no alias of plain words. An alias
  // that starts with its own name (ls='ls -G') stands for that command.
  inline static std::string expand(std::string_view names, std::string_view name) {
    std::string words{name};
    bool expanded = false;
    for (int depth = 0; depth < 4; ++depth) {
      const auto first = std::string_view{words}.substr(0, words.find(' '));
      std::string_view value;
      bool found = false;
      const auto find = [&](std::string_view entry) {
        if (!found && entry.size() > first.size() && entry.starts_with(first) && entry[first.size()] == '=') {
          value = entry.substr(first.size() + 1);
          found = true;
        }
      };
      entries(names, find);
      if (!found) {
        break;
      }
      std::string decoded;
      for (std::size_t index = 0; index < value.size(); ++index) {
        if (value.substr(index).starts_with("%20")) {
          decoded.push_back(' ');
          index += 2;
        } else if (value.substr(index).starts_with("%25")) {
          decoded.push_back('%');
          index += 2;
        } else {
          decoded.push_back(value[index]);
        }
      }
      if (decoded.empty() || decoded.size() > 256 || !printable(decoded) || decoded.front() == ' ') {
        return {};
      }
      const auto rest = std::string_view{words}.substr(first.size());
      const bool same = std::string_view{decoded}.substr(0, decoded.find(' ')) == first;
      words = decoded + std::string{rest};
      expanded = true;
      if (same) {
        break;
      }
    }
    return expanded ? words : std::string{};
  }

  // A spec is named after its command: letters, digits and ., _, + or -, not leading with a dot.
  inline static bool specName(std::string_view name) noexcept {
    return !name.empty() && name.size() <= 64 && name.front() != '.' && std::ranges::all_of(name, [](char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '+' || byte == '-'; });
  }

  // Whether the shell runs `name`: an executable file in a directory of its PATH, one of its
  // builtins, or an alias or function it reported.
  inline static bool runs(const Request &request, std::string_view name) {
    bool found = false;
    const auto exact = [&](std::string_view word, std::string_view = {}) { found |= word == name; };
    builtins(request.shell, exact);
    if (request.names) {
      words(*request.names, exact);
    }
    const std::string file{name};
    auto path = request.path.view();
    while (!found && !path.empty()) {
      const auto separator = path.find(':');
      const auto entry = path.substr(0, separator);
      path.remove_prefix(separator == std::string_view::npos ? path.size() : separator + 1);
      if (entry.empty() || entry.front() != '/' || entry.size() >= PATH_MAX) {
        continue;
      }
      const std::string directory_name{entry};
      FileDescriptor directory{::open(directory_name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      struct stat state{};
      found = directory && ::fstatat(directory.get(), file.c_str(), &state, 0) == 0 && S_ISREG(state.st_mode) && ::faccessat(directory.get(), file.c_str(), X_OK, 0) == 0;
    }
    return found;
  }

  // The user's spec for `name`, from $XDG_CONFIG_HOME/telar/completions (or
  // ~/.config/telar/completions); empty when there is none or it does not compile.
  inline std::string userSpec(std::string_view name) {
    std::string directory;
    if (const char *config = std::getenv("XDG_CONFIG_HOME"); config != nullptr && config[0] == '/') {
      directory.assign(config);
    } else if (const char *home = std::getenv("HOME"); home != nullptr && home[0] == '/') {
      directory.assign(home).append("/.config");
    } else {
      return {};
    }
    directory.append("/telar/completions");
    FileDescriptor folder{::open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!folder) {
      return {};
    }
    const auto file = std::string{name} + ".ebnf";
    auto source = readSmall(folder.get(), file.c_str(), CommandSpec::maximum_source);
    if (source.empty()) {
      return {};
    }
    const auto key = digest(source);
    auto known = compiled_.find(key);
    if (known == compiled_.end()) {
      bool compiles = true;
      try {
        static_cast<void>(ebnf::command_spec::compile(source));
      } catch (...) {
        compiles = false;
      }
      if (compiled_.size() >= 256) {
        compiled_.clear();
      }
      known = compiled_.emplace(key, compiles).first;
    }
    return known->second ? source : std::string{};
  }

  // The first of `names` that `directory` or one of its parents holds, read whole; as the
  // tools find their files. Empty when there is none.
  inline static std::string nearest(std::string_view directory, std::span<const std::string_view> names) {
    std::string current{directory};
    for (int depth = 0; depth < 32 && !current.empty() && current.front() == '/'; ++depth) {
      FileDescriptor folder{::open(current.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (folder) {
        for (const auto name : names) {
          const std::string file{name};
          if (auto bytes = readSmall(folder.get(), file.c_str()); !bytes.empty()) {
            return bytes;
          }
        }
      }
      if (current == "/") {
        break;
      }
      const auto slash = current.rfind('/');
      current.resize(slash == 0 ? 1 : slash);
    }
    return {};
  }

  // The public recipes of the nearest justfile, each with the comment above it, and its
  // aliases.
  template <typename Add>
  inline static void justRecipes(std::string_view directory, Add &add) {
    static constexpr std::array<std::string_view, 3> names{"justfile", "Justfile", ".justfile"};
    const auto source = nearest(directory, names);
    std::string_view comment;
    bool hidden = false;
    lines(source, [&](std::string_view line) {
      if (line.empty() || line.front() == ' ' || line.front() == '\t') {
        comment = {};
        hidden = false;
        return;
      }
      if (line.front() == '#') {
        comment = trim(line.substr(line.find_first_not_of('#')));
        return;
      }
      if (line.front() == '[') {
        hidden |= line.find("private") != std::string_view::npos;
        if (const auto doc = line.find("doc("); doc != std::string_view::npos) {
          const auto open = line.find_first_of("\"'", doc);
          const auto close = open == std::string_view::npos ? open : line.find(line[open], open + 1);
          if (close != std::string_view::npos) {
            comment = line.substr(open + 1, close - open - 1);
          }
        }
        return;
      }
      const auto description = std::exchange(comment, std::string_view{});
      const bool private_recipe = std::exchange(hidden, false);
      if (line.starts_with("alias ")) {
        const auto rest = trim(line.substr(6));
        const auto assign = rest.find(":=");
        if (assign != std::string_view::npos) {
          add(trim(rest.substr(0, assign)), "Alias of " + std::string{trim(rest.substr(assign + 2))});
        }
        return;
      }
      for (const auto keyword : {"set ", "import ", "mod ", "export "}) {
        if (line.starts_with(keyword)) {
          return;
        }
      }
      auto header = line.front() == '@' ? line.substr(1) : line;
      const auto end = header.find_first_of(" :");
      const auto colon = header.find(':');
      if (end == std::string_view::npos || colon == std::string_view::npos || header.substr(colon).starts_with(":=")) {
        return;
      }
      const auto name = header.substr(0, end);
      const bool valid = !name.empty() && (std::isalpha(static_cast<unsigned char>(name.front())) || name.front() == '_') && std::ranges::all_of(name, [](char byte) { return std::isalnum(static_cast<unsigned char>(byte)) || byte == '_' || byte == '-'; });
      if (valid && name.front() != '_' && !private_recipe) {
        add(name, description);
      }
    });
  }

  // The scripts of the nearest package.json, each with the command it runs.
  template <typename Add>
  inline void packageScripts(std::string_view directory, Add &add) {
    static constexpr std::array<std::string_view, 1> names{"package.json"};
    const auto source = nearest(directory, names);
    if (source.empty()) {
      return;
    }
    const auto package = JsonValue::parse(source);
    const auto scripts = package.field("scripts");
    if (!scripts) {
      return;
    }
    String<SystemAllocator> name{AllocatorRef<char, SystemAllocator>{memory_}};
    String<SystemAllocator> command{AllocatorRef<char, SystemAllocator>{memory_}};
    scripts->eachMember([&](const JsonValue &key, const JsonValue &value) {
      key.string(name);
      try {
        value.string(command);
      } catch (const JsonError &) {
        command.clear();
      }
      add(std::string_view{name}, std::string_view{command}.substr(0, 256));
    });
  }

  // The services of the compose file in the nearest directory that has one.
  template <typename Add>
  inline static void composeServices(std::string_view directory, Add &add) {
    static constexpr std::array<std::string_view, 4> names{"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"};
    const auto source = nearest(directory, names);
    bool services = false;
    std::size_t indent = 0;
    lines(source, [&](std::string_view line) {
      const auto first = line.find_first_not_of(' ');
      if (first == std::string_view::npos || line[first] == '#') {
        return;
      }
      if (first == 0) {
        services = trim(line.substr(0, line.find('#'))) == "services:";
        indent = 0;
        return;
      }
      if (!services) {
        return;
      }
      if (indent == 0) {
        indent = first;
      }
      if (first != indent) {
        return;
      }
      auto key = trim(line.substr(first, line.find(':', first) == std::string_view::npos ? std::string_view::npos : line.find(':', first) - first));
      if (key.size() >= 2 && (key.front() == '"' || key.front() == '\'') && key.back() == key.front()) {
        key = key.substr(1, key.size() - 2);
      }
      if (!key.empty() && line.find(':', first) != std::string_view::npos) {
        add(key);
      }
    });
  }

  // FNV-1a: names a spec's text, so a client asks again only for one that changed.
  inline static std::uint64_t digest(std::string_view text) noexcept {
    std::uint64_t value = 0xcbf29ce484222325;
    for (const auto byte : text) {
      value = (value ^ static_cast<unsigned char>(byte)) * 0x100000001b3;
    }
    return value == 0 ? 1 : value;
  }

  inline static bool printable(std::string_view word) noexcept {
    return std::ranges::none_of(word, [](char byte) { return static_cast<unsigned char>(byte) < 0x20 || byte == 0x7f; });
  }

  // What a shell runs without looking in PATH: its builtins and reserved words.
  template <typename Add>
  inline static void builtins(IntegratedShell shell, Add &add) {
    static constexpr auto posix = std::to_array<std::string_view>({".", ":", "[", "alias", "bg", "break", "builtin", "case", "cd", "command", "continue", "do", "done", "echo", "elif", "else", "esac", "eval", "exec", "exit", "export", "false", "fc", "fg", "fi", "for", "getopts", "hash", "if", "in", "jobs", "kill", "local", "printf", "pwd", "read", "readonly", "return", "set", "shift", "source", "test", "then", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "until", "wait", "while", "!", "{", "}", "[["});
    static constexpr auto bash = std::to_array<std::string_view>({"bind", "caller", "compgen", "complete", "compopt", "coproc", "declare", "dirs", "disown", "enable", "function", "help", "history", "let", "logout", "mapfile", "popd", "pushd", "readarray", "select", "shopt", "suspend", "time"});
    static constexpr auto zsh = std::to_array<std::string_view>({"autoload", "bindkey", "bye", "chdir", "compadd", "compdef", "dirs", "disable", "disown", "emulate", "enable", "float", "foreach", "functions", "history", "integer", "let", "limit", "logout", "noglob", "nocorrect", "popd", "print", "pushd", "pushln", "r", "rehash", "repeat", "sched", "select", "setopt", "time", "unfunction", "unhash", "unlimit", "unsetopt", "vared", "whence", "where", "which", "zcompile", "zle", "zmodload", "zparseopts", "zstyle", "function", "end"});
    static constexpr auto fish = std::to_array<std::string_view>({"abbr", "and", "argparse", "begin", "bg", "bind", "block", "break", "builtin", "case", "cd", "command", "commandline", "complete", "contains", "continue", "count", "disown", "echo", "else", "emit", "end", "eval", "exec", "exit", "false", "fg", "for", "function", "functions", "history", "if", "in", "jobs", "math", "not", "or", "path", "printf", "pwd", "random", "read", "realpath", "return", "set", "set_color", "source", "status", "string", "switch", "test", "time", "true", "type", "ulimit", "wait", "while", "[", "!"});
    const auto each = [&](std::span<const std::string_view> names) {
      for (const auto name : names) {
        add(name);
      }
    };
    switch (shell) {
    case IntegratedShell::zsh:
      each(posix);
      each(zsh);
      break;
    case IntegratedShell::bash:
      each(posix);
      each(bash);
      break;
    case IntegratedShell::fish:
      each(fish);
      break;
    case IntegratedShell::none:
      break;
    }
  }

  // The shell's report, entry by entry: a name, or an alias as name=words.
  template <typename Visit>
  inline static void entries(std::string_view names, Visit &visit) {
    while (!names.empty()) {
      const auto start = names.find_first_not_of(' ');
      if (start == std::string_view::npos) {
        return;
      }
      names.remove_prefix(start);
      const auto end = names.find(' ');
      visit(names.substr(0, end));
      names.remove_prefix(end == std::string_view::npos ? names.size() : end);
    }
  }

  // The names the shell reported, aliases without what they stand for.
  template <typename Add>
  inline static void words(std::string_view names, Add &add) {
    const auto name = [&](std::string_view entry) { add(entry.substr(0, entry.find('='))); };
    entries(names, name);
  }

  // Executables in each absolute directory of `path` whose names start with `prefix`.
  template <typename Add>
  inline static void commands(std::string_view path, std::string_view prefix, Add &add) {
    std::size_t scanned = 0;
    while (!path.empty() && scanned < maximum_entries) {
      const auto separator = path.find(':');
      const auto entry = path.substr(0, separator);
      path.remove_prefix(separator == std::string_view::npos ? path.size() : separator + 1);
      if (entry.empty() || entry.front() != '/' || entry.size() >= PATH_MAX) {
        continue;
      }
      const std::string directory_name{entry};
      FileDescriptor directory{::open(directory_name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!directory) {
        continue;
      }
      DirectoryStream entries{directory.get()};
      while (const auto *found = entries.next()) {
        if (++scanned > maximum_entries) {
          return;
        }
        const std::string_view name{found->d_name};
        if (!name.starts_with(prefix) || name.starts_with('.')) {
          continue;
        }
        struct stat state{};
        if (::fstatat(directory.get(), found->d_name, &state, 0) == 0 && S_ISREG(state.st_mode) && ::faccessat(directory.get(), found->d_name, X_OK, 0) == 0) {
          add(name);
        }
      }
    }
  }

  // Reads a regular file of at most `limit` bytes; empty when it is missing or larger.
  inline static std::string readSmall(int directory, const char *name, std::size_t limit = maximum_file) {
    FileDescriptor file{::openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || static_cast<std::size_t>(state.st_size) > limit) {
      return {};
    }
    std::string bytes(static_cast<std::size_t>(state.st_size), '\0');
    std::size_t done = 0;
    while (done < bytes.size()) {
      const auto count = ::read(file.get(), bytes.data() + done, bytes.size() - done);
      if (count <= 0) {
        break;
      }
      done += static_cast<std::size_t>(count);
    }
    bytes.resize(done);
    return bytes;
  }

  template <typename Visit>
  inline static void lines(std::string_view text, Visit &&visit) {
    while (!text.empty()) {
      const auto end = text.find('\n');
      auto line = text.substr(0, end);
      if (line.ends_with('\r')) {
        line.remove_suffix(1);
      }
      visit(line);
      text.remove_prefix(end == std::string_view::npos ? text.size() : end + 1);
    }
  }

  inline static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }
    return text.substr(first, text.find_last_not_of(" \t") - first + 1);
  }

  // `Host` names in ~/.ssh/config, without patterns.
  template <typename Add>
  inline static void sshHosts(std::string_view home, Add &add) {
    if (home.empty() || home.front() != '/') {
      return;
    }
    const std::string directory_name{std::string{home} + "/.ssh"};
    FileDescriptor directory{::open(directory_name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!directory) {
      return;
    }
    const auto text = readSmall(directory.get(), "config");
    lines(text, [&](std::string_view line) {
      line = trim(line);
      if (line.size() < 5 || (line[0] | 0x20) != 'h' || (line[1] | 0x20) != 'o' || (line[2] | 0x20) != 's' || (line[3] | 0x20) != 't' || (line[4] != ' ' && line[4] != '\t' && line[4] != '=')) {
        return;
      }
      auto names = line.substr(5);
      while (!names.empty()) {
        names = trim(names);
        const auto end = names.find_first_of(" \t");
        const auto name = names.substr(0, end);
        if (!name.empty() && name.find_first_of("*?!=") == std::string_view::npos) {
          add(name);
        }
        names.remove_prefix(end == std::string_view::npos ? names.size() : end);
      }
    });
  }

  // The explicit targets of the makefile make would read in `directory`.
  template <typename Add>
  inline static void makeTargets(std::string_view directory_path, Add &add) {
    if (directory_path.empty() || directory_path.front() != '/') {
      return;
    }
    const std::string directory_name{directory_path};
    FileDescriptor directory{::open(directory_name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!directory) {
      return;
    }
    std::string text;
    for (const auto *name : {"GNUmakefile", "makefile", "Makefile"}) {
      text = readSmall(directory.get(), name);
      if (!text.empty()) {
        break;
      }
    }
    lines(text, [&](std::string_view line) {
      if (line.empty() || line.front() == '\t' || line.front() == ' ' || line.front() == '#' || line.front() == '.') {
        return;
      }
      const auto colon = line.find(':');
      if (colon == std::string_view::npos || (colon + 1 < line.size() && line[colon + 1] == '=') || line.substr(0, colon).find_first_of("=$%") != std::string_view::npos) {
        return;
      }
      auto targets = line.substr(0, colon);
      while (!targets.empty()) {
        targets = trim(targets);
        const auto end = targets.find_first_of(" \t");
        add(targets.substr(0, end));
        targets.remove_prefix(end == std::string_view::npos ? targets.size() : end);
      }
    });
  }

  // The user's processes, newest first, each with its name.
  template <typename Add>
  inline static void processes(Add &add) {
    std::vector<std::pair<int, std::string>> found;
#if defined(__APPLE__)
    std::vector<pid_t> pids(4096);
    const auto count = ::proc_listallpids(pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    for (int index = 0; index < count && index < static_cast<int>(pids.size()); ++index) {
      proc_bsdshortinfo info{};
      if (pids[index] <= 0 || ::proc_pidinfo(pids[index], PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbsi_uid != ::geteuid()) {
        continue;
      }
      std::array<char, 2 * MAXCOMLEN + 1> name{};
      const auto length = ::proc_name(pids[index], name.data(), static_cast<std::uint32_t>(name.size()));
      found.emplace_back(pids[index], std::string{name.data(), static_cast<std::size_t>(std::max(0, length))});
    }
#else
    FileDescriptor proc{::open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!proc) {
      return;
    }
    DirectoryStream entries{proc.get()};
    std::size_t scanned = 0;
    while (const auto *entry = entries.next()) {
      if (++scanned > maximum_entries) {
        break;
      }
      const std::string_view name{entry->d_name};
      int pid = 0;
      if (std::from_chars(name.data(), name.data() + name.size(), pid).ptr != name.data() + name.size() || pid <= 0) {
        continue;
      }
      struct stat state{};
      if (::fstatat(proc.get(), entry->d_name, &state, 0) != 0 || state.st_uid != ::geteuid()) {
        continue;
      }
      // /proc reports its files' size as 0: read the name, at most 16 bytes, directly.
      std::array<char, 32> command{};
      std::format_to_n(command.data(), command.size() - 1, "{}/comm", name);
      FileDescriptor file{::openat(proc.get(), command.data(), O_RDONLY | O_CLOEXEC)};
      std::array<char, 64> buffer;
      const auto count = file ? ::read(file.get(), buffer.data(), buffer.size()) : -1;
      std::string_view text{buffer.data(), count > 0 ? static_cast<std::size_t>(count) : 0};
      if (text.ends_with('\n')) {
        text.remove_suffix(1);
      }
      found.emplace_back(pid, std::string{text});
    }
#endif
    std::ranges::sort(found, std::greater{}, &std::pair<int, std::string>::first);
    for (const auto &[pid, name] : found) {
      add(std::to_string(pid), name);
    }
  }

  SystemAllocator memory_;
  git::StatusReader<SystemAllocator> git_;
  // Whether each user spec, by digest, compiled: a spec is compiled once, not per request.
  std::unordered_map<std::uint64_t, bool> compiled_;
};

// One query at a time; later ones wait in order, at most a few per client.
class WordService {
public:
  inline WordService()
      : worker_(std::in_place) {}

  inline void request(const WordRequest &request) {
    if (std::ranges::count(waiting_, request.client, &WordRequest::client) >= 4) {
      return;
    }
    if (!busy_ && worker_.submit(request)) {
      busy_ = true;
      return;
    }
    waiting_.push_back(request);
  }

  template <typename Consumer>
  inline void collect(Consumer &&consume) {
    worker_.collect([&](const WordResult &result) {
      busy_ = false;
      consume(result);
    });
    while (!busy_ && !waiting_.empty()) {
      const auto next = waiting_.front();
      waiting_.erase(waiting_.begin());
      busy_ = worker_.submit(next);
    }
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  ObservationWorker<WordReader> worker_;
  std::vector<WordRequest> waiting_;
  bool busy_ = false;
};

}
