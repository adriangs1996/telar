module telar.cli.worktree_git;

import telar.tbc;
import telar.cli.control_session;
import telar.client;
import telar.sys.posix;
import telar.base.memory.containers;
import telar.cli.server;
import telar.platform.error;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime::cli::repository {

  namespace {

    constexpr std::string_view scheme_separator = "://";

    // An origin's parts as written, before any of them is normalized.
    struct OriginParts {
      std::string_view scheme;
      std::string_view authority;
      std::string_view path;
    };

    // A URL with a scheme, or scp's `authority:path`, which is ssh.
    OriginParts originParts(std::string_view url) {
      const auto separator = url.find(scheme_separator);
      if (separator == std::string_view::npos) {
        const auto colon = url.find(':');
        if (colon == std::string_view::npos || url.substr(0, colon).contains('/')) {
          throw std::runtime_error{"UnsupportedOrigin"};
        }

        return {.scheme = "ssh", .authority = url.substr(0, colon), .path = url.substr(colon + 1)};
      }

      const auto scheme = url.substr(0, separator);
      const auto rest = url.substr(separator + scheme_separator.size());
      const auto slash = rest.find('/');
      if (asciiEqualIgnoreCase(scheme, "file") || slash == std::string_view::npos) {
        throw std::runtime_error{"UnsupportedOrigin"};
      }

      return {.scheme = scheme, .authority = rest.substr(0, slash), .path = rest.substr(slash)};
    }

    bool defaultPort(std::string_view scheme, std::string_view port) {
      return (asciiEqualIgnoreCase(scheme, "ssh") && port == "22") || (asciiEqualIgnoreCase(scheme, "https") && port == "443") || (asciiEqualIgnoreCase(scheme, "http") && port == "80");
    }

    // The authority's host, without credentials, and without the port when it is the scheme's default.
    std::string_view originHost(const OriginParts& parts) {
      const auto at_sign = parts.authority.rfind('@');
      auto host = parts.authority.substr(at_sign == std::string_view::npos ? 0 : at_sign + 1);
      std::size_t colon = std::string_view::npos;

      if (host.starts_with('[')) {
        const auto close = host.find(']');
        if (close == std::string_view::npos) {
          throw std::runtime_error{"UnsupportedOrigin"};
        }

        colon = close + 1;
        if (colon == host.size()) {
          host = host.substr(1, close - 1);
          colon = std::string_view::npos;
        }
      } else {
        colon = host.find(':');
      }

      if (colon != std::string_view::npos && colon < host.size() && defaultPort(parts.scheme, host.substr(colon + 1))) {
        host = host.starts_with('[') ? host.substr(1, colon - 2) : host.substr(0, colon);
      }

      return host;
    }

    // Rejects a tree entry's .gitattributes that routes files through Git LFS.
    void rejectLfsAttributes(Git& git, std::string_view line, std::size_t tab) {
      const auto name = line.substr(tab + 1);
      if (name != ".gitattributes" && !name.ends_with("/.gitattributes")) {
        return;
      }

      const auto space = line.rfind(' ', tab);
      if (space == std::string_view::npos) {
        throw std::runtime_error{"InvalidGitTree"};
      }

      const auto attributes = git.read({"cat-file", "blob", line.substr(space + 1, tab - space - 1)});
      if (attributes.view().contains("filter=lfs") || attributes.view().contains("filter = lfs")) {
        throw std::runtime_error{"LfsRepositoryUnsupported"};
      }
    }

  }

  tbc::val_a<Text> normalize(tbc::mut_a<Memory> memory, std::string_view url) {
    const auto parts = originParts(trimText(url, " \t\r\n"));
    const auto host = originHost(parts);
    auto path = trimText(parts.path, "/");
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

    return ds::format(memory, "{}/{}", AsciiLower{host}, path);
  }

  tbc::val_a<Text> sanitized(tbc::mut_a<Memory> memory, std::string_view origin) {
    if (origin.find_first_of("?#\r\n\t ") != std::string_view::npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    const auto separator = origin.find(scheme_separator);
    if (separator != std::string_view::npos) {
      const auto start = separator + scheme_separator.size();
      const auto slash = origin.find('/', start);
      if (slash == std::string_view::npos) {
        throw std::runtime_error{"UnsupportedOrigin"};
      }

      // An ssh user without a password is no credential: it stays.
      const auto authority = origin.substr(start, slash - start);
      const auto at_sign = authority.rfind('@');
      if (at_sign != std::string_view::npos && (!asciiEqualIgnoreCase(origin.substr(0, separator), "ssh") || authority.substr(0, at_sign).contains(':'))) {
        return ds::format(memory, "{}{}", origin.substr(0, start), origin.substr(start + at_sign + 1));
      }
    }

    return Text{memory, origin};
  }

  void ready(Git& git, std::string_view commit) {
    if (git.read({"rev-parse", "--is-shallow-repository"}) != "false") {
      throw std::runtime_error{"ShallowRepositoryUnsupported"};
    }

    const auto config = git.read({"config", "--local", "--name-only", "--list"});
    if (config.view().contains("extensions.partialclone") || config.view().contains(".promisor")) {
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
      if (tab != std::string_view::npos) {
        rejectLfsAttributes(git, line, tab);
      }

      if (end == std::string_view::npos) {
        break;
      }

      remaining.remove_prefix(end + 1);
    }

    git.read({"fsck", "--connectivity-only", "--no-reflogs", commit});
  }

}

namespace telar::runtime::cli::sessions {

  namespace {

    constexpr std::size_t workspace_command_words = 64;

    // A byte below the space or ASCII's DEL, which moves a terminal's cursor or erases.
    bool controlByte(char character) {
      constexpr unsigned char delete_byte = 0x7f;
      const auto byte = static_cast<unsigned char>(character);

      return byte < ' ' || byte == delete_byte;
    }

    // Whether a socket call failed for its timeout. POSIX lets EWOULDBLOCK differ from EAGAIN,
    // though Linux and macOS spell one error twice.
    bool timedOut(int error) noexcept {
      constexpr bool distinct_would_block = EWOULDBLOCK != EAGAIN;

      return error == EAGAIN || (distinct_would_block && error == EWOULDBLOCK);
    }

    // Git's output, handed on as it arrives; a write the terminal refuses does not fail the command.
    void forward(std::FILE* stream, std::span<const Byte> bytes) {
#pragma clang unsafe_buffer_usage begin
      static_cast<void>(std::fwrite(bytes.data(), 1, bytes.size(), stream));
#pragma clang unsafe_buffer_usage end
    }

  }

  void text(std::string_view value, std::size_t maximum, const char* error, bool empty) {
    try {
      validateUtf8(value);
    } catch (const EncodingError&) {
      usage(error);
    }

    if ((!empty && value.empty()) || value.size() > maximum) {
      usage(error);
    }
  }

  void printable(std::string_view value, std::size_t maximum) {
    text(value, maximum, "InvalidWorktreeText");
    for (const char character : value) {
      if (controlByte(character)) {
        usage("InvalidWorktreeText");
      }
    }
  }

  template <typename Text>
  void appendWorktreeCheckout(Text& path, std::string_view root, std::string_view branch) {
    path.append(root);
    path.append("-worktrees/");

    // A branch's separators would make directories: each becomes a dash.
    for (const char character : branch) {
      const char safe = character == '/' || character == '\\' ? '-' : character;

      path.append(std::string_view{&safe, 1});
    }
  }

  void branch(std::string_view value) {
    text(value, branch_bytes, "InvalidWorktreeBranch");
    if (value.front() == '-' || value.front() == '.' || value.contains("..")) {
      usage("InvalidWorktreeBranch");
    }

    for (const char character : value) {
      if (controlByte(character) || character == ' ' || character == '~' || character == '^' || character == ':') {
        usage("InvalidWorktreeBranch");
      }
    }
  }

  void single(tbc::mut_a<ds::Option<std::string_view>> field, tbc::val_a<std::string_view> value, const char* error) {
    if (field) {
      usage(error);
    }

    field = value;
  }

  tbc::val_a<Text> realDirectory(tbc::mut_a<Memory> memory, std::string_view path) {
    const Text given{memory, path};
    ds::Array<char, PATH_MAX> resolved{};
    if (::realpath(given.data(), resolved.dataMut()) == nullptr) {
      throw Failure{sys::errorName(sys::lastError())};
    }

    struct stat state{};
    if (::stat(resolved.data(), &state) != 0 || !S_ISDIR(state.st_mode)) {
      throw Failure{"NotDir"};
    }

    return Text{memory, std::string_view{resolved.data()}};
  }

  void wireTabLabel(std::string_view value, bool empty) {
    if ((!empty && value.empty()) || value.size() > tab_label_bytes) {
      throw Failure{"InvalidByteString"};
    }

    try {
      validateUtf8(value);
    } catch (const EncodingError&) {
      throw Failure{"InvalidUtf8"};
    }

    for (const char character : value) {
      if (controlByte(character)) {
        throw Failure{"InvalidTabLabel"};
      }
    }
  }

  void checkLocation(TabLocation actual, TabLocation expected) {
    if (actual.workspace.kind != expected.workspace.kind || actual.workspace.id != expected.workspace.id || actual.tab_id != expected.tab_id) {
      throw Failure{"unexpected reply from the runtime"};
    }
  }

  ClientDescriptor chooseClient(std::span<const ClientDescriptor> clients, std::uint64_t wanted) {
    ds::Option<ClientDescriptor> chosen;

    for (const auto& client : clients) {
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

  namespace {

    void workspaceEntry(Output& output, const WorkspaceListEntry& entry, bool json) {
      if (json) {
        output.text("{\"workspace_id\":").number(entry.workspace).text(",\"name\":").json(entry.name).text(",\"path\":").json(entry.path).text(",\"tab_count\":").number(entry.tab_count).text(",\"branch\":").json(entry.branch).text(",\"dirty\":").boolean(entry.dirty).text("}");
      } else {
        output.number(entry.workspace).text("\t").text(entry.name).text("\t").text(entry.path).text("\t").number(entry.tab_count).text("\t").text(entry.branch).text("\t").text(entry.dirty ? "dirty" : "clean").text("\n");
      }
    }

    void createWorkspace(Memory& memory, const WorkspaceOptions& options, Output& output) {
      const auto directory = realDirectory(memory, *options.directory);
      // The directory's own name, after its last separator; empty for the root.
      const auto default_name = directory.view().substr(directory.view().rfind('/') + 1);
      const auto name = options.name.valueOr(default_name);
      if (name.empty()) {
        throw Failure{"MissingWorkspaceName"};
      }

      if (options.command.size() > workspace_command_words) {
        throw Failure{"WorkspaceCommandTooLong"};
      }

      const auto login = loginShell();
      ds::Array<std::string_view, workspace_command_words> command;
      std::size_t count = 0;

      for (const auto* const word : options.command) {
        command.atMut(count++) = word;
      }

      if (count == 0) {
        command.atMut(count++) = login.view();
      }

      auto size = workspace_size;

      size.cols = options.columns.valueOr(size.cols);
      Channel session{memory, options.socket, true};

      wireTabLabel(name);
      const auto opened = session.template exchange<PaneOpened>(CreateWorkspace{.size = size, .name = name, .launch = {.cwd = directory, .arguments = std::span{command}.first(count)}}, false);

      if (options.json) {
        output.text("{\"workspace_id\":").number(opened.location.workspace.id).text(",\"tab_id\":").number(opened.location.tab_id).text(",\"pane_id\":").number(opened.pane_id).text(",\"directory\":").json(directory, JsonEscapes::control).text("}\n");
      } else {
        output.text("workspace ").number(opened.location.workspace.id).text(" created at ").text(directory).text("\n");
      }
    }

    void renameWorkspace(Memory& memory, const WorkspaceOptions& options, Output& output) {
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
    }

    void listWorkspaces(Memory& memory, const WorkspaceOptions& options, Output& output) {
      const auto wanted = options.action == WorkspaceOptions::Action::get ? ds::Option{options.target.resolve("TELAR_WORKSPACE_ID")} : ds::none;
      Channel session{memory, options.socket, false};
      const auto catalog = session.catalog();

      if (!wanted) {
        output.text(options.json ? "[" : "ID\tNAME\tDIRECTORY\tTABS\tBRANCH\tGIT\n");
      }

      bool first = true;

      for (const auto& entry : catalog.entries) {
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

  }

  int workspace(Memory& memory, const WorkspaceOptions& options) {
    try {
      using Action = WorkspaceOptions::Action;
      Output output{memory};

      if (options.action == Action::create) {
        createWorkspace(memory, options, output);
      } else if (options.action == Action::rename) {
        renameWorkspace(memory, options, output);
      } else {
        listWorkspaces(memory, options, output);
      }

      output.flush();
      return 0;
    } catch (const std::exception& error) {
      std::println(stderr, "telar workspace: {}", error.what());
      return 1;
    }
  }

  CoordinatorReference coordinatorReference(std::string_view value) {
    constexpr std::size_t session_hex_bytes = 32;
    if (value.size() <= session_hex_bytes || value[session_hex_bytes] != ':') {
      usage("InvalidCoordinatorReference");
    }

    constexpr std::size_t digits_per_byte = 2;
    constexpr int hexadecimal_base = 16;
    CoordinatorReference result;
    bool nonzero = false;

    for (std::size_t index = 0; index < result.session_id.size(); ++index) {
      unsigned byte{};
      const auto digits = value.substr(index * digits_per_byte, digits_per_byte);
      const auto* const end = std::to_address(digits.end());
      const auto parsed = std::from_chars(digits.data(), end, byte, hexadecimal_base);
      if (std::make_error_code(parsed.ec) || parsed.ptr != end) {
        usage("InvalidCoordinatorReference");
      }

      result.session_id.atMut(index) = static_cast<Byte>(byte);
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

  void machineLabel(std::string_view value) {
    const auto alphanumeric = [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9');
    };
    if (value.empty() || value.size() > machine_label_bytes || !alphanumeric(value.front())) {
      usage("InvalidMachineLabel");
    }

    for (const auto byte : value) {
      if (!alphanumeric(byte) && byte != '-' && byte != '_' && byte != '.') {
        usage("InvalidMachineLabel");
      }
    }
  }

}

namespace telar::runtime::cli::repository {

}

namespace telar::runtime::cli::sessions {

  template void appendWorktreeCheckout<ds::String<Memory>>(ds::String<Memory>& path, std::string_view root, std::string_view branch);

}

namespace telar::runtime::cli::repository {

  Git::Git(tbc::mut_a<Memory> memory, std::string_view root)
      : memory_(memory),
        git_(memory, root) {
    git_.inspect([&](Command<Memory>& command) {
      return execute(command, false);
    },
        [] [[noreturn]] {
          throw std::runtime_error{"GitFailed"};
        });
  }

  tbc::val_a<Text> Git::read(std::initializer_list<std::string_view> arguments) {
    return read(std::span<const std::string_view>{arguments});
  }

  tbc::val_a<Text> Git::read(std::span<const std::string_view> arguments) {
    auto [status, output] = git_.with(arguments, [&](Command<Memory>& command) {
      return execute(command, true);
    });
    if (status != 0) {
      throw std::runtime_error{"GitFailed"};
    }

    return Text{memory_, trimText(output, " \r\n")};
  }

  void Git::bundle(std::span<const std::string_view> revisions, int descriptor) {
    ds::Vec<std::string_view, Memory> args{memory_};

    args.extend(ds::Array<std::string_view, 3>{"bundle", "create", "-"}.view());
    args.extend(revisions);
    CommandOutput<Memory> output{memory_, max_git_output};
    std::size_t total = 0;
    const auto status = git_.with(args.view(), [&](Command<Memory>& command) {
      return output.stream(command, std::chrono::steady_clock::now() + git_timeout, [&](std::span<const Byte> bytes) {
        total += bytes.size();
        if (total > max_bundle_bytes) {
          reportCommandLimit({.name = "repository.max_bundle_bytes", .noun = "bytes", .value = max_bundle_bytes, .requested = total});
          throw std::runtime_error{"RepositoryBundleLimit"};
        }

        writeBytes(descriptor, bytes);
        return true;
      });
    });
    if (status != 0) {
      throw std::runtime_error{"GitFailed"};
    }
  }

  tbc::val_a<std::pair<int, Text>> Git::execute(Command<Memory>& command, bool bounded) {
    constexpr std::size_t max_configuration_bytes = std::size_t{64} * 1024;
    CommandOutput<Memory> output{memory_, bounded ? max_git_output : max_configuration_bytes};
    const auto status = output.run(command, std::chrono::steady_clock::now() + git_timeout, true);

    if (output.truncated()) {
      if (bounded) {
        reportCommandLimit({.name = "repository.max_git_output_bytes", .noun = "bytes", .value = max_git_output});
      }

      throw std::runtime_error{bounded ? "RepositoryGitOutputLimit" : "GitFailed"};
    }

    return {status, Text{memory_, output.text()}};
  }

}

namespace telar::runtime::cli::sessions {

  Target Target::parse(std::string_view value) {
    return {.id = value == "--current" ? ds::none : ds::Option{positive(value, "InvalidIdentity")}};
  }

  std::uint64_t Target::resolve(const char* variable) const {
    if (id) {
      return *id;
    }

    const auto* const value = std::getenv(variable); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
    if (value == nullptr) {
      throw std::runtime_error{"MissingCurrentIdentity"};
    }

    const auto number = maybeUnsigned(value);
    if (!number || *number == 0) {
      throw std::runtime_error{"InvalidIdentity"};
    }

    return *number;
  }

  namespace {

    WorkspaceOptions::Action workspaceAction(std::string_view verb) {
      using Action = WorkspaceOptions::Action;

      if (verb == "create") {
        return Action::create;
      }

      if (verb == "list") {
        return Action::list;
      }

      if (verb == "get") {
        return Action::get;
      }

      if (verb == "rename") {
        return Action::rename;
      }

      usage("UnknownWorkspaceAction");
    }

    // An option only `workspace create` takes; false when `arg` is none of them.
    bool workspaceCreateOption(tbc::mut_a<WorkspaceOptions> self, Cursor& cursor, std::string_view arg) {
      if (arg == "--columns") {
        const auto value = maybeUnsigned(cursor.take("MissingWorkspaceColumns"));
        constexpr unsigned minimum_columns = 20;
        constexpr unsigned maximum_columns = 1024;
        if (!value || *value < minimum_columns || *value > maximum_columns) {
          usage("InvalidWorkspaceColumns");
        }

        self.columns = static_cast<std::uint16_t>(*value);
      } else if (arg == "--worktree") {
        const auto value = cursor.take("MissingWorktreeBranch");

        single(self.worktree, value, "DuplicateWorktreeOption");
        branch(value);
      } else if (arg == "--name") {
        single(self.name, cursor.take("MissingWorkspaceName"), "DuplicateNameOption");
      } else if (arg == "--directory") {
        single(self.directory, cursor.take("MissingWorktreeDirectory"), "DuplicateDirectoryOption");
      } else {
        return false;
      }

      return true;
    }

    TabOptions::Action tabAction(std::string_view verb) {
      using Action = TabOptions::Action;

      if (verb == "list") {
        return Action::list;
      }

      if (verb == "get") {
        return Action::get;
      }

      if (verb == "create") {
        return Action::create;
      }

      if (verb == "rename") {
        return Action::rename;
      }

      if (verb == "close") {
        return Action::close;
      }

      if (verb == "move") {
        return Action::move;
      }

      usage("UnknownTabAction");
    }

    TabMoveDirection tabDirection(std::string_view direction) {
      if (direction == "previous") {
        return TabMoveDirection::previous;
      }

      if (direction == "next") {
        return TabMoveDirection::next;
      }

      usage("InvalidMoveDirection");
    }

    // An option of one tab action; false when `arg` is none of them.
    bool tabActionOption(tbc::mut_a<TabOptions> self, Cursor& cursor, std::string_view arg) {
      using Action = TabOptions::Action;

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
      } else {
        return false;
      }

      return true;
    }

    // An option every tab action takes; false when `arg` is none of them.
    bool tabCommonOption(tbc::mut_a<TabOptions> self, Cursor& cursor, std::string_view arg, bool& workspace_seen) {
      if (arg == "--workspace") {
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
        return false;
      }

      return true;
    }

  }

  WorkspaceOptions WorkspaceOptions::parse(Arguments words) {
    if (words.empty()) {
      usage("MissingWorkspaceAction");
    }

    WorkspaceOptions self;

    self.action = workspaceAction(words[0]);
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
      const bool create = self.action == Action::create;
      if (arg == "--" && create) {
        self.command = cursor.rest();
        if (self.command.empty()) {
          usage("MissingWorkspaceCommand");
        }

        break;
      }

      if (create && workspaceCreateOption(self, cursor, arg)) {
        continue;
      }

      if (arg == "--socket") {
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

  TabOptions TabOptions::parse(Arguments words) {
    if (words.empty()) {
      usage("MissingTabAction");
    }

    TabOptions self;

    self.action = tabAction(words[0]);
    Cursor cursor{words.subspan(1)};

    if (self.action != Action::list && self.action != Action::create) {
      self.target = Target::parse(cursor.take("MissingTabTarget"));
    }

    if (self.action == Action::rename) {
      self.label = cursor.take("MissingTabLabel");
      text(*self.label, tab_label_bytes, "InvalidTabLabel");
    }

    if (self.action == Action::move) {
      self.direction = tabDirection(cursor.take("MissingMoveDirection"));
    }

    bool workspace_seen = false;

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (!tabActionOption(self, cursor, arg) && !tabCommonOption(self, cursor, arg, workspace_seen)) {
        usage("UnknownTabOption");
      }
    }

    if (self.action == Action::create && !self.background) {
      usage("MissingClientId");
    }

    return self;
  }

  Channel::Channel(Memory& memory, ds::Option<std::string_view> socket, bool start)
      : paths_(memory, socketOptions(socket), process_environment) {
    ds::Option<RuntimeConnection> probe;
    if (start && !connectExisting(probe, paths_.socket.data()) && startRuntime(memory, socketOptions(socket), paths_) != RuntimeStart::listening) {
      throw Failure{"the local runtime is not reachable"};
    }

    try {
      session_.emplace(memory, paths_.socket.data());
    } catch (const SystemError& error) {
      throw Failure{connectionFailure(error.code())};
    }

    session_.getMut().receiveTimeout(reply_timeout_seconds);
  }

  WorkspaceList Channel::catalog() {
    try {
      session_.getMut().send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false});
      return session_.getMut().template receive<WorkspaceList>();
    } catch (...) {
      rethrowTranslated();
    }
  }

  const char* Channel::socket() const {
    return paths_.socket.data();
  }

  ControlSession& Channel::control() noexcept {
    return session_.getMut();
  }

  ServerOptions Channel::socketOptions(ds::Option<std::string_view> socket) {
    ServerOptions options;

    options.socket = socket.valueOr("");
    return options;
  }

  const char* Channel::connectionFailure(int code) noexcept {
    return sys::errorName(code, "the local runtime is not reachable");
  }

  void Channel::rethrowTranslated(bool reason) {
    try {
      throw;
    } catch (const ControlFailure& failure) {
      throw Failure{reason ? failure.message() : std::string_view{controlFailureDescription(failure.code())}, 1, failure.code()};
    } catch (const SocketError&) {
      if (timedOut(sys::lastError())) {
        throw Failure{"RuntimeTimeout", 3};
      }

      throw Failure{"unexpected reply from the runtime"};
    } catch (const EncodingError&) {
      throw Failure{"unexpected reply from the runtime"};
    } catch (const std::runtime_error& error) {
      if (std::string_view{error.what()} == "RuntimeStopping") {
        throw Failure{"RuntimeStopping"};
      }

      throw;
    }
  }

  WorktreeGit::WorktreeGit(tbc::mut_a<Memory> memory)
      : memory_(memory) {}

  tbc::val_a<Text> WorktreeGit::run(std::span<const std::string_view> arguments, const char* failure, bool stream, bool hardened, std::span<const std::pair<std::string_view, std::string_view>> environment) const {
    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::configured_helper};

    for (const auto& [name, value] : environment) {
      command.setEnvironment(name, value);
    }

    if (hardened) {
      HardenedGit<Memory>::configure(command);
    }

    constexpr std::size_t diagnostic_bytes = std::size_t{64} * 1024;
    constexpr std::size_t listing_bytes = std::size_t{1024} * 1024;
    constexpr unsigned git_timeout_seconds = 300;
    RetainedStream diagnostics{memory_, diagnostic_bytes};
    CommandOutput<Memory> output{memory_, listing_bytes};
    Text kept{memory_};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{git_timeout_seconds};
    const auto status = output.streamDiagnostics(command, deadline, [&](std::span<const Byte> bytes) {
      if (stream) {
        forward(stdout, bytes);
      } else {
        if (bytes.size() > listing_bytes - kept.size()) {
          throw Failure{"StreamTooLong"};
        }

        kept.append(textBytes(bytes));
      }

      return true;
    },
        [&](std::span<const Byte> bytes) {
          if (stream) {
            forward(stderr, bytes);
          } else {
            diagnostics.append(bytes);
          }
        });

    if (status != 0) {
      if (std::string_view{failure} != "NotARepository" && !stream) {
        ds::Array<Byte, diagnostic_bytes> bytes{};
        const auto tail = diagnostics.read(diagnostics.retainedOffset(), bytes.viewMut());

        if (diagnostics.retainedOffset() != 0) {
          std::println(stderr, "({} earlier bytes of Git's output omitted)", diagnostics.retainedOffset());
        }

        forward(stderr, tail);
      }

      throw Failure{failure};
    }

    return kept;
  }

  tbc::val_a<Text> WorktreeGit::run(std::initializer_list<std::string_view> arguments, const char* failure, bool stream, bool hardened) const {
    return run(std::span<const std::string_view>{arguments}, failure, stream, hardened);
  }

  tbc::val_a<Text> WorktreeGit::line(std::initializer_list<std::string_view> arguments, bool hardened) const {
    const auto value = run(arguments, "NotARepository", false, hardened);
    const auto trimmed = trimText(value.view(), " \r\n");
    if (trimmed.empty()) {
      throw Failure{"NotARepository"};
    }

    return Text{memory_, trimmed};
  }

  tbc::val_a<Text> WorktreeGit::root(std::string_view directory) const {
    auto common = line({"git", "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"});

    while (common.view().ends_with('/')) {
      common.truncate(common.size() - 1);
    }

    constexpr std::string_view suffix = "/.git";
    if (!common.view().starts_with('/') || !common.view().ends_with(suffix) || common.size() <= suffix.size()) {
      throw Failure{"not inside a git repository"};
    }

    common.truncate(common.size() - suffix.size());
    return common;
  }

  tbc::val_a<Text> WorktreeGit::currentBranch(std::string_view directory) const {
    return line({"git", "-C", directory, "rev-parse", "--abbrev-ref", "HEAD"});
  }

  bool WorktreeGit::succeeds(std::initializer_list<std::string_view> arguments, bool hardened) const {
    try {
      run(arguments, "NotARepository", false, hardened);
      return true;
    } catch (const std::exception&) {
      return false;
    }
  }

  void WorktreeGit::add(std::string_view root, std::string_view directory, std::string_view branch, std::string_view base) const {
    const auto reference = ds::format(memory_, "refs/heads/{}", branch);
    if (succeeds({"git", "-C", root, "rev-parse", "--verify", "--quiet", reference})) {
      run({"git", "-C", root, "worktree", "add", "--", directory, branch}, "git worktree add failed");
    } else {
      run({"git", "-C", root, "worktree", "add", "-b", branch, "--", directory, base}, "git worktree add failed");
    }
  }

  bool WorktreeGit::merged(std::string_view root, std::string_view branch) const {
    try {
      repository::Git git{memory_, root};
      // The branch's upstream when it has one, else what is checked out.
      const auto against = [&] -> Text {
        try {
          return git.read({"rev-parse", "--verify", "--quiet", "--end-of-options", ds::format(memory_, "{}@{{upstream}}", branch)});
        } catch (const std::exception&) {
          return Text{memory_, "HEAD"};
        }
      }();

      git.read({"merge-base", "--is-ancestor", ds::format(memory_, "refs/heads/{}", branch), against});
      return true;
    } catch (const std::exception&) {
      return false;
    }
  }

  namespace {

    WorktreeOptions::Action worktreeAction(std::string_view verb) {
      using Action = WorktreeOptions::Action;

      if (verb == "create") {
        return Action::create;
      }

      if (verb == "exec") {
        return Action::exec;
      }

      if (verb == "list") {
        return Action::list;
      }

      if (verb == "open") {
        return Action::open;
      }

      if (verb == "diff") {
        return Action::diff;
      }

      if (verb == "remove") {
        return Action::remove;
      }

      if (verb == "fetch") {
        return Action::fetch;
      }

      if (verb == "resolve") {
        return Action::resolve;
      }

      usage("UnknownWorktreeAction");
    }

    // The branch every action but list and resolve names first.
    void worktreeBranch(tbc::mut_a<WorktreeOptions> self, Cursor& cursor) {
      using Action = WorktreeOptions::Action;
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

    // The words after `--`: the command a created or exec'd worktree runs.
    void worktreeCommand(tbc::mut_a<WorktreeOptions> self, const Cursor& cursor) {
      using Action = WorktreeOptions::Action;

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
    }

    // An option only `worktree create` takes; false when `arg` is none of them.
    bool worktreeCreateOption(tbc::mut_a<WorktreeOptions> self, Cursor& cursor, std::string_view arg) {
      if (arg == "--setup") {
        self.setup = true;
      } else if (arg == "--title") {
        single(self.title, cursor.take("MissingWorktreeTitle"), "DuplicateWorktreeOption");
        printable(*self.title, title_bytes);
      } else if (arg == "--from") {
        single(self.from, cursor.take("MissingWorktreeBase"), "DuplicateWorktreeOption");
        sessions::branch(*self.from);
      } else if (arg == "--directory") {
        single(self.directory, cursor.take("MissingWorktreeDirectory"), "DuplicateWorktreeOption");
        if (!self.directory->starts_with('/')) {
          usage("RelativeWorktreeDirectory");
        }
      } else if (arg == "--dispatched-from") {
        single(self.dispatched_from, cursor.take("MissingMachineLabel"), "DuplicateWorktreeOption");
        printable(*self.dispatched_from, machine_label_bytes);
      } else if (arg == "--coordinator") {
        const auto value = cursor.take("MissingCoordinatorReference");

        if (self.coordinator) {
          usage("DuplicateWorktreeOption");
        }

        self.coordinator = coordinatorReference(value);
      } else {
        return false;
      }

      return true;
    }

    // A flag of one action that takes no value; false when `arg` is none of them.
    bool worktreeFlag(WorktreeOptions& self, std::string_view arg) {
      using Action = WorktreeOptions::Action;

      if (arg == "--uncommitted" && self.action == Action::diff) {
        self.uncommitted = true;
      } else if (arg == "--stat" && self.action == Action::diff) {
        self.stat = true;
      } else if (arg == "--force" && self.action == Action::remove) {
        self.force = true;
      } else if (arg == "--delete-branch" && self.action == Action::remove) {
        self.delete_branch = true;
      } else if (arg == "--wait" && self.action == Action::exec) {
        self.wait = true;
      } else {
        return false;
      }

      return true;
    }

    // `--timeout`'s seconds, with any `s` suffix.
    unsigned waitTimeout(Cursor& cursor) {
      auto value = cursor.take("MissingTimeout");

      while (value.ends_with('s')) {
        value.remove_suffix(1);
      }

      const auto seconds = maybeUnsigned(value);
      if (!seconds || *seconds == 0 || *seconds > max_wait_seconds) {
        usage("InvalidTimeout");
      }

      return static_cast<unsigned>(*seconds);
    }

    // An option several actions, or one other than create, take; false when `arg` is none of them.
    bool worktreeSharedOption(tbc::mut_a<WorktreeOptions> self, Cursor& cursor, std::string_view arg) {
      using Action = WorktreeOptions::Action;
      const auto action = self.action;
      if (arg == "--label" && (action == Action::create || action == Action::exec)) {
        single(self.label, cursor.take("MissingTabLabel"), "DuplicateWorktreeOption");
        printable(*self.label, tab_label_bytes);
      } else if (arg == "--machine" && (action == Action::create || action == Action::fetch)) {
        single(self.machine, cursor.take("MissingMachineLabel"), "DuplicateWorktreeOption");
        machineLabel(*self.machine);
      } else if (arg == "--repository" && action == Action::resolve) {
        single(self.repository, cursor.take("MissingRepository"), "DuplicateWorktreeOption");
        constexpr std::size_t repository_bytes = 512;

        printable(*self.repository, repository_bytes);
      } else if (arg == "--workspace" && (action == Action::create || action == Action::list || action == Action::resolve)) {
        single(self.workspace, cursor.take("MissingWorkspaceTarget"), "DuplicateWorktreeOption");
      } else if (arg == "--client" && action == Action::open) {
        self.client = positive(cursor.take("MissingClientId"), "InvalidClientId");
      } else if (arg == "--timeout" && action == Action::exec) {
        self.timeout = waitTimeout(cursor);
      } else if (arg == "--json") {
        self.json = true;
      } else if (arg == "--socket") {
        single(self.socket, cursor.take("MissingSocketPath"), "DuplicateWorktreeOption");
      } else {
        return false;
      }

      return true;
    }

  }

  WorktreeOptions WorktreeOptions::parse(Arguments words) {
    if (words.empty()) {
      usage("MissingWorktreeAction");
    }

    WorktreeOptions self;

    self.action = worktreeAction(words.front());
    Cursor cursor{words.subspan(1)};

    if (self.action != Action::list && self.action != Action::resolve) {
      worktreeBranch(self, cursor);
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--") {
        worktreeCommand(self, cursor);
        break;
      }

      const bool known = (self.action == Action::create && worktreeCreateOption(self, cursor, arg)) || worktreeFlag(self, arg) || worktreeSharedOption(self, cursor, arg);
      if (!known) {
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

  tbc::val_a<ds::Vec<GitWorktree, Memory>> WorktreeGit::listed(std::string_view directory, const WorktreeFilter& keep) const {
    const auto main = root(directory);
    const auto bytes = run({"git", "-C", main, "worktree", "list", "--porcelain"});
    ds::Vec<GitWorktree, Memory> result{memory_};
    std::string_view path;
    std::string_view branch;
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
          result.push(GitWorktree{.path = Text{memory_, path}, .branch = Text{memory_, branch}});
        }

        first = false;
        path = {};
        branch = {};
      }
    }

    return result;
  }

}
