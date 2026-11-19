module telar.cli.machine_ssh;

import telar.tbc;
import telar.cli.base.command_error;
import telar.cli.control_session;
import telar.platform.sha256;
import telar.sys.posix;
import telar.sys.process;
import telar.base.memory.containers;
import telar.cli.command_limit;
import telar.cli.server;
import telar.client;
import telar.platform.daemon;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime::cli::config_receive {

  constexpr std::size_t max_line_bytes = PATH_MAX + 64;

  bool acceptable(std::string_view path) {
    if (path.empty() || path.size() > PATH_MAX || path.front() == '/' || std::ranges::any_of(path, [](unsigned char byte) {
          return byte < 0x20 || byte == 0x7f || byte == '\\';
        })) {
      return false;
    }

    static constexpr auto roots = ds::Array<std::string_view, 6>{".claude/", ".codex/", ".pi/agent/", ".config/opencode/", ".cursor/", ".agents/skills/"};
    static constexpr auto session_directories = ds::Array<std::string_view, 10>{"projects", "sessions", "history", "todos", "shell-snapshots", "file-history", "statsig", "logs", "cache", "plans"};
    static constexpr auto credential_names = ds::Array<std::string_view, 15>{".claude.json", ".credentials.json", "auth.json", "mcp-auth.json", "credentials", ".netrc", ".npmrc", ".pypirc", ".pgpass", ".vault-token", ".git-credentials", "hosts.yml", "models.json", "keys.json", "sa.json"};
    static constexpr auto extensions = ds::Array<std::string_view, 11>{".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".jsonl", ".db", ".sqlite", ".sqlite3", ".log"};
    static constexpr auto fragments = ds::Array<std::string_view, 5>{"credential", "secret", "token", "password", "passwd"};
    const auto name = path.substr(path.rfind('/') == std::string_view::npos ? 0 : path.rfind('/') + 1);
    const auto is = [&](std::string_view candidate) {
      return asciiEqualIgnoreCase(name, candidate);
    };
    if (std::ranges::any_of(credential_names, is) || std::ranges::any_of(extensions, [&](auto extension) {
          return asciiEndsWithIgnoreCase(name, extension);
        }) ||
        std::ranges::any_of(fragments, [&](auto fragment) {
          return asciiContainsIgnoreCase(name, fragment);
        }) ||
        is(".env") || asciiStartsWithIgnoreCase(name, ".env.") || asciiEndsWithIgnoreCase(name, ".env") || asciiStartsWithIgnoreCase(name, "id_rsa") || asciiStartsWithIgnoreCase(name, "id_ed25519") || asciiStartsWithIgnoreCase(name, "id_ecdsa") || asciiStartsWithIgnoreCase(name, "id_dsa")) {
      return false;
    }

    for (const auto root : roots) {
      if (!path.starts_with(root) || path.size() == root.size()) {
        continue;
      }

      auto tail = path.substr(root.size());
      const auto first = tail.substr(0, tail.find('/'));
      if (std::ranges::any_of(session_directories, [&](auto directory) {
            return asciiEqualIgnoreCase(first, directory);
          })) {
        return false;
      }

      while (!tail.empty()) {
        const auto separator = tail.find('/');
        const auto component = tail.substr(0, separator);
        if (component.empty() || component.front() == '.' || std::ranges::any_of(credential_directories, [&](auto directory) {
              return asciiEqualIgnoreCase(component, directory);
            })) {
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

  FixedText<max_line_bytes> line() {
    ds::Array<char, max_line_bytes> bytes;
    std::size_t size = 0;
    char byte;

    while (std::cin.get(byte)) {
      if (byte == '\n') {
        FixedText<max_line_bytes> result;

        result.assign({bytes.data(), size});
        return result;
      }

      if (size == max_line_bytes) {
        throw CommandError{"InvalidConfigStream"};
      }

      bytes.atMut(size++) = byte;
    }

    throw CommandError{"InvalidConfigStream"};
  }

  // `name` as a C string, which a path component no longer than NAME_MAX always fits.
  ds::Array<char, NAME_MAX + 1> component(std::string_view name) {
    ds::Array<char, NAME_MAX + 1> bytes{};

    if (name.size() > NAME_MAX) {
      throw fileError(ENAMETOOLONG);
    }

    std::ranges::copy(name, bytes.dataMut());
    return bytes;
  }

  // Each directory is held by descriptor and opened with O_NOFOLLOW. A symlink
  // swapped in while receiving can never redirect the write outside HOME.
  bool place(int home, std::string_view path, std::string_view bytes, mode_t mode) {
    FileDescriptor parent{::openat(home, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!parent) {
      throw fileError(sys::lastError());
    }

    std::string_view tail{path};

    for (;;) {
      const auto slash = tail.find('/');
      if (slash == std::string_view::npos) {
        break;
      }

      const auto directory = component(tail.substr(0, slash));
      auto next = ::openat(parent.get(), directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (next < 0 && sys::lastError() == ENOENT) {
        if (::mkdirat(parent.get(), directory.data(), 0700) != 0 && sys::lastError() != EEXIST) {
          throw fileError(sys::lastError());
        }

        next = ::openat(parent.get(), directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      }

      if (next < 0) {
        if (sys::lastError() == ELOOP || sys::lastError() == ENOTDIR) {
          throw CommandError{"SymlinkOnTheWay"};
        }

        throw fileError(sys::lastError());
      }

      parent.reset(next);
      tail.remove_prefix(slash + 1);
    }

    const auto name = component(tail);
    struct stat state{};
    if (::fstatat(parent.get(), name.data(), &state, AT_SYMLINK_NOFOLLOW) == 0) {
      if (!S_ISREG(state.st_mode)) {
        throw CommandError{"NotARegularFile"};
      }

      if (state.st_size == static_cast<off_t>(bytes.size()) && (state.st_mode & 0777) == mode) {
        FileDescriptor existing{::openat(parent.get(), name.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
        if (!existing) {
          throw fileError(sys::lastError());
        }

        ds::Array<char, 16 * 1024> buffer;
        std::size_t offset = 0;
        bool same = true;

        for (;;) {
          const auto count = ::read(existing.get(), buffer.dataMut(), buffer.size());
          if (count < 0 && sys::lastError() == EINTR) {
            continue;
          }

          if (count < 0) {
            throw fileError(sys::lastError());
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
    } else if (sys::lastError() != ENOENT) {
      throw fileError(sys::lastError());
    }

    std::uint64_t nonce;

    randomBytes(&nonce, sizeof(nonce));
    ds::Array<char, 64> temporary;

    std::snprintf(temporary.dataMut(), temporary.size(), ".telar-%016llx", static_cast<unsigned long long>(nonce));
    FileDescriptor file{::openat(parent.get(), temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)};
    if (!file) {
      throw fileError(sys::lastError());
    }

    try {
      const auto error = writeDescriptor(file.get(), {reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size()});
      if (error != 0) {
        throw fileError(error);
      }

      if (::fchmod(file.get(), mode) != 0 || ::fsync(file.get()) != 0) {
        throw fileError(sys::lastError());
      }

      file.reset();
      if (::renameat(parent.get(), temporary.data(), parent.get(), name.data()) != 0) {
        throw fileError(sys::lastError());
      }
    } catch (...) {
      ::unlinkat(parent.get(), temporary.data(), 0);
      throw;
    }

    return true;
  }

  int run(Memory& memory) {
    const auto* home_path = std::getenv("HOME");
    if (!home_path) {
      throw CommandError{"HomeUnavailable"};
    }

    FileDescriptor home{::open(home_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!home) {
      throw fileError(sys::lastError());
    }

    if (line().view() != "telar-config 1") {
      throw CommandError{"InvalidConfigStream"};
    }

    std::size_t files = 0;
    std::size_t total = 0;
    DescriptorWriter output{STDOUT_FILENO};
    Text bytes{memory};

    for (;;) {
      const auto header = line();
      if (header.view() == "end") {
        output.flush();
        return 0;
      }

      std::string_view fields = header.view();
      ds::Array<std::string_view, 3> prefix;

      for (auto& field : prefix.viewMut()) {
        const auto end = fields.find(' ');
        if (end == std::string_view::npos) {
          throw CommandError{"InvalidConfigStream"};
        }

        field = fields.substr(0, end);
        fields.remove_prefix(end + 1);
      }

      const auto path = fields;

      if (prefix[0] != "file") {
        throw CommandError{"InvalidConfigStream"};
      }

      std::size_t size = 0;

      try {
        size = parseInt<std::size_t>(prefix[2]);
      } catch (const std::invalid_argument&) {
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

      bytes.resizeForOverwrite(size);
      char separator = 0;
      if (!std::cin.read(bytes.dataMut(), static_cast<std::streamsize>(size)) || !std::cin.get(separator) || separator != '\n') {
        throw CommandError{"InvalidConfigStream"};
      }

      if (!acceptable(path)) {
        output.print("refused {}: not a path the sync may write\n", path);
      } else {
        try {
          const auto written = place(home.get(), path, bytes, mode);

          output.print("{} {}\n", written ? "written" : "unchanged", path);
        } catch (const std::exception& error) {
          output.print("refused {}: {}\n", path, error.what());
        }
      }
    }
  }

}

namespace telar::runtime::cli::launch {

  constexpr std::size_t error_limit = 64 * 1024;

  tbc::view<Argv, tbc::lt::a> words(tbc::view<Memory&, tbc::lt::a> memory, std::initializer_list<std::string_view> words) {
    Argv result{memory};

    result.reserve(words.size());
    for (const auto word : words) {
      result.emplace(memory, word);
    }

    return result;
  }

  // The pointers exec takes, into the arguments' own bytes, which end with a NUL; the list ends
  // with a null pointer. They live in the first argument's allocator.
  ds::Vec<const char*, Memory> pointers(std::span<const Text> arguments) {
    if (arguments.empty()) {
      throw CommandError{"MissingProgram"};
    }

    ds::Vec<const char*, Memory> result{arguments.front().memory()};

    result.reserve(arguments.size() + 1);
    for (const auto& argument : arguments) {
      result.push(argument.data());
    }

    result.push(nullptr);
    return result;
  }

  [[noreturn]] void replace(std::span<const Text> arguments) {
    const auto argv = pointers(arguments);

    // exec takes char* const[] for C's sake and never writes through them.
    ::execvp(argv.front(), const_cast<char* const*>(argv.data()));
    throw CommandError{sys::errorName(sys::lastError())};
  }

  int inherit(std::span<const Text> arguments) {
    const auto argv = pointers(arguments);
    SpawnOptions spawn{0};

    spawn.keepStandardStreams();

    pid_t process = -1;
    if (const auto failure = ::posix_spawnp(&process, argv.front(), &spawn.actions, &spawn.attributes, const_cast<char* const*>(argv.data()), environ); failure != 0) {
      throw SystemError{"Start child process", failure};
    }

    int status = 0;

    while (::waitpid(process, &status, 0) < 0) {
      if (sys::lastError() != EINTR) {
        throw SystemError{"Wait for child process"};
      }
    }

    return WIFEXITED(status) ? WEXITSTATUS(status) : ssh_failure;
  }

  tbc::view<Text, tbc::lt::a> retained(tbc::view<Memory&, tbc::lt::a> memory, const RetainedStream<Memory>& stream) {
    Text text{memory};

    text.resizeForOverwrite(static_cast<std::size_t>(stream.total() - stream.retainedOffset()));
    static_cast<void>(stream.read(stream.retainedOffset(), {reinterpret_cast<Byte*>(text.dataMut()), text.size()}));
    return text;
  }

  Output::Output(Memory& memory)
      : out(memory),
        err(memory) {}

  tbc::view<Output, tbc::lt::a> capture(tbc::view<Memory&, tbc::lt::a> memory, std::span<const Text> arguments, std::string_view input, std::chrono::seconds timeout) {
    ds::Vec<std::string_view, Memory> words{memory};

    words.reserve(arguments.size());
    for (const auto& argument : arguments) {
      words.push(argument.view());
    }

    Command command{memory, Launch{.arguments = words.view()}, CommandPurpose::configured_helper};
    RetainedStream out{memory, output_limit};
    RetainedStream err{memory, error_limit};
    CommandOutput<Memory> process{memory, 0};
    const ds::Array pieces{input};
    Output result{memory};

    try {
      result.status = process.streamWithInput(
          command,
          std::chrono::steady_clock::now() + timeout,
          input.empty() ? std::span<const std::string_view>{} : std::span<const std::string_view>{pieces},
          [&](std::span<const Byte> bytes) {
            out.append(bytes);
            return true;
          },
          [&](std::span<const Byte> bytes) {
            err.append(bytes);
          }
      );
    } catch (const RequestError&) {
      throw CommandError{"Timeout"};
    }

    result.out = retained(memory, out);
    result.err = retained(memory, err);
    result.dropped = static_cast<std::size_t>(out.retainedOffset());
    return result;
  }

  tbc::view<Output, tbc::lt::a> captureFile(tbc::view<Memory&, tbc::lt::a> memory, std::span<const Text> arguments, int file, std::chrono::seconds timeout) {
    if (file < 0) {
      return capture(memory, arguments, {}, timeout);
    }

    struct stat status{};
    if (::fstat(file, &status) != 0) {
      throw SystemError{"Read process input"};
    }

    const auto size = static_cast<std::size_t>(status.st_size);
    const MappedRegion mapped{file, size, PROT_READ};
    if (size != 0 && !mapped) {
      throw SystemError{"Map process input"};
    }

    return capture(memory, arguments, {reinterpret_cast<const char*>(mapped.bytes().data()), size}, timeout);
  }

  void appendQuoted(Text& output, std::string_view value) {
    output.push('\'');
    for (const auto byte : value) {
      if (byte == '\'') {
        output.append("'\\''");
      } else {
        output.push(byte);
      }
    }

    output.push('\'');
  }

  Text quote(Memory& memory, std::string_view value) {
    Text result{memory};

    appendQuoted(result, value);
    return result;
  }

}

namespace telar::runtime::cli::machine {

  Text profilesPath(Memory& memory) {
    auto path = RuntimePaths<Memory>::configHome(memory, ProcessEnvironment{});
    if (path.empty()) {
      throw CommandError{"HomeUnavailable"};
    }

    path.append("/machines.json");
    return path;
  }

  MachineProfiles load(Memory& memory, const Text& path) {
    ds::Vec<unsigned char, Memory> source{memory};

    try {
      if (!readPrivateFile(AT_FDCWD, path.data(), source, MachineLimits::file_bytes)) {
        return {};
      }
    } catch (const SystemError& error) {
      if (error.code() == EACCES || error.code() == ELOOP || error.code() == EISDIR) {
        throw CommandError{"InsecureFile"};
      }

      if (error.code() == EFBIG) {
        throw CommandError{"StreamTooLong"};
      }

      throw fileError(error.code());
    }

    return MachineProfileCodec::parse(memory, {reinterpret_cast<const char*>(source.data()), source.size()});
  }

  LocalLabel localLabel(const MachineProfiles& profiles) {
    LocalLabel result;

    if (const auto label = profiles.localLabel()) {
      result.assign(*label);
      return result;
    }

    ds::Array<char, 256> name{};

    result.assign(::gethostname(name.dataMut(), name.size() - 1) == 0 ? std::string_view{name.data()} : std::string_view{"localhost"});
    return result;
  }

  void requireNotLocal(const MachineProfiles& profiles, std::string_view label) {
    if (label == localLabel(profiles).view()) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }

  MachineProfile newProfile(const MachineProfiles& profiles, const MachineOptions& options) {
    requireNotLocal(profiles, options.label);
    Random random;

    return MachineProfile::create(MachineId::generate(random), {
                                                                   .label = options.label,
                                                                   .destination = options.value,
                                                                   .color = options.color,
                                                                   .enabled = !options.disabled,
                                                               });
  }

  void change(MachineProfiles& profiles, const MachineOptions& options) {
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

  const char* describe(std::string_view error) {
    if (error == "SetupBinaryCompanionsMissing") {
      return "a C++ --binary needs telar-runtime and telar-config-check beside it";
    }

    if (error == "InsecureFile") {
      return MachineFailure::insecure_file.data();
    }

    const auto code = MachineFailure::named(error);
    const auto description = code ? MachineFailure::description(*code) : ds::none;

    return description ? description->data() : nullptr;
  }

  int report(const std::exception& error) {
    const auto* text = describe(error.what());

    std::fprintf(stderr, "telar machine: %s\n", text ? text : error.what());
    return 1;
  }

  int list(Memory& memory, const MachineProfiles& profiles, bool json) {
    if (json) {
      ds::String<Memory> output{memory};

      output.append("{\"local\":");
      appendJsonText(output, localLabel(profiles).view());
      output.append(",\"machines\":[");
      bool first = true;

      for (const auto& profile : profiles.rows()) {
        if (!first) {
          output.push(',');
        }

        first = false;
        MachineProfileCodec::appendProfile(output, profile);
      }

      output.append("]}\n");
      std::fwrite(output.data(), 1, output.size(), stdout);
    } else {
      const auto local = localLabel(profiles);

      std::printf("%.*s\tlocal\n", static_cast<int>(local.view().size()), local.view().data());
      for (const auto& profile : profiles.rows()) {
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

  constexpr auto endpoint_timeout = std::chrono::seconds{30};
  constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

  void appendEncoded(Text& result, std::string_view argument) {
    result.push('a');
    unsigned value = 0;
    unsigned bits = 0;

    for (const unsigned char byte : argument) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 6) {
        bits -= 6;
        result.push(alphabet[(value >> bits) & 63]);
      }
    }

    if (bits != 0) {
      result.push(alphabet[(value << (6 - bits)) & 63]);
    }
  }

  tbc::view<Text, tbc::lt::a> decode(tbc::view<Memory&, tbc::lt::a> memory, std::string_view word) {
    if (word.empty() || word.front() != 'a') {
      throw CommandError{"InvalidDispatchArgument"};
    }

    word.remove_prefix(1);
    if (word.size() % 4 == 1) {
      throw CommandError{"InvalidDispatchArgument"};
    }

    Text result{memory};
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

        result.push(decoded);
      }
    }

    if (bits != 0 && (value & ((1u << bits) - 1)) != 0) {
      throw CommandError{"InvalidDispatchArgument"};
    }

    return result;
  }

  // The options every connection to `destination` shares, including the
  // control master that keeps one SSH session per machine.
  void appendSshOptions(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<Argv&, tbc::lt::a> argv, std::string_view destination) {
    MachineFieldRules::destination(destination);
    const RuntimePaths paths{memory, ServerOptions{}, process_environment};

    paths.prepareSocket();
    const auto directory = std::string_view{paths.socket}.substr(0, paths.socket.view().rfind('/'));
    ds::Array<unsigned char, SHA256_DIGEST_LENGTH> digest;

    ::SHA256(reinterpret_cast<const unsigned char*>(destination.data()), destination.size(), digest.dataMut());
    std::uint64_t hash = 0;
    constexpr unsigned bits_per_byte = 8;
    constexpr unsigned control_hash_shift = 16;

    for (std::size_t index = 0; index < sizeof(hash); ++index) {
      hash |= static_cast<std::uint64_t>(digest[index]) << (index * bits_per_byte);
    }

    ds::Array<char, 32> name;

    std::snprintf(name.dataMut(), name.size(), "/ssh-%012llx", static_cast<unsigned long long>(hash >> control_hash_shift));
    for (const auto word : {"-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "ForwardAgent=no", "-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-o"}) {
      argv.emplace(memory, word);
    }

    argv.push(ds::format(memory, "ControlPath={}{}", directory, std::string_view{name.data()}));
  }

  tbc::view<Argv, tbc::lt::a> ssh(tbc::view<Memory&, tbc::lt::a> memory, std::string_view destination, std::string_view command, bool terminal) {
    auto argv = launch::words(memory, {"ssh", terminal ? "-t" : "-T"});

    appendSshOptions(memory, argv, destination);
    argv.emplace(memory, "--");
    argv.emplace(memory, destination);
    argv.emplace(memory, command);
    return argv;
  }

  tbc::view<Text, tbc::lt::a> gitSshCommand(tbc::view<Memory&, tbc::lt::a> memory, std::string_view destination) {
    Argv options{memory};
    Text command{memory, "ssh"};

    appendSshOptions(memory, options, destination);
    for (const auto& word : options) {
      if (word.view().contains('\'')) {
        throw CommandError{"UnquotableSshOption"};
      }

      ds::formatTo(command, " '{}'", word);
    }

    return command;
  }

  template <typename Words>
  tbc::view<Text, tbc::lt::a> remoteCommand(tbc::view<Memory&, tbc::lt::a> memory, const MachineProfile& profile, const Words& words) {
    auto command = ds::format(memory, "{} dispatch-argv", profile.program().valueOr("telar"));

    for (const std::string_view word : words) {
      command.push(' ');
      appendEncoded(command, word);
      if (command.size() > command_limit) {
        throw CommandError{"MachineCommandTooLong"};
      }
    }

    return command;
  }

  template <typename Words>
  int forward(Memory& memory, const MachineProfile& profile, const Words& words) {
    // A terminal there lets the command ask the person here, as a removal that needs
    // confirmation does. It merges stderr into stdout and writes \r\n, so it is only
    // given when both ends here are a terminal; anyone else gets none, as before.
    const bool terminal = ::isatty(STDIN_FILENO) && ::isatty(STDOUT_FILENO);

    return launch::inherit(ssh(memory, profile.destination(), remoteCommand(memory, profile, words), terminal).view());
  }

  template <typename Words>
  tbc::view<Text, tbc::lt::a> capture(tbc::view<Memory&, tbc::lt::a> memory, const MachineProfile& profile, const Words& words, const char* failure, int input) {
    constexpr auto capture_timeout = std::chrono::seconds{900};
    auto result = launch::captureFile(memory, ssh(memory, profile.destination(), remoteCommand(memory, profile, words)).view(), input, capture_timeout);

    std::fwrite(result.err.data(), 1, result.err.size(), stderr);
    if (result.status != 0 || result.dropped != 0) {
      throw CommandError{failure};
    }

    return std::move(result.out);
  }

  tbc::view<ds::Option<MachineProfile>, tbc::lt::a> resolve(tbc::view<Memory&, tbc::lt::a> memory, std::string_view label) {
    const auto profiles = load(memory, profilesPath(memory));
    if (const auto index = profiles.find(label)) {
      return profiles.rows()[*index];
    }

    if (label != localLabel(profiles).view()) {
      throw CommandError{"UnknownMachine"};
    }

    return ds::none;
  }

  MachineError sshFailure(const launch::Output& output) {
    if (output.err.view().contains("telar protocol mismatch")) {
      return MachineError::remote_runtime_incompatible;
    }

    if (output.status == 126 || output.status == 127) {
      return MachineError::remote_program_missing;
    }

    if (output.status == launch::ssh_failure) {
      if (output.err.view().contains("Host key verification failed") || output.err.view().contains("REMOTE HOST IDENTIFICATION HAS CHANGED")) {
        return MachineError::host_key_rejected;
      }

      if (output.err.view().contains("Permission denied (") || output.err.view().contains("Too many authentication failures")) {
        return MachineError::authentication_failed;
      }
    }

    return MachineError::endpoint_unavailable;
  }

  Discovery discover(Memory& memory, const MachineProfile& profile, Text& detail) {
    launch::Output output{memory};

    try {
      output = launch::capture(memory, ssh(memory, profile.destination(), MachineRemoteCommand::discovery(profile.program()).view()).view(), {}, endpoint_timeout);
    } catch (const std::exception&) {
      throw MachineFailure{MachineError::endpoint_unavailable};
    }

    constexpr std::size_t detail_limit = 1024;

    if (output.status != 0) {
      const auto failure = sshFailure(output);
      if (failure == MachineError::remote_program_missing) {
        detail.assign("telar is not on the PATH of non-interactive SSH sessions there: ");
      } else if (failure == MachineError::remote_runtime_incompatible) {
        detail.assign("the runtime there is another telar build; run `telar server stop` there: ");
      }

      if (failure == MachineError::host_key_rejected) {
        std::string_view lines = output.err.view();

        while (!lines.empty()) {
          const auto end = lines.find('\n');
          const auto line = lines.substr(0, end);
          if (line.contains("you have requested strict checking") || line.contains("Host key verification failed")) {
            ds::formatTo(detail, "{} ", trimText(line, " \t\r\n"));
          }

          if (end == std::string_view::npos) {
            break;
          }

          lines.remove_prefix(end + 1);
        }
      } else {
        detail.append(output.err);
      }

      detail.truncate(std::min(detail.size(), detail_limit));
      throw MachineFailure{failure};
    }

    try {
      if (output.dropped != 0) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }

      return Discovery::parse(output.out);
    } catch (const MachineFailure&) {
      detail.assign("`telar server endpoint` there printed something this telar cannot read; install the same telar build on both machines and keep shell startup files quiet");
      throw;
    }
  }

  int check(Memory& memory, const MachineProfile& profile, bool json) {
    Text detail{memory};
    ds::Option<Discovery> found;

    try {
      found = discover(memory, profile, detail);
    } catch (const MachineFailure& error) {
      if (json) {
        ds::String<Memory> output{memory};

        output.append("{\"label\":");
        appendJsonText(output, profile.label(), JsonEscapes::control);
        output.append(",\"reachable\":false,\"error\":");
        appendJsonText(output, error.what(), JsonEscapes::control);
        output.append(",\"detail\":");
        appendJsonText(output, trimText(detail, " \t\r\n"), JsonEscapes::control);
        output.append("}\n");
        std::fwrite(output.data(), 1, output.size(), stdout);
      } else {
        std::fprintf(stderr, "telar machine: %.*s (%.*s) is not reachable: %s\n%.*s\n", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), error.what(), static_cast<int>(trimText(detail, " \t\r\n").size()), trimText(detail, " \t\r\n").data());
      }

      return 1;
    }

    const std::string_view schema{reinterpret_cast<const char*>(found->schema().data()), found->schema().size()};
    const std::string_view local_schema{reinterpret_cast<const char*>(handshake::schema_id.data()), handshake::schema_id.size()};

    if (json) {
      ds::String<Memory> output{memory};

      output.append("{\"label\":");
      appendJsonText(output, profile.label(), JsonEscapes::control);
      ds::formatTo(output, ",\"reachable\":true,\"schema\":\"{}\",\"local_schema\":\"{}\",\"compatible\":", schema, local_schema);
      output.append(found->compatible() ? "true" : "false");
      for (const auto& [name, value] : ds::Array<std::pair<std::string_view, std::string_view>, 3>{{{"home", found->home()}, {"shell", found->shell()}, {"socket", found->endpoint()}}}) {
        output.append(",\"");
        output.append(name);
        output.append("\":");
        appendJsonText(output, value, JsonEscapes::control);
      }

      output.append("}\n");
      std::fwrite(output.data(), 1, output.size(), stdout);
    } else {
      DescriptorWriter output{STDOUT_FILENO};

      output.print("{}\t{}\treachable\n  home\t{}\n  shell\t{}\n  socket\t{}\n  schema\t{} (", profile.label(), profile.destination(), found->home(), found->shell(), found->endpoint(), schema);
      if (found->compatible()) {
        output.print("matches this telar)\n");
      } else {
        output.print("does not match this telar {}; update telar on one side)\n", local_schema);
      }

      output.flush();
    }

    return found->compatible() ? 0 : 1;
  }

}

namespace telar::runtime::cli::machine::filter {

  bool whitespace(char byte) {
    return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\v' || byte == '\f';
  }

  void noteOnce(Notes& notes, std::string_view name) {
    if (std::ranges::find(notes, name) == notes.end()) {
      notes.emplace(notes.memory(), name);
    }
  }

  enum class Kind {
    scalar,
    text,
    container,
  };

  bool secretKey(std::string_view name, Kind kind) {
    static constexpr auto dropped = ds::Array<std::string_view, 21>{"env", "environment", "headers", "http_headers", "env_http_headers", "auth", "authInfo", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper", "mcpServers", "mcp", "mcp_servers", "token", "accessToken", "access_token", "refreshToken", "refresh_token", "idToken", "id_token"};
    static constexpr auto fragments = ds::Array<std::string_view, 12>{"secret", "password", "passphrase", "apikey", "api_key", "api-key", "credential", "bearer", "private_key", "privatekey", "authorization", "cookie"};

    return std::ranges::find(dropped, name) != dropped.end() || std::ranges::any_of(fragments, [&](auto fragment) {
      return asciiContainsIgnoreCase(name, fragment);
    }) || (kind != Kind::scalar && (asciiContainsIgnoreCase(name, "token") || asciiContainsIgnoreCase(name, "auth")));
  }

  tbc::view<Text, tbc::lt::a> rewriteHome(tbc::view<Memory&, tbc::lt::a> memory, std::string_view bytes, std::string_view from, std::string_view to) {
    if (from.empty()) {
      throw CommandError{"HomeUnavailable"};
    }

    Text output{memory};

    for (;;) {
      const auto at = bytes.find(from);
      if (at == std::string_view::npos) {
        output.append(bytes);
        return output;
      }

      const auto after = at + from.size();
      const bool ends = after == bytes.size() || bytes[after] == '/' || bytes[after] == '"' || bytes[after] == '\'' || whitespace(bytes[after]);

      output.append(bytes.substr(0, at));
      output.append(ends ? to : from);
      bytes.remove_prefix(after);
    }
  }

  tbc::view<Text, tbc::lt::a> stripJsonc(tbc::view<Memory&, tbc::lt::a> memory, std::string_view bytes) {
    Text result{memory};
    bool string = false;

    for (std::size_t index = 0; index < bytes.size(); ++index) {
      const auto byte = bytes[index];

      if (string) {
        result.push(byte);
        if (byte == '\\' && index + 1 < bytes.size()) {
          result.push(bytes[++index]);
        } else if (byte == '"') {
          string = false;
        }
      } else if (byte == '"') {
        string = true;
        result.push(byte);
      } else if (bytes.substr(index).starts_with("//")) {
        index = bytes.find('\n', index);
        if (index == std::string_view::npos) {
          break;
        }

        result.push('\n');
      } else if (bytes.substr(index).starts_with("/*")) {
        const auto end = bytes.find("*/", index + 2);
        if (end == std::string_view::npos) {
          throw CommandError{"UnterminatedComment"};
        }

        index = end + 1;
      } else {
        result.push(byte);
      }
    }

    Text plain{memory};

    string = false;
    for (std::size_t index = 0; index < result.size(); ++index) {
      const auto byte = result[index];

      if (string) {
        plain.push(byte);
        if (byte == '\\' && index + 1 < result.size()) {
          plain.push(result[++index]);
        } else if (byte == '"') {
          string = false;
        }
      } else if (byte == '"') {
        string = true;
        plain.push(byte);
      } else if (byte == ',') {
        auto next = index + 1;

        while (next < result.size() && whitespace(result[next])) {
          ++next;
        }

        if (next == result.size() || (result[next] != '}' && result[next] != ']')) {
          plain.push(byte);
        }
      } else {
        plain.push(byte);
      }
    }

    return plain;
  }

  void json(Memory& memory, const JsonValue& value, ds::String<Memory>& output, Notes& dropped) {
    const auto source = value.encoded();
    ds::String<Memory> scratch{memory};

    if (source.starts_with('{')) {
      output.push('{');
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
          output.push(',');
        }

        first = false;
        output.append(key.encoded());
        output.push(':');
        json(memory, child, output, dropped);
      });

      output.push('}');
    } else if (source.starts_with('[')) {
      output.push('[');
      bool first = true;

      value.eachElement([&](JsonValue child) {
        if (!first) {
          output.push(',');
        }

        first = false;
        json(memory, child, output, dropped);
      });

      output.push(']');
    } else {
      output.append(source);
    }
  }

  std::size_t skipQuoted(std::string_view text, std::size_t start) {
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

    bool open() const {
      return delimiter != 0 || depth > 0;
    }

    void scan(std::string_view text) {
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

  // The part of a dotted TOML key that makes it secret, as a view of `path`.
  ds::Option<std::string_view> tomlSecret(std::string_view path, Kind last) {
    constexpr std::size_t max_components = 16;
    ds::Array<std::string_view, max_components> components;
    std::size_t count = 0;
    std::size_t start = 0;

    for (std::size_t index = 0; index <= path.size();) {
      if (index == path.size() || path[index] == '.') {
        if (count == max_components) {
          return path;
        }

        components.atMut(count++) = trimText(trimText(path.substr(start, index - start), " \t"), "\"'");
        start = ++index;
      } else {
        index = path[index] == '"' || path[index] == '\'' ? skipQuoted(path, index) + 1 : index + 1;
      }
    }

    static constexpr auto tables = ds::Array<std::string_view, 3>{"mcp_servers", "projects", "shell_environment_policy"};
    if (std::ranges::find(tables, components.front()) != tables.end()) {
      return components.front();
    }

    for (std::size_t index = 0; index < count; ++index) {
      if (secretKey(components[index], index + 1 == count ? last : Kind::container)) {
        return components[index];
      }
    }

    return ds::none;
  }

  tbc::view<Text, tbc::lt::a> toml(tbc::view<Memory&, tbc::lt::a> memory, std::string_view bytes, Notes& dropped) {
    bool skipping_table = false;
    bool dropping_value = false;
    bool first = true;
    TomlValue value;
    Text output{memory};

    for (;;) {
      const auto newline = bytes.find('\n');
      const auto line = bytes.substr(0, newline);
      bool keep = !skipping_table;

      if (value.open()) {
        value.scan(line);
        keep = keep && !dropping_value;
      } else {
        const auto text = trimText(line, " \t\r");
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

          skipping_table = offending.hasValue();
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
            const auto rest = trimText(text.substr(equals + 1), " \t");
            const auto kind = rest.empty() || rest.front() == '"' || rest.front() == '\'' ? Kind::text : rest.front() == '[' || rest.front() == '{' ? Kind::container
                                                                                                                                                    : Kind::scalar;
            const auto offending = tomlSecret(text.substr(0, equals), kind);

            dropping_value = offending.hasValue();
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
          output.push('\n');
        }

        first = false;
        output.append(line);
      }

      if (newline == std::string_view::npos) {
        break;
      }

      bytes.remove_prefix(newline + 1);
    }

    return output;
  }

  bool tokenByte(char byte) {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
  }

  bool placeholder(char byte) {
    return std::string_view{"$<{%[(*"}.contains(byte);
  }

  bool secretName(std::string_view name) {
    if (name.size() > 128) {
      return false;
    }

    const auto text = name;
    static constexpr auto names = ds::Array<std::string_view, 4>{"key", "auth", "pat", "pwd"};
    static constexpr auto fragments = ds::Array<std::string_view, 13>{"token", "secret", "passw", "api_key", "apikey", "api-key", "access_key", "accesskey", "private_key", "authorization", "credential", "webhook", "cookie"};
    static constexpr auto suffixes = ds::Array<std::string_view, 6>{"_key", "-key", "_header", "-header", "_app", "-app"};

    return std::ranges::any_of(names, [&](auto candidate) {
      return asciiEqualIgnoreCase(text, candidate);
    }) || std::ranges::any_of(fragments, [&](auto fragment) {
      return asciiContainsIgnoreCase(text, fragment);
    }) || std::ranges::any_of(suffixes, [&](auto suffix) {
      return asciiEndsWithIgnoreCase(text, suffix);
    }) || asciiStartsWithIgnoreCase(text, "auth_") ||
           asciiStartsWithIgnoreCase(text, "auth-");
  }

  ds::Option<std::string_view> nextWord(std::string_view& rest) {
    rest = trimText(rest, " \t");
    if (!rest.empty() && (rest.front() == '"' || rest.front() == '\'')) {
      rest.remove_prefix(1);
    }

    if (rest.empty() || placeholder(rest.front())) {
      return ds::none;
    }

    const auto end = rest.find_first_of(" \t\r\n\v\f\"',;");
    const auto word = rest.substr(0, end);

    rest.remove_prefix(end == std::string_view::npos ? rest.size() : end);
    return word;
  }

  bool literalValue(std::string_view rest, bool numbers) {
    auto word = nextWord(rest);
    if (!word) {
      return false;
    }

    const auto scheme = *word;
    if (asciiEqualIgnoreCase(scheme, "bearer") || asciiEqualIgnoreCase(scheme, "basic") || asciiEqualIgnoreCase(scheme, "token") || asciiEqualIgnoreCase(scheme, "digest")) {
      word = nextWord(rest);
    }

    if (!word || word->size() < 3) {
      return false;
    }

    const auto text = *word;
    if (asciiEqualIgnoreCase(text, "true") || asciiEqualIgnoreCase(text, "false") || asciiEqualIgnoreCase(text, "null") || asciiEqualIgnoreCase(text, "none") || asciiEqualIgnoreCase(text, "undefined")) {
      return false;
    }

    return numbers || std::ranges::any_of(*word, [](char byte) {
      return (byte < '0' || byte > '9') && byte != '.' && byte != '_';
    });
  }

  ds::Option<std::string_view> finding(std::string_view line) {

    if (line.contains("PRIVATE KEY-----")) {
      return "a private key";
    }

    static constexpr auto webhooks = ds::Array<std::string_view, 11>{"hooks.slack.com/services/", "hooks.slack.com/workflows/", "hooks.slack.com/triggers/", "discord.com/api/webhooks/", "discordapp.com/api/webhooks/", ".webhook.office.com/", "outlook.office.com/webhook", "hooks.zapier.com/hooks/", "api.telegram.org/bot", "chat.googleapis.com/v1/spaces/", "ntfy.sh/"};
    if (std::ranges::any_of(webhooks, [&](auto marker) {
          return asciiContainsIgnoreCase(line, marker);
        })) {
      return "a webhook URL, whose path is its key";
    }

    static constexpr auto prefixes = ds::Array<std::pair<std::string_view, std::size_t>, 21>{{{"ghp_", 20}, {"gho_", 20}, {"ghu_", 20}, {"ghs_", 20}, {"ghr_", 20}, {"github_pat_", 20}, {"glpat-", 20}, {"sk-", 20}, {"xoxb-", 10}, {"xoxp-", 10}, {"xoxa-", 10}, {"xoxr-", 10}, {"xoxs-", 10}, {"AKIA", 16}, {"ASIA", 16}, {"AIza", 30}, {"npm_", 30}, {"pypi-", 30}, {"hf_", 30}, {"r8_", 30}, {"tvly-", 20}}};

    for (const auto& [prefix, minimum] : prefixes) {
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
      const auto at = asciiFindIgnoreCase(line, "bearer", start);
      if (at == std::string_view::npos) {
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

    const bool database = asciiContainsIgnoreCase(line, "mysql") || asciiContainsIgnoreCase(line, "mariadb");
    auto words = line;
    bool after_user = false;

    while (!words.empty()) {
      words = trimText(words, " \t");
      const auto end = words.find_first_of(" \t");
      const auto word = trimText(words.substr(0, end), "\"'");
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

    const auto name_byte = [](char byte) {
      return tokenByte(byte) || byte == '.';
    };

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

      if (secretName(name) && literalValue(line.substr(cursor), !asciiContainsIgnoreCase(name, "token"))) {
        return "a value assigned to a secret-looking name";
      }
    }

    return ds::none;
  }

  ds::Option<std::pair<std::size_t, std::string_view>> findSecret(std::string_view bytes) {
    std::size_t number = 1;

    for (;;) {
      const auto end = bytes.find('\n');
      if (const auto found = finding(bytes.substr(0, end))) {
        return std::pair{number, *found};
      }

      if (end == std::string_view::npos) {
        return ds::none;
      }

      bytes.remove_prefix(end + 1);
      ++number;
    }
  }

}

namespace telar::runtime::cli {

  Text guiProgram(Memory& memory) {
    const auto found = ExecutablePath::sibling({"telar-gui", "../../MacOS/telar-gui"});

    return Text{memory, found ? found->view() : std::string_view{"telar-gui"}};
  }

  void relaunchLogin(Memory& memory, std::span<char* const> words) {
    if (std::getenv("TELAR_LOGIN_SHELL")) {
      return;
    }

    const auto shell = loginShell();
    const auto script = loginShellScript(shell.view());
    if (script.empty()) {
      return;
    }

    auto arguments = launch::words(memory, {shell.view(), "-l", "-c", script, ExecutablePath{}.c_str(), "gui"});

    for (const std::string_view word : words) {
      if (word != "--login-shell") {
        arguments.emplace(memory, word);
      }
    }

    ::setenv("TELAR_LOGIN_SHELL", "1", 1);
    launch::replace(arguments.view());
  }

  int openWindow(Memory& memory, const WindowOptions& options) {
#if defined(__APPLE__)
    const bool display = std::getenv("SSH_CONNECTION") == nullptr && std::getenv("SSH_TTY") == nullptr;
#else
    const auto* wayland = std::getenv("WAYLAND_DISPLAY");
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
        const auto profiles = machine::load(memory, machine::profilesPath(memory));
        if (!profiles.find(*options.machine) && machine::localLabel(profiles).view() != *options.machine) {
          std::fputs("telar gui: no saved machine or local label has that name; see telar machine list\n", stderr);
          return 1;
        }
      } catch (const std::exception& error) {
        std::fprintf(stderr, "telar gui: %s\n", error.what());
        return 1;
      }
    }

    ServerOptions server;

    server.config = options.config.valueOr(std::string_view{});
    server.no_config = options.no_config;
    server.profile = options.profile.valueOr(std::string_view{});
    server.fresh = options.fresh;
    const RuntimePaths paths{memory, server, process_environment};
    ds::Option<RuntimeConnection> connection;
    if (connectExisting(connection, paths.socket.data()) && options.fresh) {
      std::fprintf(stderr, "telar: a runtime is already running; stop it first (telar server stop) or drop --fresh\n");
      throw CommandError{"RuntimeAlreadyRunning"};
    }

    if (!connection) {
      paths.prepareSocket();
      const auto child = launchDaemon(memory, server, paths, ExecutablePath{runtime_program});
      constexpr auto start_timeout = std::chrono::seconds{10};
      constexpr auto retry_interval = std::chrono::milliseconds{10};
      const auto deadline = std::chrono::steady_clock::now() + start_timeout;

      while (!connectExisting(connection, paths.socket.data())) {
        int status = 0;
        if (::waitpid(child, &status, WNOHANG) == child || std::chrono::steady_clock::now() >= deadline) {
          throw CommandError{"RuntimeUnavailable"};
        }

        std::this_thread::sleep_for(retry_interval);
      }
    }

    connection.reset();
    ds::Array<char, PATH_MAX> cwd{};
    if (::getcwd(cwd.dataMut(), cwd.size()) == nullptr) {
      throw SystemError{"Read the working directory"};
    }

    launch::Argv arguments{memory};

    arguments.push(guiProgram(memory));
    for (const auto word : {std::string_view{"--socket"}, paths.socket.view(), std::string_view{"--cwd"}, std::string_view{cwd.data()}}) {
      arguments.emplace(memory, word);
    }

    for (const auto& [flag, value] : ds::Array<std::pair<std::string_view, const ds::Option<std::string_view>*>, 5>{{{"--config", &options.config}, {"--profile", &options.profile}, {"--theme", &options.theme}, {"--remote", &options.remote}, {"--machine", &options.machine}}}) {
      if (*value) {
        arguments.emplace(memory, flag);
        arguments.emplace(memory, **value);
      }
    }

    if (options.no_config) {
      arguments.emplace(memory, "--no-config");
    }

    if (options.fresh) {
      arguments.emplace(memory, "--fresh");
    }

    if (!options.command().empty()) {
      arguments.emplace(memory, "--");
      for (const auto word : options.command()) {
        arguments.emplace(memory, word);
      }
    }

    launch::replace(arguments.view());
  }

}

namespace telar::runtime::cli::machine {

  template int forward<std::span<char* const>>(Memory& memory, const MachineProfile& profile, const std::span<char* const>& words);

}

namespace telar::runtime::cli {

}

namespace telar::runtime::cli::machine {

  template Text remoteCommand<std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words);
  template int forward<std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words);
  template Text capture<std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words, const char* failure, int input);

}

namespace telar::runtime::cli::machine::filter {

}

namespace telar::runtime::cli::machine {

}

namespace telar::runtime::cli::launch {

  std::string_view Output::errorLine() const {
    const auto text = err.view();
    const auto end = text.find_last_not_of(" \r\n");
    if (end == std::string_view::npos) {
      return {};
    }

    const auto start = text.rfind('\n', end);
    const auto begin = start == std::string_view::npos ? 0 : start + 1;

    return text.substr(begin, end + 1 - begin);
  }

}

namespace telar::runtime::cli {

  MachineOptions MachineOptions::parse(std::span<char* const> args) {
    if (args.empty()) {
      throw std::invalid_argument{"MissingMachineAction"};
    }

    static constexpr ds::Array<std::string_view, 9> names{"add", "remove", "rename", "enable", "disable", "list", "check", "setup", "receive-config"};
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
      const auto value = [&] {
        return cursor.take("MissingMachineArgument");
      };

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
            result.skip.atMut(0) = true;
          } else if (name == "config") {
            result.skip.atMut(1) = true;
          } else if (name == "login") {
            result.skip.atMut(2) = true;
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

    if (action == Action::add && !result.setup && (result.binary || std::ranges::any_of(result.skip, [](bool value) {
          return value;
        }))) {
      throw std::invalid_argument{"SetupOptionWithoutSetup"};
    }

    return result;
  }

  std::string_view WindowOptions::canonicalTheme(std::string_view name) {
    static constexpr auto aliases = ds::Array<std::pair<std::string_view, std::string_view>, 8>{{{"catppuccin-mocha", "catppuccin"}, {"mocha", "catppuccin"}, {"tokyonight", "tokyo-night"}, {"tokyo_night", "tokyo-night"}, {"kanagawa-wave", "kanagawa"}, {"kanagawa_wave", "kanagawa"}, {"kanagawa_dragon", "kanagawa-dragon"}, {"default", "terminal"}}};

    for (const auto& [alias, canonical] : aliases) {
      if (asciiEqualIgnoreCase(name, alias)) {
        return canonical;
      }
    }

    static constexpr auto names = ds::Array<std::string_view, 11>{"shade", "vesper", "catppuccin", "tokyo-night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-dragon", "terminal", "cybervenom", "zenburn"};
    const auto found = std::ranges::find_if(names, [&](auto candidate) {
      return asciiEqualIgnoreCase(name, candidate);
    });
    if (found == names.end()) {
      throw std::invalid_argument{"UnknownTheme"};
    }

    return *found;
  }

  std::span<const std::string_view> WindowOptions::command() const noexcept {
    return command_words.view().first(command_count);
  }

  WindowOptions WindowOptions::parse(std::span<char* const> input, bool gui) {
    constexpr std::size_t maximum_arguments = 64;
    WindowOptions result;

    if (gui && input.size() > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    // The options take each flag once, and the command at most maximum_arguments words.
    ds::Array<std::string_view, 2 * maximum_arguments> args;
    std::size_t count = 0;

    for (const std::string_view word : input) {
      if (gui && word == "--login-shell") {
        result.login_shell = true;
      } else if (count == args.size()) {
        throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
      } else {
        args.atMut(count++) = word;
      }
    }

    const auto words = args.view().first(count);

    std::size_t index = 0;

    for (; index < words.size(); ++index) {
      const auto word = words[index];
      if (word == "--") {
        if (++index == words.size()) {
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
      ds::Option<std::string_view>* value = nullptr;
      const char* missing = nullptr;
      const char* duplicate = nullptr;

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
        if (++index == words.size()) {
          throw std::invalid_argument{missing};
        }

        text = words[index];
      }

      *value = flag == "--theme" ? canonicalTheme(text) : text;
    }

    if (words.size() - index > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    for (; index < words.size(); ++index) {
      result.command_words.atMut(result.command_count++) = words[index];
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

}

namespace telar::runtime::cli::machine {

  void Random::fill(std::span<std::uint8_t> bytes) {
    randomBytes(bytes.data(), bytes.size());
  }

}


