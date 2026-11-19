module telar.runtime.shell_integration.words;

import std;
import telar.sys.posix;
#if defined(__APPLE__)
import telar.sys.apple;
#endif
import telar.base.text;
import telar.base.text.json;
import telar.platform.fs;
import telar.platform.primitives;
import telar.ebnf.matcher;
import telar.base.ds;
import telar.tbc;

namespace telar::runtime {

  namespace {

    using Text = ds::String<ConcurrentMemory>;

    // The completion specs telar ships, by the command they describe.
    namespace shipped {

#include "command_specs.inc"

    }

    bool printable(std::string_view word) noexcept {
      return std::ranges::none_of(word, [](char byte) {
        return static_cast<unsigned char>(byte) < 0x20 || byte == 0x7f;
      });
    }

    // FNV-1a: names a spec's text, so a client asks again only for one that changed.
    std::uint64_t digest(std::string_view text) noexcept {
      const auto value = fnv1a64(text);

      return value == 0 ? 1 : value;
    }

    // The shell's report, entry by entry: a name, or an alias as name=words.
    template <typename Visit>
    void entries(std::string_view names, Visit& visit) {
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
    void words(std::string_view names, Add& add) {
      const auto name = [&](std::string_view entry) {
        add(entry.substr(0, entry.find('=')));
      };

      entries(names, name);
    }

    // Opens each absolute directory of `path`, a colon-separated list, and hands its descriptor
    // to `visit` until `visit` returns false. Relative, over-long and unopenable entries are
    // passed over.
    template <typename Visit>
    void forEachPathDirectory(std::string_view path, Visit&& visit) {
      ds::Array<char, PATH_MAX> name;

      while (!path.empty()) {
        const auto separator = path.find(':');
        const auto entry = path.substr(0, separator);

        path.remove_prefix(separator == std::string_view::npos ? path.size() : separator + 1);
        if (entry.empty() || entry.front() != '/' || entry.size() >= name.size()) {
          continue;
        }

        *std::ranges::copy(entry, name.dataMut()).out = '\0';
        FileDescriptor directory{::open(name.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
        if (directory && !visit(directory.get())) {
          return;
        }
      }
    }

    // Reads a regular file of at most `limit` bytes; empty when it is missing or larger.
    tbc::view<Text, tbc::lt::a> readSmall(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, int directory, const char* name, std::size_t limit = WordReader::maximum_file) {
      Text bytes{memory};
      FileDescriptor file{::openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)};
      struct stat state{};
      if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || static_cast<std::size_t>(state.st_size) > limit) {
        return bytes;
      }

      bytes.resizeForOverwrite(static_cast<std::size_t>(state.st_size));
      std::size_t done = 0;

      while (done < bytes.size()) {
        const auto count = ::read(file.get(), bytes.dataMut() + done, bytes.size() - done);
        if (count <= 0) {
          break;
        }

        done += static_cast<std::size_t>(count);
      }

      bytes.truncate(done);
      return bytes;
    }

    template <typename Visit>
    void lines(std::string_view text, Visit&& visit) {
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

    // The first of `names` that `directory` or one of its parents holds, read whole; as the
    // tools find their files. Empty when there is none.
    tbc::view<Text, tbc::lt::a> nearest(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::string_view directory, std::span<const std::string_view> names) {
      Text current{memory, directory};
      Text file{memory};

      for (int depth = 0; depth < 32 && current.view().starts_with('/'); ++depth) {
        FileDescriptor folder{::open(current.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
        if (folder) {
          for (const auto name : names) {
            file.assign(name);
            if (auto bytes = readSmall(memory, folder.get(), file.data()); !bytes.empty()) {
              return bytes;
            }
          }
        }

        if (current == "/") {
          break;
        }

        const auto slash = current.view().rfind('/');

        current.truncate(slash == 0 ? 1 : slash);
      }

      return Text{memory};
    }

    // What the alias `name` stands for, as the shell reported it (name=words, %-encoded),
    // followed through aliases of aliases; empty when it is no alias of plain words. An alias
    // that starts with its own name (ls='ls -G') stands for that command.
    tbc::view<Text, tbc::lt::a> expand(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::string_view names, std::string_view name) {
      Text words{memory, name};
      Text decoded{memory};
      bool expanded = false;

      for (int depth = 0; depth < 4; ++depth) {
        const auto first = words.view().substr(0, words.view().find(' '));
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

        decoded.clear();
        for (std::size_t index = 0; index < value.size(); ++index) {
          if (value.substr(index).starts_with("%20")) {
            decoded.push(' ');
            index += 2;
          } else if (value.substr(index).starts_with("%25")) {
            decoded.push('%');
            index += 2;
          } else {
            decoded.push(value[index]);
          }
        }

        if (decoded.empty() || decoded.size() > 256 || !printable(decoded) || decoded.view().front() == ' ') {
          return Text{memory};
        }

        const bool same = decoded.view().substr(0, decoded.view().find(' ')) == first;

        // The alias's words replace the name; the words after the name stay.
        words.replace(0, first.size(), decoded);
        expanded = true;
        if (same) {
          break;
        }
      }

      if (!expanded) {
        words.clear();
      }

      return words;
    }

    // A spec is named after its command: letters, digits and ., _, + or -, not leading with a dot.
    bool specName(std::string_view name) noexcept {
      return !name.empty() && name.size() <= 64 && name.front() != '.' && std::ranges::all_of(name, [](char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '+' || byte == '-';
      });
    }

    // What a shell runs without looking in PATH: its builtins and reserved words.
    template <typename Add>
    void builtins(IntegratedShell shell, Add& add) {
      static constexpr auto posix = ds::Array<std::string_view, 59>{".", ":", "[", "alias", "bg", "break", "builtin", "case", "cd", "command", "continue", "do", "done", "echo", "elif", "else", "esac", "eval", "exec", "exit", "export", "false", "fc", "fg", "fi", "for", "getopts", "hash", "if", "in", "jobs", "kill", "local", "printf", "pwd", "read", "readonly", "return", "set", "shift", "source", "test", "then", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "until", "wait", "while", "!", "{", "}", "[["};
      static constexpr auto bash = ds::Array<std::string_view, 23>{"bind", "caller", "compgen", "complete", "compopt", "coproc", "declare", "dirs", "disown", "enable", "function", "help", "history", "let", "logout", "mapfile", "popd", "pushd", "readarray", "select", "shopt", "suspend", "time"};
      static constexpr auto zsh = ds::Array<std::string_view, 47>{"autoload", "bindkey", "bye", "chdir", "compadd", "compdef", "dirs", "disable", "disown", "emulate", "enable", "float", "foreach", "functions", "history", "integer", "let", "limit", "logout", "noglob", "nocorrect", "popd", "print", "pushd", "pushln", "r", "rehash", "repeat", "sched", "select", "setopt", "time", "unfunction", "unhash", "unlimit", "unsetopt", "vared", "whence", "where", "which", "zcompile", "zle", "zmodload", "zparseopts", "zstyle", "function", "end"};
      static constexpr auto fish = ds::Array<std::string_view, 59>{"abbr", "and", "argparse", "begin", "bg", "bind", "block", "break", "builtin", "case", "cd", "command", "commandline", "complete", "contains", "continue", "count", "disown", "echo", "else", "emit", "end", "eval", "exec", "exit", "false", "fg", "for", "function", "functions", "history", "if", "in", "jobs", "math", "not", "or", "path", "printf", "pwd", "random", "read", "realpath", "return", "set", "set_color", "source", "status", "string", "switch", "test", "time", "true", "type", "ulimit", "wait", "while", "[", "!"};
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

    // Whether the shell runs `name`: an executable file in a directory of its PATH, one of its
    // builtins, or an alias or function it reported.
    bool runs(const WordRequest& request, std::string_view name) {
      bool found = false;
      const auto exact = [&](std::string_view word, std::string_view = {}) {
        found |= word == name;
      };

      builtins(request.shell, exact);
      if (request.names) {
        words(request.names->view(), exact);
      }

      // No directory holds a file whose name is longer than NAME_MAX.
      ds::Array<char, NAME_MAX + 1> file;
      if (found || name.size() >= file.size()) {
        return found;
      }

      *std::ranges::copy(name, file.dataMut()).out = '\0';
      forEachPathDirectory(request.path.view(), [&](int directory) {
        struct stat state{};

        found = ::fstatat(directory, file.data(), &state, 0) == 0 && S_ISREG(state.st_mode) && ::faccessat(directory, file.data(), X_OK, 0) == 0;
        return !found;
      });

      return found;
    }

    // The public recipes of the nearest justfile, each with the comment above it, and its
    // aliases.
    template <typename Add>
    void justRecipes(ConcurrentMemory& memory, std::string_view directory, Add& add) {
      static constexpr ds::Array<std::string_view, 3> names{"justfile", "Justfile", ".justfile"};
      const auto source = nearest(memory, directory, names);
      Text alias{memory};
      std::string_view comment;
      bool hidden = false;

      lines(source, [&](std::string_view line) {
        if (line.empty() || line.front() == ' ' || line.front() == '\t') {
          comment = {};
          hidden = false;
          return;
        }

        if (line.front() == '#') {
          comment = trimText(line.substr(line.find_first_not_of('#')), " \t");
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
          const auto rest = trimText(line.substr(6), " \t");
          const auto assign = rest.find(":=");
          if (assign != std::string_view::npos) {
            alias.assign("Alias of ");
            alias.append(trimText(rest.substr(assign + 2), " \t"));
            add(trimText(rest.substr(0, assign), " \t"), alias.view());
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
        const bool valid = !name.empty() && (std::isalpha(static_cast<unsigned char>(name.front())) || name.front() == '_') && std::ranges::all_of(name, [](char byte) {
          return std::isalnum(static_cast<unsigned char>(byte)) || byte == '_' || byte == '-';
        });
        if (valid && name.front() != '_' && !private_recipe) {
          add(name, description);
        }
      });
    }

    // The scripts of the nearest package.json, each with the command it runs.
    template <typename Add>
    void packageScripts(ConcurrentMemory& memory, std::string_view directory, Add& add) {
      static constexpr ds::Array<std::string_view, 1> names{"package.json"};
      const auto source = nearest(memory, directory, names);
      if (source.empty()) {
        return;
      }

      const auto package = JsonValue::parse(source);
      const auto scripts = package.field("scripts");
      if (!scripts) {
        return;
      }

      Text name{memory};
      Text command{memory};

      scripts->eachMember([&](const JsonValue& key, const JsonValue& value) {
        key.string(name);
        try {
          value.string(command);
        } catch (const JsonError&) {
          command.clear();
        }

        add(std::string_view{name}, std::string_view{command}.substr(0, 256));
      });
    }

    // The services of the compose file in the nearest directory that has one.
    template <typename Add>
    void composeServices(ConcurrentMemory& memory, std::string_view directory, Add& add) {
      static constexpr ds::Array<std::string_view, 4> names{"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"};
      const auto source = nearest(memory, directory, names);
      bool services = false;
      std::size_t indent = 0;

      lines(source, [&](std::string_view line) {
        const auto first = line.find_first_not_of(' ');
        if (first == std::string_view::npos || line[first] == '#') {
          return;
        }

        if (first == 0) {
          services = trimText(line.substr(0, line.find('#')), " \t") == "services:";
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

        auto key = trimText(line.substr(first, line.find(':', first) == std::string_view::npos ? std::string_view::npos : line.find(':', first) - first), " \t");
        if (key.size() >= 2 && (key.front() == '"' || key.front() == '\'') && key.back() == key.front()) {
          key = key.substr(1, key.size() - 2);
        }

        if (!key.empty() && line.find(':', first) != std::string_view::npos) {
          add(key);
        }
      });
    }

    // Executables in each absolute directory of `path` whose names start with `prefix`.
    template <typename Add>
    void commands(std::string_view path, std::string_view prefix, Add& add) {
      std::size_t scanned = 0;

      forEachPathDirectory(path, [&](int directory) {
        DirectoryStream entries{directory};

        while (const auto* found = entries.next()) {
          if (++scanned > WordReader::maximum_entries) {
            return false;
          }

          const std::string_view name{found->d_name};
          if (!name.starts_with(prefix) || name.starts_with('.')) {
            continue;
          }

          struct stat state{};
          if (::fstatat(directory, found->d_name, &state, 0) == 0 && S_ISREG(state.st_mode) && ::faccessat(directory, found->d_name, X_OK, 0) == 0) {
            add(name);
          }
        }

        return scanned < WordReader::maximum_entries;
      });
    }

    // `Host` names in ~/.ssh/config, without patterns.
    template <typename Add>
    void sshHosts(ConcurrentMemory& memory, std::string_view home, Add& add) {
      if (home.empty() || home.front() != '/') {
        return;
      }

      Text directory_name{memory, home};

      directory_name.append("/.ssh");
      FileDescriptor directory{::open(directory_name.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!directory) {
        return;
      }

      const auto text = readSmall(memory, directory.get(), "config");

      lines(text, [&](std::string_view line) {
        line = trimText(line, " \t");
        if (line.size() < 5 || (line[0] | 0x20) != 'h' || (line[1] | 0x20) != 'o' || (line[2] | 0x20) != 's' || (line[3] | 0x20) != 't' || (line[4] != ' ' && line[4] != '\t' && line[4] != '=')) {
          return;
        }

        auto names = line.substr(5);

        while (!names.empty()) {
          names = trimText(names, " \t");
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
    void makeTargets(ConcurrentMemory& memory, std::string_view directory_path, Add& add) {
      if (directory_path.empty() || directory_path.front() != '/') {
        return;
      }

      const Text directory_name{memory, directory_path};
      FileDescriptor directory{::open(directory_name.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!directory) {
        return;
      }

      Text text{memory};

      for (const auto* name : {"GNUmakefile", "makefile", "Makefile"}) {
        text = readSmall(memory, directory.get(), name);
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
          targets = trimText(targets, " \t");
          const auto end = targets.find_first_of(" \t");

          add(targets.substr(0, end));
          targets.remove_prefix(end == std::string_view::npos ? targets.size() : end);
        }
      });
    }

    // The user's processes, newest first, each with its name.
    template <typename Add>
    void processes(ConcurrentMemory& memory, Add& add) {
      ds::Vec<std::pair<int, Text>, ConcurrentMemory> found{memory};
#if defined(__APPLE__)
      ds::Vec<pid_t, ConcurrentMemory> pids{memory};

      pids.resize(4096);
      const auto count = ::proc_listallpids(pids.dataMut(), static_cast<int>(pids.size() * sizeof(pid_t)));

      for (int index = 0; index < count && index < static_cast<int>(pids.size()); ++index) {
        proc_bsdshortinfo info{};
        if (pids[index] <= 0 || ::proc_pidinfo(pids[index], PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbsi_uid != ::geteuid()) {
          continue;
        }

        ds::Array<char, 2 * MAXCOMLEN + 1> name{};
        const auto length = ::proc_name(pids[index], name.dataMut(), static_cast<std::uint32_t>(name.size()));

        found.push({pids[index], Text{memory, std::string_view{name.data(), static_cast<std::size_t>(std::max(0, length))}}});
      }

#else
      FileDescriptor proc{::open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!proc) {
        return;
      }
      DirectoryStream entries{proc.get()};
      std::size_t scanned = 0;
      while (const auto* entry = entries.next()) {
        if (++scanned > WordReader::maximum_entries) {
          break;
        }
        const std::string_view name{entry->d_name};
        const auto pid = parseExact<int>(name).valueOr(0);
        if (pid <= 0) {
          continue;
        }
        struct stat state{};
        if (::fstatat(proc.get(), entry->d_name, &state, 0) != 0 || state.st_uid != ::geteuid()) {
          continue;
        }
        // /proc reports its files' size as 0: read the name, at most 16 bytes, directly.
        ds::Array<char, 32> command{};
        std::format_to_n(command.dataMut(), command.size() - 1, "{}/comm", name);
        FileDescriptor file{::openat(proc.get(), command.data(), O_RDONLY | O_CLOEXEC)};
        ds::Array<char, 64> buffer;
        const auto count = file ? ::read(file.get(), buffer.dataMut(), buffer.size()) : -1;
        std::string_view text{buffer.data(), count > 0 ? static_cast<std::size_t>(count) : 0};
        if (text.ends_with('\n')) {
          text.remove_suffix(1);
        }
        found.push({pid, Text{memory, text}});
      }
#endif
      std::ranges::sort(found.viewMut(), std::greater{}, &std::pair<int, Text>::first);
      for (const auto& [pid, name] : found) {
        ds::Array<char, 16> digits;
        const auto end = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), pid).ptr;

        add(std::string_view{digits.data(), end}, name.view());
      }
    }

  }

  WordResult::WordResult(tbc::view<ConcurrentMemory&, tbc::lt::a> memory)
      : words(memory),
        command(memory),
        source(memory),
        expansion(memory) {}

  WordReader::WordReader(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::string_view configuration_directory)
      : memory_(memory),
        completions_(memory),
        git_(memory),
        compiled_(memory) {
    if (!configuration_directory.empty()) {
      completions_.assign(configuration_directory);
      completions_.append("/completions");
    }
  }

  tbc::view<WordReader::Result, tbc::lt::a> WordReader::observe(const Request& request) noexcept {
    Result result{memory_};

    result.client = request.client;
    result.request = request.request;

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

        result.words.push(Word{.text = Text{memory_, word}, .description = Text{memory_, printable(description) ? description.substr(0, 256) : std::string_view{}}});
      };

      const auto add_word = [&](std::string_view word) {
        add(word);
      };

      switch (request.provider) {
      case CompletionProvider::command:
        commands(request.path.view(), prefix, add);
        builtins(request.shell, add_word);
        if (request.names) {
          words(request.names->view(), add_word);
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
          ds::Array<char, 32> stash;
          const auto written = std::format_to_n(stash.dataMut(), stash.size(), "stash@{{{}}}", index);

          add(std::string_view{stash.data(), static_cast<std::size_t>(written.out - stash.data())});
        }

        break;
      }
      case CompletionProvider::process:
        processes(memory_, add);
        break;
      case CompletionProvider::ssh_host:
        sshHosts(memory_, request.home.view(), add);
        break;
      case CompletionProvider::make_target:
        makeTargets(memory_, request.directory.view(), add);
        break;
      case CompletionProvider::just_recipe:
        justRecipes(memory_, request.directory.view(), add);
        break;
      case CompletionProvider::package_script:
        packageScripts(memory_, request.directory.view(), add);
        break;
      case CompletionProvider::compose_service:
        composeServices(memory_, request.directory.view(), add);
        break;
      }

      // Processes keep the newest first; everything else reads best sorted.
      if (request.provider != CompletionProvider::process) {
        std::ranges::sort(result.words.viewMut());
      }

      const auto duplicates = std::ranges::unique(result.words.viewMut(), {}, &Word::text);

      result.words.truncate(result.words.size() - duplicates.size());
      if (result.words.size() > maximum_words) {
        result.words.truncate(maximum_words);
        result.truncated = true;
      }
    } catch (...) {
      result.words.clear();
    }

    return result;
  }

  void WordReader::stop() noexcept {}

  void WordReader::spec(const Request& request, tbc::view<Result&, tbc::lt::a> result) {
    auto name = request.prefix.view();
    if (!specName(name)) {
      return;
    }

    // An alias completes as the command it stands for.
    if (request.names) {
      result.expansion = expand(memory_, request.names->view(), name);
      if (!result.expansion.empty()) {
        name = result.expansion.view().substr(0, result.expansion.view().find(' '));
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

  std::span<const std::pair<std::string_view, std::string_view>> shippedSpecs() noexcept {
    return shipped::specs.view();
  }

  tbc::view<ds::String<ConcurrentMemory>, tbc::lt::a> WordReader::userSpec(std::string_view name) {
    Text source{memory_};

    if (completions_.empty()) {
      return source;
    }

    FileDescriptor folder{::open(completions_.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!folder) {
      return source;
    }

    Text file{memory_, name};

    file.append(".ebnf");
    source = readSmall(memory_, folder.get(), file.data(), CommandSpec::maximum_source);
    if (source.empty()) {
      return source;
    }

    const auto key = digest(source);
    const auto* known = compiled_.find(key);
    bool compiles = known != nullptr && *known;

    if (known == nullptr) {
      compiles = true;
      try {
        static_cast<void>(ebnf::command_spec::compile(source));
      } catch (...) {
        compiles = false;
      }

      if (compiled_.size() >= 256) {
        compiled_.clear();
      }

      static_cast<void>(compiled_.insert(key, compiles));
    }

    if (!compiles) {
      source.clear();
    }

    return source;
  }

  WordService::WordService(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::string_view configuration_directory)
      : worker_(std::in_place, memory, configuration_directory),
        queue_(memory) {}

  void WordService::request(tbc::holds<const WordRequest&, tbc::lt::a> request) {
    if (std::ranges::count(queue_.waiting(), request.client, &WordRequest::client) >= 4) {
      return;
    }

    queue_.request(worker_, request);
  }

  int WordService::descriptor() const noexcept {
    return worker_.descriptor();
  }

}
