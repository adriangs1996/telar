module telar.runtime.terminal.shell_integration.words;

import std;
import telar.sys.posix;
#ifdef __APPLE__
import telar.sys.apple;
#endif
import telar.base.text;
import telar.base.text.utf8;
import telar.base.text.json;
import telar.platform.fs;
import telar.platform.primitives;
import telar.ebnf.matcher;
import telar.base.ds;
import telar.tbc;

namespace telar::runtime {

  namespace {

    using Text = ds::String<ConcurrentMemory>;

    // The control bytes below the space and DEL.
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;

    // The longest word, description or alias expansion a completion carries.
    constexpr std::size_t maximum_text_bytes = 256;

    // How far up from a directory a project file is looked for.
    constexpr int maximum_parent_depth = 32;

    // The completion specs telar ships, by the command they describe.
    namespace shipped {

#include "command_specs.inc"

    }

    // UTF-8 without control bytes: what the wire carries as display text.
    bool printable(std::string_view word) noexcept {
      const auto control = std::ranges::any_of(word, [](char byte) {
        const auto value = static_cast<unsigned char>(byte);

        return value < first_printable || value == delete_byte;
      });

      return !control && inspectUtf8(word) == Utf8Validation::valid;
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
    // passed over. Takes the visitor itself, as the lambdas callers pass build it in place.
    template <typename Visit>
    void forEachPathDirectory(std::string_view path, Visit visit) {
      ds::Array<char, PATH_MAX> name{};

      while (!path.empty()) {
        const auto separator = path.find(':');
        const auto entry = path.substr(0, separator);

        path.remove_prefix(separator == std::string_view::npos ? path.size() : separator + 1);
        if (entry.empty() || entry.front() != '/' || entry.size() >= name.size()) {
          continue;
        }

        *std::ranges::copy(entry, name.dataMut()).out = '\0';
        FileDescriptor directory{::open(name.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
        if (directory && !visit(directory.get())) {
          return;
        }
      }
    }

    // Reads a regular file of at most `limit` bytes; empty when it is missing or larger.
    tbc::val_a<Text> readSmall(tbc::mut_a<ConcurrentMemory> memory, int directory, const char* name, std::size_t limit = WordReader::maximum_file) {
      Text bytes{memory};
      FileDescriptor file{::openat(directory, name, combineFlags(O_RDONLY, O_CLOEXEC, O_NONBLOCK))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      struct stat state{};
      if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || std::cmp_greater(state.st_size, limit)) {
        return bytes;
      }

      bytes.resizeForOverwrite(static_cast<std::size_t>(state.st_size));
      std::size_t done = 0;

      while (done < bytes.size()) {
        const auto unread = bytes.viewMut().subspan(done);
        const auto count = ::read(file.get(), unread.data(), unread.size());
        if (count <= 0) {
          break;
        }

        done += static_cast<std::size_t>(count);
      }

      bytes.truncate(done);
      return bytes;
    }

    // Takes the visitor itself, as the lambdas callers pass build it in place.
    template <typename Visit>
    void lines(std::string_view text, Visit visit) {
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

    // The first of `names` that `folder` holds, read whole; empty when it holds none. `file` is
    // scratch for the terminated name.
    tbc::val_a<Text> firstOf(tbc::mut_a<ConcurrentMemory> memory, int folder, std::span<const std::string_view> names, Text& file) {
      for (const auto name : names) {
        file.assign(name);
        if (auto bytes = readSmall(memory, folder, file.data()); !bytes.empty()) {
          return bytes;
        }
      }

      return Text{memory};
    }

    // The first of `names` that `directory` or one of its parents holds, read whole; as the
    // tools find their files. Empty when there is none.
    tbc::val_a<Text> nearest(tbc::mut_a<ConcurrentMemory> memory, std::string_view directory, std::span<const std::string_view> names) {
      Text current{memory, directory};
      Text file{memory};

      for (int depth = 0; depth < maximum_parent_depth && current.view().starts_with('/'); ++depth) {
        FileDescriptor folder{::open(current.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
        if (folder) {
          if (auto bytes = firstOf(memory, folder.get(), names, file); !bytes.empty()) {
            return bytes;
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
    tbc::val_a<Text> expand(tbc::mut_a<ConcurrentMemory> memory, std::string_view names, std::string_view name) {
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

        if (decoded.empty() || decoded.size() > maximum_text_bytes || !printable(decoded) || decoded.view().front() == ' ') {
          words.clear();
          return words;
        }

        const bool same = decoded.view().substr(0, decoded.view().find(' ')) == first;

        // The alias's words replace the name; the words after the name stay.
        words.replace(0, first.size(), decoded);
        expanded = true;
        if (same) {
          break;
        }
      }

      // Words past what a reply carries are dropped, not cut.
      if (!expanded || words.size() > maximum_text_bytes) {
        words.clear();
      }

      return words;
    }

    // A spec is named after its command: letters, digits and ., _, + or -, not leading with a dot.
    bool specName(std::string_view name) noexcept {
      constexpr std::size_t maximum_spec_name = 64;

      return !name.empty() && name.size() <= maximum_spec_name && name.front() != '.' && std::ranges::all_of(name, [](char byte) {
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
      ds::Array<char, NAME_MAX + 1> file{};
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

    // What a justfile's lines carry to the recipe after them: its comment and whether it is private.
    struct RecipeNotes {
      std::string_view comment;
      bool hidden = false;
    };

    // Reads a line that annotates the next recipe, or ends what annotated it; false for a recipe,
    // an alias or a setting.
    bool recipeAnnotation(tbc::val_a<std::string_view> line, tbc::mut_a<RecipeNotes> notes) {
      if (line.empty() || line.front() == ' ' || line.front() == '\t') {
        notes = {};
        return true;
      }

      if (line.front() == '#') {
        notes.comment = trimText(line.substr(line.find_first_not_of('#')), " \t");
        return true;
      }

      if (line.front() != '[') {
        return false;
      }

      notes.hidden |= line.contains("private");
      if (const auto doc = line.find("doc("); doc != std::string_view::npos) {
        const auto open = line.find_first_of("\"'", doc);
        const auto close = open == std::string_view::npos ? open : line.find(line[open], open + 1);
        if (close != std::string_view::npos) {
          notes.comment = line.substr(open + 1, close - open - 1);
        }
      }

      return true;
    }

    // The recipe a line declares; empty when it declares none.
    std::string_view recipeName(std::string_view line) {
      for (const auto* const keyword : {"set ", "import ", "mod ", "export "}) {
        if (line.starts_with(keyword)) {
          return {};
        }
      }

      const auto header = line.front() == '@' ? line.substr(1) : line;
      const auto end = header.find_first_of(" :");
      const auto colon = header.find(':');
      if (end == std::string_view::npos || colon == std::string_view::npos || header.substr(colon).starts_with(":=")) {
        return {};
      }

      const auto name = header.substr(0, end);
      const bool valid = !name.empty() && (std::isalpha(static_cast<unsigned char>(name.front())) != 0 || name.front() == '_') && std::ranges::all_of(name, [](char byte) {
        return std::isalnum(static_cast<unsigned char>(byte)) != 0 || byte == '_' || byte == '-';
      });

      return valid ? name : std::string_view{};
    }

    // An `alias name := recipe` line, offered as the name with what it stands for.
    template <typename Add>
    void justAlias(std::string_view line, Text& alias, Add& add) {
      constexpr std::string_view keyword = "alias ";
      const auto rest = trimText(line.substr(keyword.size()), " \t");
      const auto assign = rest.find(":=");
      if (assign == std::string_view::npos) {
        return;
      }

      alias.assign("Alias of ");
      alias.append(trimText(rest.substr(assign + 2), " \t"));
      add(trimText(rest.substr(0, assign), " \t"), alias.view());
    }

    // The public recipes of the nearest justfile, each with the comment above it, and its
    // aliases.
    template <typename Add>
    void justRecipes(ConcurrentMemory& memory, std::string_view directory, Add& add) {
      static constexpr ds::Array<std::string_view, 3> names{"justfile", "Justfile", ".justfile"};
      const auto source = nearest(memory, directory, names);
      Text alias{memory};
      RecipeNotes notes;

      lines(source, [&](std::string_view line) {
        if (recipeAnnotation(line, notes)) {
          return;
        }

        const auto description = std::exchange(notes.comment, std::string_view{});
        const bool private_recipe = std::exchange(notes.hidden, false);

        if (line.starts_with("alias ")) {
          justAlias(line, alias, add);
          return;
        }

        const auto name = recipeName(line);
        if (!name.empty() && name.front() != '_' && !private_recipe) {
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

        add(std::string_view{name}, utf8Prefix(std::string_view{command}, maximum_text_bytes));
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

    // The executables to look for: those in each absolute directory of `path` whose names start
    // with `prefix`.
    struct CommandSearch {
      std::string_view path;
      std::string_view prefix;
    };

    template <typename Add>
    void commands(CommandSearch search, Add& add) {
      std::size_t scanned = 0;

      forEachPathDirectory(search.path, [&](int directory) {
        DirectoryStream entries{directory};

        while (const auto* found = entries.next()) {
          if (++scanned > WordReader::maximum_entries) {
            return false;
          }

          const auto* const terminated = std::data(found->d_name);
          const std::string_view name{terminated};
          if (!name.starts_with(search.prefix) || name.starts_with('.')) {
            continue;
          }

          struct stat state{};
          if (::fstatat(directory, terminated, &state, 0) == 0 && S_ISREG(state.st_mode) && ::faccessat(directory, terminated, X_OK, 0) == 0) {
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
      FileDescriptor directory{::open(directory_name.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!directory) {
        return;
      }

      const auto text = readSmall(memory, directory.get(), "config");

      lines(text, [&](std::string_view line) {
        constexpr std::string_view keyword = "host";

        line = trimText(line, " \t");
        if (line.size() <= keyword.size() || !asciiStartsWithIgnoreCase(line, keyword)) {
          return;
        }

        if (const char separator = line[keyword.size()]; separator != ' ' && separator != '\t' && separator != '=') {
          return;
        }

        auto names = line.substr(keyword.size() + 1);

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
      FileDescriptor directory{::open(directory_name.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
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
#ifdef __APPLE__
      constexpr std::size_t maximum_processes = 4096;
      ds::Vec<pid_t, ConcurrentMemory> pids{memory};

      pids.resize(maximum_processes);
      const auto count = ::proc_listallpids(pids.dataMut(), static_cast<int>(pids.size() * sizeof(pid_t)));
      const auto listed = std::min(static_cast<std::size_t>(std::max(0, count)), pids.size());

      for (std::size_t index = 0; index < listed; ++index) {
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
        constexpr std::size_t pid_digits = 16;
        ds::Array<char, pid_digits> digits{};
        auto* const end = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), pid).ptr;

        add(std::string_view{digits.data(), end}, name.view());
      }
    }

    // The directory a typed path's directory part names, NUL-terminated in `resolved`: `~` or
    // `~user` at its start is a home, and a relative one is under `directory`. False for a
    // directory part with a variable, which only the shell can expand, or one that does not fit.
    bool typedDirectory(std::string_view typed, std::string_view directory, std::string_view home, ds::Array<char, PATH_MAX>& resolved) {
      if (typed.contains('$')) {
        return false;
      }

      std::size_t length = 0;
      const auto append = [&](std::string_view part) {
        if (length + part.size() >= resolved.size()) {
          return false;
        }

        std::ranges::copy(part, resolved.dataMut() + length);
        length += part.size();
        return true;
      };

      bool fits = true;

      if (typed.starts_with('~')) {
        const auto end = std::min(typed.find('/'), typed.size());
        const auto user = typed.substr(1, end - 1);

        if (user.empty()) {
          fits = append(home);
        } else {
          constexpr std::size_t account_bytes = 4096;
          ds::Array<char, NAME_MAX + 1> name{};
          ds::Array<char, account_bytes> storage{};
          passwd account{};
          passwd* found = nullptr;
          if (user.size() >= name.size()) {
            return false;
          }

          *std::ranges::copy(user, name.dataMut()).out = '\0';
          if (::getpwnam_r(name.data(), &account, storage.dataMut(), storage.size(), &found) != 0 || found == nullptr || found->pw_dir == nullptr) {
            return false;
          }

          fits = append(std::string_view{found->pw_dir});
        }

        typed.remove_prefix(end);
      } else if (!typed.starts_with('/')) {
        fits = append(directory) && append("/");
      }

      if (!fits || !append(typed) || length == 0 || resolved[0] != '/') {
        return false;
      }

      resolved.atMut(length) = '\0';
      return true;
    }

    // The entries of the one directory `typed` names, before its last slash, that start with
    // what follows it, written back with `typed`'s directory part: a directory, or a link to one,
    // ends with a slash. Dot files only for a name that starts with a dot.
    template <typename Add>
    void directoryEntries(ConcurrentMemory& memory, const WordRequest& request, Add& add) {
      const auto typed = request.prefix.view();
      const auto slash = typed.rfind('/');
      const auto shown = slash == std::string_view::npos ? std::string_view{} : typed.substr(0, slash + 1);
      const auto partial = slash == std::string_view::npos ? typed : typed.substr(slash + 1);
      ds::Array<char, PATH_MAX> path; // NOLINT(cppcoreguidelines-pro-type-member-init): typedDirectory writes the bytes open reads, up to their NUL
      if (!typedDirectory(shown, request.directory.view(), request.home.view(), path)) {
        return;
      }

      FileDescriptor directory{::open(path.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!directory) {
        return;
      }

      DirectoryStream entries{directory.get()};
      Text word{memory};
      std::size_t scanned = 0;

      while (const auto* entry = entries.next()) {
        const std::string_view name{std::data(entry->d_name)};
        if (++scanned > WordReader::maximum_entries) {
          break;
        }

        if (!name.starts_with(partial) || (name.starts_with('.') && !partial.starts_with('.'))) {
          continue;
        }

        // Followed: a link to a directory lists as one. A dangling link is a file.
        struct stat state{};
        const bool listed = ::fstatat(entries.descriptor(), entry->d_name, &state, 0) == 0;
        const bool is_directory = listed && S_ISDIR(state.st_mode);
        const bool executable = listed && S_ISREG(state.st_mode) && ::faccessat(entries.descriptor(), entry->d_name, X_OK, 0) == 0;
        if ((request.provider == CompletionProvider::directory && !is_directory) || (request.provider == CompletionProvider::executable && !is_directory && !executable)) {
          continue;
        }

        word.assign(shown);
        word.append(name);
        if (is_directory) {
          word.push('/');
        }

        add(word.view());
      }
    }

  }

  WordResult::WordResult(tbc::mut_a<ConcurrentMemory> memory)
      : words(memory),
        command(memory),
        source(memory),
        expansion(memory) {}

  WordReader::WordReader(tbc::mut_a<ConcurrentMemory> memory, std::string_view configuration_directory)
      : memory_(memory),
        completions_(memory),
        git_(memory),
        compiled_(memory) {
    if (!configuration_directory.empty()) {
      completions_.assign(configuration_directory);
      completions_.append("/completions");
    }
  }

  tbc::val_a<WordReader::Result> WordReader::observe(const Request& request) noexcept { // NOLINT(bugprone-exception-escape): only the command's copy allocates outside the guarded calls, and a process without memory for it ends, as noexcept states
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
      collect(request, result);
    } catch (...) {
      result.words.clear();
    }

    return result;
  }

  void WordReader::collect(const Request& request, tbc::mut_a<Result> result) {
    const auto prefix = request.prefix.view();
    const auto add = [&](std::string_view word, std::string_view description = {}) {
      if (word.empty() || !word.starts_with(prefix) || word.size() > maximum_text_bytes || !printable(word)) {
        return;
      }

      // A bound on memory only: the reply is cut once everything is sorted.
      if (result.words.size() >= maximum_entries) {
        result.truncated = true;
        return;
      }

      result.words.push(Word{.text = Text{memory_, word}, .description = Text{memory_, printable(description) ? utf8Prefix(description, maximum_text_bytes) : std::string_view{}}});
    };

    const auto add_word = [&](std::string_view word) {
      add(word);
    };

    switch (request.provider) {
    case CompletionProvider::command:
      // The shell's own names first, so no PATH, however long, crowds them out.
      builtins(request.shell, add_word);
      if (request.names) {
        words(request.names->view(), add_word);
      } else {
        result.truncated = true;
      }

      commands({.path = request.path.view(), .prefix = prefix}, add);
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
      constexpr std::size_t stash_name_bytes = 32;

      git_.read(request.directory.view());
      const auto count = git_.stashes(maximum_words);

      for (std::size_t index = 0; index < count; ++index) {
        ds::Array<char, stash_name_bytes> stash{};
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
    case CompletionProvider::path:
    case CompletionProvider::directory:
    case CompletionProvider::executable:
      directoryEntries(memory_, request, add);
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
  }

  void WordReader::stop() noexcept {}

  void WordReader::spec(const Request& request, tbc::mut_a<Result> result) {
    auto name = request.prefix.view();
    if (!specName(name)) {
      return;
    }

    // An alias completes as the command it stands for.
    if (request.names && !request.remote) {
      result.expansion = expand(memory_, request.names->view(), name);
      if (!result.expansion.empty()) {
        name = result.expansion.view().substr(0, result.expansion.view().find(' '));
        if (!specName(name)) {
          result.expansion.clear();
          return;
        }
      }
    }

    if (!request.remote && !runs(request, name)) {
      result.expansion.clear();
      return;
    }

    auto source = userSpec(name);
    if (source.empty()) {
      const auto* const shipped = std::ranges::find(shipped::specs, name, &std::pair<std::string_view, std::string_view>::first);
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

  tbc::val_a<ds::String<ConcurrentMemory>> WordReader::userSpec(std::string_view name) {
    Text source{memory_};

    if (completions_.empty()) {
      return source;
    }

    FileDescriptor folder{::open(completions_.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
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

      constexpr std::size_t compiled_capacity = 256;

      if (compiled_.size() >= compiled_capacity) {
        compiled_.clear();
      }

      static_cast<void>(compiled_.insert(key, compiles));
    }

    if (!compiles) {
      source.clear();
    }

    return source;
  }

  WordService::WordService(tbc::mut_a<ConcurrentMemory> memory, std::string_view configuration_directory)
      : worker_(std::in_place, memory, configuration_directory),
        queue_(memory) {}

  ds::Option<std::uint64_t> WordService::request(tbc::holds<const WordRequest&, tbc::lt::a> request) {
    ds::Option<std::uint64_t> dropped;
    const auto waiting = queue_.waiting();

    if (std::cmp_greater_equal(std::ranges::count(waiting, request.client, &WordRequest::client), waiting_per_client)) {
      const auto oldest = std::ranges::find(waiting, request.client, &WordRequest::client)->request;

      queue_.dropWaiting([&](const WordRequest& entry) {
        return entry.client == request.client && entry.request == oldest;
      });
      dropped = oldest;
    }

    queue_.request(worker_, request);
    return dropped;
  }

  int WordService::descriptor() const noexcept {
    return worker_.descriptor();
  }

}
