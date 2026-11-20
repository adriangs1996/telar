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

  namespace {

    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;

    // The modes a received file takes, and the bits of a mode that are its permissions.
    constexpr mode_t regular_file_mode = 0644;
    constexpr mode_t executable_file_mode = 0755;
    constexpr mode_t directory_mode = 0700;
    constexpr mode_t permission_bits = 0777;

    constexpr std::size_t compare_chunk_bytes = 16 * std::size_t{1024};
    constexpr std::size_t temporary_name_bytes = 64;

    constexpr int directory_flags = combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC);
    constexpr int home_flags = combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC);

    // A file the stream sends: where below HOME it goes, its contents and its mode.
    struct ReceivedFile {
      std::string_view path;
      std::string_view bytes;
      mode_t mode;
    };

  }

  bool acceptable(std::string_view path) {
    if (path.empty() || path.size() > PATH_MAX || path.front() == '/' || std::ranges::any_of(path, [](unsigned char byte) {
          return byte < first_printable || byte == delete_byte || byte == '\\';
        })) {
      return false;
    }

    static constexpr auto roots = ds::Array<std::string_view, 6>{".claude/", ".codex/", ".pi/agent/", ".config/opencode/", ".cursor/", ".agents/skills/"};
    static constexpr auto session_directories = ds::Array<std::string_view, 10>{"projects", "sessions", "history", "todos", "shell-snapshots", "file-history", "statsig", "logs", "cache", "plans"};
    static constexpr auto credential_names = ds::Array<std::string_view, 15>{".claude.json", ".credentials.json", "auth.json", "mcp-auth.json", "credentials", ".netrc", ".npmrc", ".pypirc", ".pgpass", ".vault-token", ".git-credentials", "hosts.yml", "models.json", "keys.json", "sa.json"};
    static constexpr auto extensions = ds::Array<std::string_view, 11>{".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".jsonl", ".db", ".sqlite", ".sqlite3", ".log"};
    static constexpr auto fragments = ds::Array<std::string_view, 5>{"credential", "secret", "token", "password", "passwd"};
    const auto name = path.substr(path.rfind('/') == std::string_view::npos ? 0 : path.rfind('/') + 1);
    const auto named = [&](std::string_view candidate) {
      return asciiEqualIgnoreCase(name, candidate);
    };
    if (std::ranges::any_of(credential_names, named) || std::ranges::any_of(extensions, [&](auto extension) {
          return asciiEndsWithIgnoreCase(name, extension);
        }) ||
        std::ranges::any_of(fragments, [&](auto fragment) {
          return asciiContainsIgnoreCase(name, fragment);
        }) ||
        named(".env") || asciiStartsWithIgnoreCase(name, ".env.") || asciiEndsWithIgnoreCase(name, ".env") || asciiStartsWithIgnoreCase(name, "id_rsa") || asciiStartsWithIgnoreCase(name, "id_ed25519") || asciiStartsWithIgnoreCase(name, "id_ecdsa") || asciiStartsWithIgnoreCase(name, "id_dsa")) {
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

  namespace {

    FixedText<max_line_bytes> line() {
      ds::Array<char, max_line_bytes> bytes{};
      std::size_t size = 0;
      char byte = 0;

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

    // The directory `name` in `parent`, created when missing, never through a symlink.
    FileDescriptor openDirectory(int parent, const char* name) {
      FileDescriptor next{::openat(parent, name, directory_flags)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!next && sys::lastError() == ENOENT) {
        if (::mkdirat(parent, name, directory_mode) != 0 && sys::lastError() != EEXIST) {
          throw fileError(sys::lastError());
        }

        next.reset(::openat(parent, name, directory_flags)); // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      }

      if (!next) {
        if (sys::lastError() == ELOOP || sys::lastError() == ENOTDIR) {
          throw CommandError{"SymlinkOnTheWay"};
        }

        throw fileError(sys::lastError());
      }

      return next;
    }

    // The directory that holds `path`, each directory on the way held by descriptor and opened with
    // O_NOFOLLOW, so that a symlink swapped in while receiving can never redirect the write outside HOME.
    FileDescriptor openParent(int home, std::string_view path) {
      FileDescriptor parent{::openat(home, ".", directory_flags)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!parent) {
        throw fileError(sys::lastError());
      }

      std::string_view tail{path};

      for (;;) {
        const auto slash = tail.find('/');
        if (slash == std::string_view::npos) {
          return parent;
        }

        const auto directory = component(tail.substr(0, slash));

        parent = openDirectory(parent.get(), directory.data());
        tail.remove_prefix(slash + 1);
      }
    }

    // Whether the open file holds exactly `bytes`.
    bool holdsBytes(int descriptor, std::string_view bytes) {
      ds::Array<char, compare_chunk_bytes> buffer{};
      std::size_t offset = 0;

      for (;;) {
        const auto count = ::read(descriptor, buffer.dataMut(), buffer.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count < 0) {
          throw fileError(sys::lastError());
        }

        if (count == 0) {
          return offset == bytes.size();
        }

        const auto size = static_cast<std::size_t>(count);
        if (offset > bytes.size() || size > bytes.size() - offset || bytes.substr(offset, size) != std::string_view{buffer.data(), size}) {
          return false;
        }

        offset += size;
      }
    }

    // Whether `name` in `parent` already is the regular file `file` describes; a file of another
    // kind there refuses the write.
    bool unchanged(int parent, const char* name, const ReceivedFile& file) {
      struct stat state{};
      if (::fstatat(parent, name, &state, AT_SYMLINK_NOFOLLOW) != 0) {
        if (sys::lastError() != ENOENT) {
          throw fileError(sys::lastError());
        }

        return false;
      }

      if (!S_ISREG(state.st_mode)) {
        throw CommandError{"NotARegularFile"};
      }

      if (!std::cmp_equal(state.st_size, file.bytes.size()) || (state.st_mode & permission_bits) != file.mode) {
        return false;
      }

      FileDescriptor existing{::openat(parent, name, combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!existing) {
        throw fileError(sys::lastError());
      }

      return holdsBytes(existing.get(), file.bytes);
    }

    // Writes the file beside `name` and renames it over `name`, so a reader never sees half of it.
    void replace(int parent, const char* name, const ReceivedFile& file) {
      std::uint64_t nonce = 0;

      randomBytes(&nonce, sizeof(nonce));
      ds::Array<char, temporary_name_bytes> temporary{};

      std::format_to_n(temporary.dataMut(), temporary.size() - 1, ".telar-{:016x}", nonce);
      FileDescriptor descriptor{::openat(parent, temporary.data(), combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC), file.mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!descriptor) {
        throw fileError(sys::lastError());
      }

      try {
        const auto error = writeDescriptor(descriptor.get(), byteView(file.bytes));
        if (error != 0) {
          throw fileError(error);
        }

        if (::fchmod(descriptor.get(), file.mode) != 0 || ::fsync(descriptor.get()) != 0) {
          throw fileError(sys::lastError());
        }

        descriptor.reset();
        if (::renameat(parent, temporary.data(), parent, name) != 0) {
          throw fileError(sys::lastError());
        }
      } catch (...) {
        ::unlinkat(parent, temporary.data(), 0);
        throw;
      }
    }

    // Writes the file below HOME unless it already holds the same bytes and mode; true when it wrote.
    bool place(int home, const ReceivedFile& file) {
      const auto parent = openParent(home, file.path);
      const auto name = component(file.path.substr(file.path.rfind('/') + 1));
      if (unchanged(parent.get(), name.data(), file)) {
        return false;
      }

      replace(parent.get(), name.data(), file);
      return true;
    }

    // The mode the stream names, or 0 for one it may not send.
    mode_t streamMode(std::string_view text) noexcept {
      if (text == "644") {
        return regular_file_mode;
      }

      if (text == "755") {
        return executable_file_mode;
      }

      return 0;
    }

    // A file's header line, `file MODE SIZE PATH`: its path, its size and the mode it names.
    struct FileHeader {
      std::string_view path;
      std::size_t size = 0;
      mode_t mode = 0;
    };

    FileHeader parseHeader(std::string_view fields) {
      ds::Array<std::string_view, 3> prefix;

      for (auto& field : prefix.viewMut()) {
        const auto end = fields.find(' ');
        if (end == std::string_view::npos) {
          throw CommandError{"InvalidConfigStream"};
        }

        field = fields.substr(0, end);
        fields.remove_prefix(end + 1);
      }

      if (prefix[0] != "file") {
        throw CommandError{"InvalidConfigStream"};
      }

      FileHeader header{.path = fields, .mode = streamMode(prefix[1])};

      try {
        header.size = parseInt<std::size_t>(prefix[2]);
      } catch (const std::invalid_argument&) {
        throw CommandError{"InvalidConfigStream"};
      }

      return header;
    }

    // Writes the received file where the sync may, and reports what became of it.
    void receive(int home, const ReceivedFile& file, DescriptorWriter& output) {
      if (!acceptable(file.path)) {
        output.print("refused {}: not a path the sync may write\n", file.path);
        return;
      }

      try {
        const auto written = place(home, file);

        output.print("{} {}\n", written ? "written" : "unchanged", file.path);
      } catch (const std::exception& error) {
        output.print("refused {}: {}\n", file.path, error.what());
      }
    }

  }

  int run(Memory& memory) {
    const auto* home_path = std::getenv("HOME"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
    if (home_path == nullptr) {
      throw CommandError{"HomeUnavailable"};
    }

    FileDescriptor home{::open(home_path, home_flags)}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
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
      const auto line_text = line();
      if (line_text.view() == "end") {
        output.flush();
        return 0;
      }

      const auto header = parseHeader(line_text.view());
      if (header.size > max_file_bytes || header.size > max_total_bytes - total || ++files > max_files) {
        throw CommandError{"ConfigStreamTooLarge"};
      }

      total += header.size;
      if (header.mode == 0 || header.path.size() > PATH_MAX) {
        throw CommandError{"InvalidConfigStream"};
      }

      bytes.resizeForOverwrite(header.size);
      char separator = 0;
      if (!std::cin.read(bytes.dataMut(), static_cast<std::streamsize>(header.size)) || !std::cin.get(separator) || separator != '\n') {
        throw CommandError{"InvalidConfigStream"};
      }

      receive(home.get(), {.path = header.path, .bytes = bytes, .mode = header.mode}, output);
    }
  }

}

namespace telar::runtime::cli::launch {

  constexpr std::size_t error_limit = 64 * std::size_t{1024};

  tbc::val_a<Argv> words(tbc::mut_a<Memory> memory, std::initializer_list<std::string_view> words) {
    Argv result{memory};

    result.reserve(words.size());
    for (const auto word : words) {
      result.emplace(memory, word);
    }

    return result;
  }

  namespace {

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

    // The bytes of `text` for a stream to fill.
    tbc::val_a<std::span<Byte>> writableBytes(tbc::val_a<std::span<char>> text) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {reinterpret_cast<Byte*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): Byte may alias char, and no cast-free view writes text as bytes
#pragma clang unsafe_buffer_usage end
    }

    tbc::val_a<Text> retained(tbc::mut_a<Memory> memory, const RetainedStream<Memory>& stream) {
      Text text{memory};

      text.resizeForOverwrite(static_cast<std::size_t>(stream.total() - stream.retainedOffset()));
      static_cast<void>(stream.read(stream.retainedOffset(), writableBytes(text.viewMut())));
      return text;
    }

  }

  [[noreturn]] void replace(std::span<const Text> arguments) {
    const auto argv = pointers(arguments);

    // exec takes char* const[] for C's sake and never writes through them.
    ::execvp(argv.front(), const_cast<char* const*>(argv.data())); // NOLINT(cppcoreguidelines-pro-type-const-cast): exec's C signature takes char* const[] and never writes through it
    throw CommandError{sys::errorName(sys::lastError())};
  }

  int inherit(std::span<const Text> arguments) {
    const auto argv = pointers(arguments);
    SpawnOptions spawn{0};

    spawn.keepStandardStreams();

    pid_t process = -1;
    if (const auto failure = ::posix_spawnp(&process, argv.front(), &spawn.actions, &spawn.attributes, const_cast<char* const*>(argv.data()), environ); failure != 0) { // NOLINT(cppcoreguidelines-pro-type-const-cast): posix_spawnp's C signature takes char* const[] and never writes through it
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

  Output::Output(Memory& memory)
      : out(memory),
        err(memory) {}

  tbc::val_a<Output> capture(tbc::mut_a<Memory> memory, std::span<const Text> arguments, std::string_view input, std::chrono::seconds timeout) {
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

  tbc::val_a<Output> captureFile(tbc::mut_a<Memory> memory, std::span<const Text> arguments, int file, std::chrono::seconds timeout) {
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

    return capture(memory, arguments, textView(mapped.bytes()), timeout);
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

    return MachineProfileCodec::parse(memory, textView(source.view()));
  }

  LocalLabel localLabel(const MachineProfiles& profiles) {
    LocalLabel result;

    if (const auto label = profiles.localLabel()) {
      result.assign(*label);
      return result;
    }

    ds::Array<char, local_label_bytes> name{};

    result.assign(::gethostname(name.dataMut(), name.size() - 1) == 0 ? std::string_view{name.data()} : std::string_view{"localhost"});
    return result;
  }

  namespace {

    void requireNotLocal(const MachineProfiles& profiles, std::string_view label) {
      if (label == localLabel(profiles).view()) {
        throw MachineFailure{MachineError::duplicate_label};
      }
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
      return;
    case MachineOptions::Action::remove:
      profiles.remove(options.label);
      return;
    case MachineOptions::Action::rename:
      requireNotLocal(profiles, options.value);
      profiles.rename(options.label, options.value);
      return;
    case MachineOptions::Action::enable:
    case MachineOptions::Action::disable:
      profiles.enable(options.label, options.action == MachineOptions::Action::enable);
      return;
    case MachineOptions::Action::list:
    case MachineOptions::Action::check:
    case MachineOptions::Action::setup:
    case MachineOptions::Action::receive_config:
      break;
    }

    // An action that edits no profile, or one outside the enum.
    throw std::logic_error{"Expected a machine profile edit"};
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

    std::println(stderr, "telar machine: {}", (text != nullptr) ? text : error.what());
    return 1;
  }

  namespace {

    void printListJson(Memory& memory, const MachineProfiles& profiles) {
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
      std::print(stdout, "{}", output.view());
    }

    void printListRow(const MachineProfile& profile) {
      std::print(stdout, "{}\t{}\t{}", profile.label(), profile.destination(), profile.enabled() ? "enabled" : "disabled");
      if (const auto color = profile.color()) {
        std::print(stdout, "\t{}", *color);
      }

      bool first = true;

      for (const auto agent : machine_agents) {
        if (const auto login = profile.login(agent)) {
          std::print(stdout, "{}{} {}", first ? "\tlogins: " : ", ", machine_agent_names.at(static_cast<std::size_t>(agent)), machine_login_names.at(static_cast<std::size_t>(*login)));
          first = false;
        }
      }

      std::putchar('\n');
    }

  }

  int list(Memory& memory, const MachineProfiles& profiles, bool json) {
    if (json) {
      printListJson(memory, profiles);
      return 0;
    }

    std::println(stdout, "{}\tlocal", localLabel(profiles).view());
    for (const auto& profile : profiles.rows()) {
      printListRow(profile);
    }

    return 0;
  }

  constexpr auto endpoint_timeout = std::chrono::seconds{30};
  constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

  namespace {

    // A byte of the argument and a digit of its encoding, each as bits and as the mask of them.
    constexpr unsigned bits_per_byte = 8;
    constexpr unsigned byte_mask = 0xff;
    constexpr unsigned bits_per_digit = 6;
    constexpr unsigned digit_mask = 0x3f;

  }

  void appendEncoded(Text& result, std::string_view argument) {
    result.push('a');
    unsigned value = 0;
    unsigned bits = 0;

    for (const auto character : argument) {
      value = (value << bits_per_byte) | static_cast<unsigned char>(character);
      bits += bits_per_byte;
      while (bits >= bits_per_digit) {
        bits -= bits_per_digit;
        result.push(alphabet[(value >> bits) & digit_mask]);
      }
    }

    if (bits != 0) {
      result.push(alphabet[(value << (bits_per_digit - bits)) & digit_mask]);
    }
  }

  tbc::val_a<Text> decode(tbc::mut_a<Memory> memory, std::string_view word) {
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

      value = (value << bits_per_digit) | static_cast<unsigned>(digit);
      bits += bits_per_digit;
      if (bits >= bits_per_byte) {
        bits -= bits_per_byte;
        const auto decoded = static_cast<char>((value >> bits) & byte_mask);
        if (decoded == '\0') {
          throw CommandError{"InvalidDispatchArgument"};
        }

        result.push(decoded);
      }
    }

    if (bits != 0 && (value & ((1U << bits) - 1)) != 0) {
      throw CommandError{"InvalidDispatchArgument"};
    }

    return result;
  }

  namespace {

    // The options every connection to `destination` shares, including the
    // control master that keeps one SSH session per machine.
    void appendSshOptions(tbc::mut_a<Memory> memory, tbc::mut_a<Argv> argv, std::string_view destination) {
      MachineFieldRules::destination(destination);
      const ServerOptions server_options{};
      const RuntimePaths<Memory> paths{memory, server_options, process_environment};

      paths.prepareSocket();
      const auto directory = std::string_view{paths.socket}.substr(0, paths.socket.view().rfind('/'));
      ds::Array<unsigned char, SHA256_DIGEST_LENGTH> digest{};

      ::SHA256(byteView(destination).data(), destination.size(), digest.dataMut());
      std::uint64_t hash = 0;
      constexpr unsigned control_hash_shift = 16;
      constexpr std::size_t control_name_bytes = 32;

      for (std::size_t index = 0; index < sizeof(hash); ++index) {
        hash |= static_cast<std::uint64_t>(digest[index]) << (index * bits_per_byte);
      }

      ds::Array<char, control_name_bytes> name{};

      std::format_to_n(name.dataMut(), name.size() - 1, "/ssh-{:012x}", hash >> control_hash_shift);
      for (const auto* const word : {"-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "ForwardAgent=no", "-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-o"}) {
        argv.emplace(memory, word);
      }

      argv.push(ds::format(memory, "ControlPath={}{}", directory, std::string_view{name.data()}));
    }

  }

  tbc::val_a<Argv> ssh(tbc::mut_a<Memory> memory, std::string_view destination, std::string_view command, bool terminal) {
    auto argv = launch::words(memory, {"ssh", terminal ? "-t" : "-T"});

    appendSshOptions(memory, argv, destination);
    argv.emplace(memory, "--");
    argv.emplace(memory, destination);
    argv.emplace(memory, command);
    return argv;
  }

  tbc::val_a<Text> gitSshCommand(tbc::mut_a<Memory> memory, std::string_view destination) {
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
  tbc::val_a<Text> remoteCommand(tbc::mut_a<Memory> memory, const MachineProfile& profile, const Words& words) {
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
  tbc::val_a<Text> capture(tbc::mut_a<Memory> memory, const MachineProfile& profile, const Words& words, const char* failure, int input) {
    constexpr auto capture_timeout = std::chrono::seconds{900};
    auto result = launch::captureFile(memory, ssh(memory, profile.destination(), remoteCommand(memory, profile, words)).view(), input, capture_timeout);

    std::print(stderr, "{}", result.err.view());
    if (result.status != 0 || result.dropped != 0) {
      throw CommandError{failure};
    }

    return std::move(result.out);
  }

  tbc::val_a<ds::Option<MachineProfile>> resolve(tbc::mut_a<Memory> memory, std::string_view label) {
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

    // The shell's statuses for a program it found but could not run, and for one it did not find.
    constexpr int not_executable_status = 126;
    constexpr int not_found_status = 127;

    if (output.status == not_executable_status || output.status == not_found_status) {
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

  namespace {

    // What the person needs to know of a failed discovery: a hint at the cause, then what SSH said
    // of it.
    void describeFailure(Text& detail, const launch::Output& output, MachineError failure) {
      if (failure == MachineError::remote_program_missing) {
        detail.assign("telar is not on the PATH of non-interactive SSH sessions there: ");
      } else if (failure == MachineError::remote_runtime_incompatible) {
        detail.assign("the runtime there is another telar build; run `telar server stop` there: ");
      }

      if (failure != MachineError::host_key_rejected) {
        detail.append(output.err);
        return;
      }

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
    }

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

      describeFailure(detail, output, failure);
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
        output.append(R"(,"reachable":false,"error":)");
        appendJsonText(output, error.what(), JsonEscapes::control);
        output.append(",\"detail\":");
        appendJsonText(output, trimText(detail, " \t\r\n"), JsonEscapes::control);
        output.append("}\n");
        std::print(stdout, "{}", output.view());
      } else {
        std::println(stderr, "telar machine: {} ({}) is not reachable: {}\n{}", profile.label(), profile.destination(), error.what(), trimText(detail, " \t\r\n"));
      }

      return 1;
    }

    const auto schema = textView(found->schema().view());
    const auto local_schema = textView(handshake::schema_id.view());

    if (json) {
      ds::String<Memory> output{memory};

      output.append("{\"label\":");
      appendJsonText(output, profile.label(), JsonEscapes::control);
      ds::formatTo(output, R"(,"reachable":true,"schema":"{}","local_schema":"{}","compatible":)", schema, local_schema);
      output.append(found->compatible() ? "true" : "false");
      for (const auto& [name, value] : ds::Array<std::pair<std::string_view, std::string_view>, 3>{{{"home", found->home()}, {"shell", found->shell()}, {"socket", found->endpoint()}}}) {
        output.append(",\"");
        output.append(name);
        output.append("\":");
        appendJsonText(output, value, JsonEscapes::control);
      }

      output.append("}\n");
      std::print(stdout, "{}", output.view());
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

  namespace {

    bool whitespace(char byte) {
      return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\v' || byte == '\f';
    }

    void noteOnce(Notes& notes, std::string_view name) {
      if (std::ranges::find(notes, name) == notes.end()) {
        notes.emplace(notes.memory(), name);
      }
    }

    enum class Kind : std::uint8_t {
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

    // The kind of a JSON value, from its encoding.
    Kind jsonKind(std::string_view encoded) noexcept {
      if (encoded.starts_with('"')) {
        return Kind::text;
      }

      return encoded.starts_with('{') || encoded.starts_with('[') ? Kind::container : Kind::scalar;
    }

    // The kind of a TOML value, from the text after its `=`.
    Kind tomlKind(std::string_view rest) noexcept {
      if (rest.empty() || rest.front() == '"' || rest.front() == '\'') {
        return Kind::text;
      }

      return rest.front() == '[' || rest.front() == '{' ? Kind::container : Kind::scalar;
    }

  }

  tbc::val_a<Text> rewriteHome(tbc::mut_a<Memory> memory, std::string_view bytes, std::string_view from, std::string_view replacement) {
    if (from.empty()) {
      throw CommandError{"HomeUnavailable"};
    }

    Text output{memory};

    for (;;) {
      const auto found = bytes.find(from);
      if (found == std::string_view::npos) {
        output.append(bytes);
        return output;
      }

      const auto after = found + from.size();
      const bool ends = after == bytes.size() || bytes[after] == '/' || bytes[after] == '"' || bytes[after] == '\'' || whitespace(bytes[after]);

      output.append(bytes.substr(0, found));
      output.append(ends ? replacement : from);
      bytes.remove_prefix(after);
    }
  }

  namespace {

    // The bytes without their `//` and `/* */` comments, strings kept whole.
    tbc::val_a<Text> stripComments(tbc::mut_a<Memory> memory, std::string_view bytes) {
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

      return result;
    }

    // The text without the commas that end an object or an array, strings kept whole.
    tbc::val_a<Text> stripTrailingCommas(tbc::mut_a<Memory> memory, std::string_view text) {
      Text plain{memory};
      bool string = false;

      for (std::size_t index = 0; index < text.size(); ++index) {
        const auto byte = text[index];

        if (string) {
          plain.push(byte);
          if (byte == '\\' && index + 1 < text.size()) {
            plain.push(text[++index]);
          } else if (byte == '"') {
            string = false;
          }
        } else if (byte == '"') {
          string = true;
          plain.push(byte);
        } else if (byte == ',') {
          auto next = index + 1;

          while (next < text.size() && whitespace(text[next])) {
            ++next;
          }

          if (next == text.size() || (text[next] != '}' && text[next] != ']')) {
            plain.push(byte);
          }
        } else {
          plain.push(byte);
        }
      }

      return plain;
    }

  }

  tbc::val_a<Text> stripJsonc(tbc::mut_a<Memory> memory, std::string_view bytes) {
    const auto uncommented = stripComments(memory, bytes);

    return stripTrailingCommas(memory, uncommented);
  }

  void json(Memory& memory, const JsonValue& value, ds::String<Memory>& output, Notes& dropped) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
    const auto source = value.encoded();
    ds::String<Memory> scratch{memory};

    if (source.starts_with('{')) {
      output.push('{');
      bool first = true;

      value.eachMember([&](JsonValue key, JsonValue child) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
        key.string(scratch);
        if (secretKey(scratch, jsonKind(child.encoded()))) {
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

      value.eachElement([&](JsonValue child) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
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

  namespace {

    std::size_t skipQuoted(std::string_view text, std::size_t start) {
      const auto quote = text[start];
      auto index = start + 1;

      while (index < text.size() && text[index] != quote) {
        index += quote == '"' && text[index] == '\\' ? 2 : 1;
      }

      return std::min(index, text.size());
    }

    // Whether a TOML value goes on past the line it starts on: a multi-line string, or an array
    // or inline table not yet closed.
    struct TomlValue {
      char delimiter = 0;
      int depth = 0;

      [[nodiscard]] bool open() const {
        return delimiter != 0 || depth > 0;
      }

      void scan(std::string_view text) {
        for (std::size_t index = 0; index < text.size();) {
          if (delimiter != 0) {
            index = insideString(text, index);
            continue;
          }

          const auto tail = text.substr(index);
          if (tail.starts_with(R"(""")") || tail.starts_with("'''")) {
            delimiter = text[index];
            index += 3;
            continue;
          }

          if (text[index] == '#') {
            return;
          }

          index = outsideString(text, index);
        }
      }

    private:
      // The index after the byte at `index` of a multi-line string, which may close it.
      std::size_t insideString(std::string_view text, std::size_t index) {
        if (delimiter == '"' && text[index] == '\\') {
          return index + 2;
        }

        const auto tail = text.substr(index);
        if ((delimiter == '"' && tail.starts_with(R"(""")")) || (delimiter == '\'' && tail.starts_with("'''"))) {
          delimiter = 0;
          return index + 3;
        }

        return index + 1;
      }

      // The index after the token at `index` outside a string, which may open or close a level.
      std::size_t outsideString(std::string_view text, std::size_t index) {
        const auto byte = text[index];

        if (byte == '"' || byte == '\'') {
          return skipQuoted(text, index) + 1;
        }

        if (byte == '[' || byte == '{') {
          ++depth;
        } else if (byte == ']' || byte == '}') {
          --depth;
        }

        return index + 1;
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

    // What the TOML filter carries from one line to the next.
    struct TomlState {
      bool skipping_table = false;
      bool dropping_value = false;
      TomlValue value;
    };

    // A `[table]` line: whether the table, and so its lines, stay.
    bool keepTable(TomlState& state, std::string_view text, Notes& dropped) {
      auto inner = text;

      while (inner.starts_with('[')) {
        inner.remove_prefix(1);
      }

      std::size_t index = 0;

      while (index < inner.size() && inner[index] != ']') {
        index = inner[index] == '"' || inner[index] == '\'' ? skipQuoted(inner, index) + 1 : index + 1;
      }

      const auto offending = tomlSecret(inner.substr(0, std::min(index, inner.size())), Kind::container);

      state.skipping_table = offending.hasValue();
      if (offending) {
        noteOnce(dropped, *offending);
      }

      return !state.skipping_table;
    }

    // A `key = value` line: whether it stays, where `keep` says whether its table does.
    bool keepAssignment(TomlState& state, std::string_view text, bool keep, Notes& dropped) {
      std::size_t equals = 0;

      while (equals < text.size() && text[equals] != '=') {
        equals = text[equals] == '"' || text[equals] == '\'' ? skipQuoted(text, equals) + 1 : equals + 1;
      }

      if (equals >= text.size()) {
        return keep;
      }

      const auto rest = trimText(text.substr(equals + 1), " \t");
      const auto offending = tomlSecret(text.substr(0, equals), tomlKind(rest));

      state.dropping_value = offending.hasValue();
      state.value.scan(rest);
      if (!offending) {
        return keep;
      }

      if (!state.skipping_table) {
        noteOnce(dropped, *offending);
      }

      return false;
    }

    // Whether `line` stays in the filtered TOML.
    bool keepLine(TomlState& state, std::string_view line, Notes& dropped) {
      const bool keep = !state.skipping_table;

      if (state.value.open()) {
        state.value.scan(line);
        return keep && !state.dropping_value;
      }

      const auto text = trimText(line, " \t\r");
      if (text.starts_with('[')) {
        return keepTable(state, text, dropped);
      }

      if (!text.empty() && !text.starts_with('#')) {
        return keepAssignment(state, text, keep, dropped);
      }

      return keep;
    }

  }

  tbc::val_a<Text> toml(tbc::mut_a<Memory> memory, std::string_view bytes, Notes& dropped) {
    TomlState state;
    bool first = true;
    Text output{memory};

    for (;;) {
      const auto newline = bytes.find('\n');
      const auto line = bytes.substr(0, newline);

      if (keepLine(state, line, dropped)) {
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

  namespace {

    constexpr std::size_t max_secret_name_bytes = 128;
    constexpr std::size_t min_bearer_token_bytes = 8;

    bool tokenByte(char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
    }

    bool placeholder(char byte) {
      return std::string_view{"$<{%[(*"}.contains(byte);
    }

    bool secretName(std::string_view name) {
      if (name.size() > max_secret_name_bytes) {
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

    bool webhookUrl(std::string_view line) {
      static constexpr auto webhooks = ds::Array<std::string_view, 11>{"hooks.slack.com/services/", "hooks.slack.com/workflows/", "hooks.slack.com/triggers/", "discord.com/api/webhooks/", "discordapp.com/api/webhooks/", ".webhook.office.com/", "outlook.office.com/webhook", "hooks.zapier.com/hooks/", "api.telegram.org/bot", "chat.googleapis.com/v1/spaces/", "ntfy.sh/"};

      return std::ranges::any_of(webhooks, [&](auto marker) {
        return asciiContainsIgnoreCase(line, marker);
      });
    }

    // Whether `prefix` starts a token of at least `minimum` more token bytes in `line`.
    bool prefixedToken(std::string_view line, std::string_view prefix, std::size_t minimum) {
      for (std::size_t start = 0;;) {
        const auto found = line.find(prefix, start);
        if (found == std::string_view::npos) {
          return false;
        }

        start = found + 1;
        if (found != 0 && tokenByte(line[found - 1])) {
          continue;
        }

        auto end = found + prefix.size();

        while (end < line.size() && tokenByte(line[end])) {
          ++end;
        }

        if (end - found - prefix.size() >= minimum) {
          return true;
        }
      }
    }

    bool wellKnownToken(std::string_view line) {
      static constexpr auto prefixes = ds::Array<std::pair<std::string_view, std::size_t>, 21>{{{"ghp_", 20}, {"gho_", 20}, {"ghu_", 20}, {"ghs_", 20}, {"ghr_", 20}, {"github_pat_", 20}, {"glpat-", 20}, {"sk-", 20}, {"xoxb-", 10}, {"xoxp-", 10}, {"xoxa-", 10}, {"xoxr-", 10}, {"xoxs-", 10}, {"AKIA", 16}, {"ASIA", 16}, {"AIza", 30}, {"npm_", 30}, {"pypi-", 30}, {"hf_", 30}, {"r8_", 30}, {"tvly-", 20}}};

      return std::ranges::any_of(prefixes, [&](const auto& entry) {
        return prefixedToken(line, entry.first, entry.second);
      });
    }

    bool bearerToken(std::string_view line) {
      constexpr std::string_view scheme = "bearer";

      for (std::size_t start = 0;;) {
        const auto found = asciiFindIgnoreCase(line, scheme, start);
        if (found == std::string_view::npos) {
          return false;
        }

        start = found + 1;
        auto index = found + scheme.size();
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

        if (index - begin >= min_bearer_token_bytes) {
          return true;
        }
      }
    }

    bool urlPassword(std::string_view line) {
      constexpr std::string_view separator = "://";

      for (std::size_t start = 0;;) {
        const auto found = line.find(separator, start);
        if (found == std::string_view::npos) {
          return false;
        }

        start = found + separator.size();
        const auto end = line.find_first_of("/?# \t\"'`<>", start);
        const auto authority = line.substr(start, end == std::string_view::npos ? line.size() - start : end - start);
        const auto sign = authority.rfind('@');
        const auto colon = authority.substr(0, sign).find(':');
        if (sign != std::string_view::npos && colon != std::string_view::npos && colon + 1 < sign && !placeholder(authority[colon + 1])) {
          return true;
        }
      }
    }

    bool userPassword(std::string_view text) {
      const auto colon = text.find(':');

      return colon != std::string_view::npos && colon + 1 < text.size() && !placeholder(text[colon + 1]);
    }

    bool commandLinePassword(std::string_view line) {
      constexpr std::string_view user_option = "--user=";
      const bool database = asciiContainsIgnoreCase(line, "mysql") || asciiContainsIgnoreCase(line, "mariadb");
      auto words = line;
      bool after_user = false;

      while (!words.empty()) {
        words = trimText(words, " \t");
        const auto end = words.find_first_of(" \t");
        const auto word = trimText(words.substr(0, end), "\"'");
        if (after_user && userPassword(word)) {
          return true;
        }

        after_user = word == "-u" || word == "--user";
        if ((word.starts_with(user_option) && userPassword(word.substr(user_option.size()))) || (database && word.starts_with("-p") && word.size() > 2 && !placeholder(word[2]))) {
          return true;
        }

        if (end == std::string_view::npos) {
          break;
        }

        words.remove_prefix(end + 1);
      }

      return false;
    }

    bool nameByte(char byte) {
      return tokenByte(byte) || byte == '.';
    }

    // Whether the name that ends before `cursor` is assigned a literal, secret-looking value there.
    bool secretValueAt(std::string_view line, std::string_view name, std::size_t cursor) {
      if (cursor < line.size() && (line[cursor] == '"' || line[cursor] == '\'')) {
        ++cursor;
      }

      while (cursor < line.size() && (line[cursor] == ' ' || line[cursor] == '\t')) {
        ++cursor;
      }

      if (cursor == line.size() || (line[cursor] != '=' && line[cursor] != ':') || line.substr(cursor).starts_with("://")) {
        return false;
      }

      ++cursor;
      if (cursor < line.size() && line[cursor] == '=') {
        return false;
      }

      return secretName(name) && literalValue(line.substr(cursor), !asciiContainsIgnoreCase(name, "token"));
    }

    bool secretAssignment(std::string_view line) {
      for (std::size_t index = 0; index < line.size();) {
        if (!nameByte(line[index])) {
          ++index;
          continue;
        }

        const auto begin = index;

        while (index < line.size() && nameByte(line[index])) {
          ++index;
        }

        if (secretValueAt(line, line.substr(begin, index - begin), index)) {
          return true;
        }
      }

      return false;
    }

    ds::Option<std::string_view> finding(std::string_view line) {
      if (line.contains("PRIVATE KEY-----")) {
        return "a private key";
      }

      if (webhookUrl(line)) {
        return "a webhook URL, whose path is its key";
      }

      if (wellKnownToken(line)) {
        return "a token of a well-known format";
      }

      if (bearerToken(line)) {
        return "a bearer token";
      }

      if (urlPassword(line)) {
        return "a password inside a URL";
      }

      if (commandLinePassword(line)) {
        return "a password on a command line";
      }

      if (secretAssignment(line)) {
        return "a value assigned to a secret-looking name";
      }

      return ds::none;
    }

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

  namespace {

    Text guiProgram(Memory& memory) {
      const auto found = ExecutablePath::sibling({"telar-gui", "../../MacOS/telar-gui"});

      return Text{memory, found ? found->view() : std::string_view{"telar-gui"}};
    }

    // Whether this session can show a window: one outside SSH on macOS, one with a Wayland display
    // elsewhere.
    bool displayAvailable() {
#ifdef __APPLE__
      return std::getenv("SSH_CONNECTION") == nullptr && std::getenv("SSH_TTY") == nullptr; // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
#else
      const auto* wayland = std::getenv("WAYLAND_DISPLAY"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
      return wayland && *wayland;
#endif
    }

    // Whether `label` names a saved machine or this machine's own label; prints why where it does not.
    bool knownMachine(Memory& memory, std::string_view label) {
      try {
        const auto profiles = machine::load(memory, machine::profilesPath(memory));
        if (!profiles.find(label) && machine::localLabel(profiles).view() != label) {
          std::println(stderr, "telar gui: no saved machine or local label has that name; see telar machine list");
          return false;
        }
      } catch (const std::exception& error) {
        std::println(stderr, "telar gui: {}", error.what());
        return false;
      }

      return true;
    }

    // Connects to the runtime at `paths`, starting it where none runs, and lets the connection go.
    void ensureRuntime(Memory& memory, const ServerOptions& server, const RuntimePaths<Memory>& paths) {
      ds::Option<RuntimeConnection> connection;
      if (connectExisting(connection, paths.socket.data()) && server.fresh) {
        std::println(stderr, "telar: a runtime is already running; stop it first (telar server stop) or drop --fresh");
        throw CommandError{"RuntimeAlreadyRunning"};
      }

      if (connection) {
        return;
      }

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

  }

  void relaunchLogin(Memory& memory, std::span<char* const> words) {
    if (std::getenv("TELAR_LOGIN_SHELL") != nullptr) { // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
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

    ::setenv("TELAR_LOGIN_SHELL", "1", 1); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe write of the environment
    launch::replace(arguments.view());
  }

  int openWindow(Memory& memory, const WindowOptions& options) {
    if (!displayAvailable()) {
      std::print(stderr, "telar: no display to open a window here (an SSH login, or Linux without WAYLAND_DISPLAY).\n"
                         "From a terminal, reach the panes and agents through the CLI:\n"
                         "  telar pane read|watch|send-keys, telar agent prompt, telar --machine LABEL COMMAND\n");
      return 1;
    }

    if (options.machine && !knownMachine(memory, *options.machine)) {
      return 1;
    }

    ServerOptions server;

    server.config = options.config.valueOr(std::string_view{});
    server.no_config = options.no_config;
    server.profile = options.profile.valueOr(std::string_view{});
    server.fresh = options.fresh;
    const RuntimePaths<Memory> paths{memory, server, process_environment};

    ensureRuntime(memory, server, paths);
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

  namespace {

    using Action = MachineOptions::Action;

    // The words after the action that it takes.
    std::size_t positionalCount(Action action) noexcept {
      if (action == Action::list || action == Action::receive_config) {
        return 0;
      }

      return action == Action::add || action == Action::rename ? 2 : 1;
    }

    // The setup steps `--skip` names, separated by commas.
    void parseSkip(MachineOptions& result, std::string_view skipped) {
      for (;;) {
        const auto end = skipped.find(',');
        const auto name = skipped.substr(0, end);
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
          return;
        }

        skipped.remove_prefix(end + 1);
      }
    }

    // An option of the setup that `machine add --setup` and `machine setup` run; false where `word`
    // is none of the action's.
    bool setupOption(tbc::mut_a<MachineOptions> result, Cursor& cursor, std::string_view word) {
      const auto action = result.action;
      const bool takes_setup = action == Action::add || action == Action::setup;

      if (word == "--setup" && action == Action::add) {
        result.setup = true;
      } else if (word == "--confirm" && action == Action::setup) {
        result.confirm = true;
      } else if (word == "--label" && action == Action::setup) {
        result.new_label = cursor.take("MissingMachineArgument");
      } else if (word == "--binary" && takes_setup) {
        result.binary = cursor.take("MissingMachineArgument");
      } else if (word == "--skip" && takes_setup) {
        parseSkip(result, cursor.take("MissingMachineArgument"));
      } else {
        return false;
      }

      return true;
    }

    // An option of the profile `machine add` saves; false where `word` is none of the action's.
    bool profileOption(tbc::mut_a<MachineOptions> result, Cursor& cursor, std::string_view word) {
      if (result.action != Action::add) {
        return false;
      }

      if (word == "--color") {
        if (result.color) {
          throw std::invalid_argument{"DuplicateColorOption"};
        }

        result.color = cursor.take("MissingMachineColor");
      } else if (word == "--disabled") {
        result.disabled = true;
      } else if (word == "--check") {
        result.check = true;
      } else {
        return false;
      }

      return true;
    }

  }

  MachineOptions MachineOptions::parse(std::span<char* const> args) {
    if (args.empty()) {
      throw std::invalid_argument{"MissingMachineAction"};
    }

    static constexpr ds::Array<std::string_view, 9> names{"add", "remove", "rename", "enable", "disable", "list", "check", "setup", "receive-config"};
    const auto* const found = std::ranges::find(names, std::string_view{args.front()});
    if (found == names.end()) {
      throw std::invalid_argument{"UnknownMachineAction"};
    }

    MachineOptions result{.action = static_cast<Action>(found - names.begin())};
    const auto action = result.action;
    const std::size_t positional = positionalCount(action);

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

      if (word == "--json" && (action == Action::list || action == Action::check || action == Action::add || action == Action::setup)) {
        result.json = true;
      } else if (!setupOption(result, cursor, word) && !profileOption(result, cursor, word)) {
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
    const auto* const found = std::ranges::find_if(names, [&](auto candidate) {
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

  namespace {

    constexpr std::size_t maximum_arguments = 64;

    // The options take each flag once, and the command at most maximum_arguments words.
    using WindowWords = ds::Array<std::string_view, 2 * maximum_arguments>;

    // An option that takes a value, and the errors of one given without it or twice.
    struct ValueFlag {
      std::string_view flag;
      const char* missing;
      const char* duplicate;
    };

    constexpr ds::Array<ValueFlag, 5> value_flags{
        ValueFlag{.flag = "--config", .missing = "MissingConfigPath", .duplicate = "DuplicateConfigOption"},
        ValueFlag{.flag = "--profile", .missing = "MissingProfileName", .duplicate = "DuplicateProfileOption"},
        ValueFlag{.flag = "--theme", .missing = "MissingThemeName", .duplicate = "DuplicateThemeOption"},
        ValueFlag{.flag = "--remote", .missing = "MissingRemoteDestination", .duplicate = "DuplicateRemoteOption"},
        ValueFlag{.flag = "--machine", .missing = "MissingMachineLabel", .duplicate = "DuplicateMachineOption"},
    };

    // The words of the command line but `--login-shell`, which `gui` takes apart; their count.
    std::size_t collectWords(tbc::val_a<std::span<char* const>> input, bool gui, tbc::mut_a<WindowWords> words, WindowOptions& result) {
      if (gui && input.size() > maximum_arguments) {
        throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
      }

      std::size_t count = 0;

      for (const std::string_view word : input) {
        if (gui && word == "--login-shell") {
          result.login_shell = true;
        } else if (count == words.size()) {
          throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
        } else {
          words.atMut(count++) = word;
        }
      }

      return count;
    }

    // `--fresh` or `--no-config`, each once; false where `word` is neither.
    bool switchOption(WindowOptions& result, std::string_view word) {
      if (word == "--fresh") {
        if (result.fresh) {
          throw std::invalid_argument{"DuplicateFreshOption"};
        }

        result.fresh = true;
        return true;
      }

      if (word == "--no-config") {
        if (result.no_config || result.config) {
          throw std::invalid_argument{"DuplicateConfigOption"};
        }

        result.no_config = true;
        return true;
      }

      return false;
    }

    // The field of the options that `value_flags[index]` sets.
    ds::Option<std::string_view>& flagValue(WindowOptions& result, std::size_t index) {
      switch (index) {
      case 0:
        return result.config;
      case 1:
        return result.profile;
      case 2:
        return result.theme;
      case 3:
        return result.remote;
      default:
        return result.machine;
      }
    }

    void requireFirst(WindowOptions& result, std::size_t index) {
      const auto& option = value_flags[index];
      if (flagValue(result, index) || (option.flag == "--config" && result.no_config)) {
        throw std::invalid_argument{option.duplicate};
      }
    }

    void requireCompatible(const WindowOptions& result) {
      if (result.no_config && result.profile) {
        throw std::invalid_argument{"ProfileWithoutConfig"};
      }

      if (result.fresh && result.remote) {
        throw std::invalid_argument{"FreshWithRemote"};
      }

      if (result.machine && result.remote) {
        throw std::invalid_argument{"MachineWithRemote"};
      }
    }

  }

  WindowOptions WindowOptions::parse(std::span<char* const> input, bool gui) {
    WindowOptions result;
    WindowWords args;
    const auto count = collectWords(input, gui, args, result);
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

      if (switchOption(result, word)) {
        continue;
      }

      const auto equals = word.find('=');
      const auto flag = word.substr(0, equals);
      const auto* const option = std::ranges::find(value_flags, flag, &ValueFlag::flag);
      if (option == value_flags.end()) {
        break;
      }

      const auto flag_index = static_cast<std::size_t>(option - value_flags.begin());

      requireFirst(result, flag_index);
      std::string_view text;

      if (equals != std::string_view::npos) {
        text = word.substr(equals + 1);
        if (text.empty() && flag != "--theme") {
          throw std::invalid_argument{option->missing};
        }
      } else {
        if (++index == words.size()) {
          throw std::invalid_argument{option->missing};
        }

        text = words[index];
      }

      flagValue(result, flag_index) = flag == "--theme" ? canonicalTheme(text) : text;
    }

    if (words.size() - index > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    for (; index < words.size(); ++index) {
      result.command_words.atMut(result.command_count++) = words[index];
    }

    requireCompatible(result);
    return result;
  }

}

namespace telar::runtime::cli::machine {

  void Random::fill(std::span<std::uint8_t> bytes) {
    randomBytes(bytes.data(), bytes.size());
  }

}
