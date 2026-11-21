module telar.cli.commands.worktree;

import telar.cli.session.control_session;
import telar.platform.sha256;
import telar.sys.posix;
import telar.tbc;
import telar.cli.console.output;
import telar.base.text.utf8;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.content;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.ds;
import telar.base.memory.containers;
import telar.base.text;
import telar.base.text.json;

namespace telar::runtime::cli::repository {

  namespace {

    struct Catalog {
      ds::Vec<std::pair<std::uint64_t, Text>, Memory> workspaces;
      ds::Vec<Text, Memory> worktrees;
    };

    template <Allocator Memory>
    tbc::val_a<Catalog> catalog(tbc::mut_a<Memory> memory, const char* socket) {
      constexpr unsigned reply_timeout_seconds = 30;
      constexpr std::size_t request_bytes = 32;
      RuntimeConnection connection{socket};

      connection.receiveTimeout(reply_timeout_seconds);
      ds::Array<Byte, request_bytes> outgoing{};

      connection.send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false}, outgoing.viewMut());
      ds::Vec<Byte, Memory> incoming{memory};

      incoming.resize(max_payload_size, Byte{});
      ds::Vec<Byte, Memory> decoded{memory};

      decoded.resize(max_payload_size, Byte{});

      for (;;) {
        const auto frame = connection.receive(incoming.viewMut());
        if (static_cast<ServerTag>(frame.front()) != ServerTag::workspace_list) {
          continue;
        }

        DecodeStorage storage{decoded.viewMut()};
        const auto list = Codec::decode<WorkspaceList>(frame, storage);
        Catalog result{.workspaces = ds::Vec<std::pair<std::uint64_t, Text>, Memory>{memory}, .worktrees = ds::Vec<Text, Memory>{memory}};

        for (const auto& entry : list.entries) {
          result.workspaces.push({entry.workspace, Text{memory, entry.path}});
        }

        for (const auto& entry : list.worktrees) {
          result.worktrees.emplace(memory, entry.path);
        }

        return result;
      }
    }

    // The workspaces the runtime's history recorded, which outlive the workspaces themselves: the
    // runtime owns the history, so it is asked rather than its database read.
    tbc::val_a<ds::Vec<Text, Memory>> recordedWorkspaces(tbc::mut_a<Memory> memory, const char* socket) {
      constexpr unsigned reply_timeout_seconds = 30;
      ControlSession session{memory, socket};
      ds::Vec<Text, Memory> paths{memory};

      session.receiveTimeout(reply_timeout_seconds);
      try {
        const auto recorded = session.template exchange<HistoryWorkspaces>(QueryHistoryWorkspaces{});
        if (recorded.truncated) {
          reportCommandLimit({.name = "repository.max_recorded_paths", .noun = "recorded paths", .value = HistoryWorkspaces::maximum_paths, .requested = HistoryWorkspaces::maximum_paths + 1});
          throw std::runtime_error{"RepositoryDiscoveryLimit"};
        }

        for (const auto path : recorded.paths) {
          paths.emplace(memory, path);
        }
      } catch (const ControlFailure&) {
        throw std::runtime_error{"RepositoryHistoryUnavailable"};
      }

      return paths;
    }

    tbc::val_a<Text> managedPath(tbc::mut_a<Memory> memory, std::string_view identity) {
      const ProcessEnvironment environment;
      // A later lookup may overwrite the storage an earlier one returned.
      const Text home{memory, environment.lookup("HOME")};
      if (home.empty()) {
        throw std::runtime_error{"HomeDirectoryUnavailable"};
      }

      const auto configured = environment.lookup("XDG_DATA_HOME");
      auto result = configured.empty() ? ds::format(memory, "{}/.local/share", home) : Text{memory, configured};
      if (!result.view().starts_with('/')) {
        throw std::runtime_error{"InvalidDataDirectory"};
      }

      Sha256 hash;

      hash.update(identity);
      const auto digest = hash.finish();

      ds::formatTo(result, "/telar/repositories/{}", lowerHex(digest.view()));
      return result;
    }

    template <Allocator Memory>
    tbc::val_a<Text> mainRoot(tbc::mut_a<Memory> memory, std::string_view path) {
      Git git{memory, path};
      const auto common = git.read({"rev-parse", "--path-format=absolute", "--git-common-dir"});
      auto trimmed = common.view();

      while (trimmed.ends_with('/')) {
        trimmed.remove_suffix(1);
      }

      constexpr std::string_view suffix = "/.git";
      if (!trimmed.ends_with(suffix)) {
        throw std::runtime_error{"NotARepository"};
      }

      trimmed.remove_suffix(suffix.size());
      if (trimmed.empty() || !trimmed.starts_with('/')) {
        throw std::runtime_error{"NotARepository"};
      }

      return Text{memory, trimmed};
    }

    // A checkout to try, and the origin identity it must have.
    struct Candidate {
      std::string_view path;
      std::string_view identity;
    };

    template <Allocator Memory>
    tbc::val_a<ds::Option<Text>> matching(tbc::mut_a<Memory> memory, Candidate candidate) {
      const auto path = candidate.path;
      const auto identity = candidate.identity;

      if (path.contains('\0') || path.size() >= PATH_MAX) {
        return ds::none;
      }

      Text root{memory};

      try {
        root = mainRoot(memory, path);
      } catch (const std::exception&) {
        return ds::none;
      }

      auto directory = file_transfer::openDirectory(root);

      try {
        Git git{memory, root};
        if (normalize(memory, git.read({"config", "--get", "remote.origin.url"})) != identity) {
          return ds::none;
        }
      } catch (const std::exception&) {
        return ds::none;
      }

      return std::move(root);
    }

    // Repository discovery: the main checkout whose origin is
    // `identity` among the runtime's workspaces and worktrees, the workspaces
    // history recorded and the managed clone. It starts the runtime if needed.
    template <Allocator Memory>
    tbc::val_a<ds::Option<Text>> find(tbc::mut_a<Memory> memory, std::string_view identity, ds::Option<std::string_view> selected, ds::Option<std::string_view> socket = ds::none) {
      const ProcessEnvironment environment;
      ServerOptions server;

      if (socket) {
        server.socket = *socket;
      }

      const RuntimePaths<Memory> paths{memory, server, environment};

      ensureRuntime(memory, paths);
      const auto available = catalog(memory, paths.socket.data());

      if (selected) {
        Text path{memory, *selected};

        if (const auto id = maybeUnsigned(*selected)) {
          const auto found = std::ranges::find(available.workspaces, *id, &std::pair<std::uint64_t, Text>::first);
          if (found == available.workspaces.end()) {
            throw std::runtime_error{"WorkspaceNotFound"};
          }

          path = found->second.clone();
        }

        auto result = matching(memory, Candidate{.path = path, .identity = identity});
        if (!result) {
          throw std::runtime_error{"RepositoryNotInWorkspace"};
        }

        return result;
      }

      // Keeps the one main checkout with `identity` among the paths it is shown.
      class Consider final {
      public:
        // What it finds lives in `memory`; it only reads `identity`.
        Consider(tbc::mut_a<Memory> memory, tbc::val_b<std::string_view> identity)
            : memory_(memory),
              identity_(identity) {}

        void operator()(std::string_view path) {
          auto candidate = matching(memory_, Candidate{.path = path, .identity = identity_});
          if (!candidate) {
            return;
          }

          if (result_ && *result_ != *candidate) {
            throw std::runtime_error{"AmbiguousRepository"};
          }

          result_ = std::move(candidate);
        }

        [[nodiscard]] const ds::Option<Text>& result() const noexcept {
          return result_;
        }

      private:
        tbc::val_a<ds::Option<Text>> result_;
        tbc::mut_a<Memory> memory_;
        tbc::val_b<std::string_view> identity_;
      };

      Consider consider{memory, identity};

      for (const auto& [id, path] : available.workspaces) {
        consider(path);
      }

      for (const auto& path : available.worktrees) {
        consider(path);
      }

      for (const auto& path : recordedWorkspaces(memory, paths.socket.data())) {
        consider(path.view());
      }

      consider(managedPath(memory, identity));
      if (!consider.result()) {
        return ds::none;
      }

      return Text{memory, consider.result()->view()};
    }

    class StagingDirectory {
    public:
      explicit StagingDirectory(Text path)
          : path_(std::move(path)) {}

      ~StagingDirectory() {
        try {
          std::error_code ignored;

          std::filesystem::remove_all(path_.view(), ignored);
        } catch (...) { // NOLINT(bugprone-empty-catch): removal is best effort, and a destructor cannot fail
        }
      }

      StagingDirectory(const StagingDirectory&) = delete;
      StagingDirectory& operator=(const StagingDirectory&) = delete;
      StagingDirectory(StagingDirectory&&) = delete;
      StagingDirectory& operator=(StagingDirectory&&) = delete;

    private:
      Text path_;
    };

    bool validCommit(std::string_view commit) {
      constexpr std::size_t sha1_chars = 40;
      constexpr std::size_t sha256_chars = 64;

      return (commit.size() == sha1_chars || commit.size() == sha256_chars) && std::ranges::all_of(commit, [](unsigned char byte) {
        return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
      });
    }

    FileDescriptor lockRepository(Memory& memory, int parent, std::string_view name) {
      const auto lock_name = ds::format(memory, "{}.lock", name);
      auto file = openLockFile(parent, lock_name.data());
      struct stat state{};
      constexpr unsigned group_and_other_permissions = 0077U;
      if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::getuid() || state.st_nlink != 1 || (static_cast<unsigned>(state.st_mode) & group_and_other_permissions) != 0) {
        throw std::runtime_error{"UnsafeRepositoryLock"};
      }

      while (::flock(file.get(), LOCK_EX) != 0) {
        if (sys::lastError() != EINTR) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }
      }

      return file;
    }

    template <Allocator Memory>
    void clearPriorStage(Memory& memory, const Text& stage, std::string_view identity) {
      struct stat state{};
      if (::lstat(stage.data(), &state) != 0) {
        if (sys::lastError() == ENOENT) {
          return;
        }

        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      if (!S_ISDIR(state.st_mode)) {
        throw std::runtime_error{"UnownedRepositoryStage"};
      }

      constexpr std::size_t max_owner_bytes = 2048;
      auto directory = file_transfer::openDirectory(stage);
      ds::Vec<unsigned char, Memory> marker{memory};
      if (!readPrivateFile(directory.get(), "owner", marker, max_owner_bytes) || textBytes(marker.view()) != identity) {
        throw std::runtime_error{"UnownedRepositoryStage"};
      }

      std::filesystem::remove_all(stage.view());
    }

    void receiveBundle(const FileDescriptor& bundle, std::uint64_t expected) {
      const auto descriptor = bundle.get();
      ds::Array<Byte, file_transfer::copy_buffer_bytes> bytes; // NOLINT(cppcoreguidelines-pro-type-member-init): read() fills what is then written, so clearing the 64 KiB copy buffer is waste
      std::uint64_t total = 0;

      for (;;) {
        const auto count = ::read(STDIN_FILENO, bytes.dataMut(), bytes.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count < 0) {
          throw std::runtime_error{sys::errorName(sys::lastError())};
        }

        if (count == 0) {
          break;
        }

        total += static_cast<std::uint64_t>(count);
        if (total > expected) {
          throw std::runtime_error{"RepositoryTransferLength"};
        }

        writeBytes(descriptor, std::span{bytes}.first(static_cast<std::size_t>(count)));
      }

      if (total != expected) {
        throw std::runtime_error{"RepositoryTransferInterrupted"};
      }
    }

  }

  // The modes of what a transfer stages, private to the user.
  constexpr mode_t private_directory_mode = 0700;
  constexpr mode_t private_file_mode = 0600;

  template <Allocator Memory>
  tbc::val_a<PreparedRepository> receive(tbc::mut_a<Memory> memory, const RepositoryOptions& options) {
    if (normalize(memory, options.transport) != options.identity || !validCommit(options.commit) || !options.ref.starts_with("refs/telar/transfer/") || options.bytes == 0 || options.bytes > max_bundle_bytes) {
      throw std::runtime_error{"InvalidRepositoryTransfer"};
    }

    const auto managed = managedPath(memory, options.identity);
    const auto slash = managed.view().rfind('/');
    const auto base = managed.view().substr(slash + 1);
    auto parent = file_transfer::openDirectory(managed.view().substr(0, slash), true);
    auto lock = lockRepository(memory, parent.get(), base);
    const auto existing = find(memory, options.identity, options.workspace);
    const auto stage = ds::format(memory, "{}.stage", managed);

    clearPriorStage(memory, stage, options.identity);
    const auto stage_name = ds::format(memory, "{}.stage", base);
    if (::mkdirat(parent.get(), stage_name.data(), private_directory_mode) != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    StagingDirectory cleanup{stage.clone()};
    auto directory = file_transfer::openDirectory(stage);
    FileDescriptor owner{::openat(directory.get(), "owner", combineFlags(O_CREAT, O_EXCL, O_WRONLY, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!owner) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    writeText(options.identity, owner.get());
    FileDescriptor bundle{::openat(directory.get(), "history.bundle", combineFlags(O_CREAT, O_EXCL, O_WRONLY, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!bundle) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    receiveBundle(bundle, options.bytes);
    const auto bundle_path = ds::format(memory, "{}/history.bundle", stage);
    const auto staged_repository = ds::format(memory, "{}/repository", stage);
    const std::string_view root = existing ? existing->view() : staged_repository.view();

    if (!existing && ::mkdirat(directory.get(), "repository", private_directory_mode) != 0) {
      throw std::runtime_error{sys::errorName(sys::lastError())};
    }

    Git git{memory, root};

    if (!existing) {
      git.read({"init", "--template="});
    }

    git.read({"bundle", "verify", bundle_path});
    git.read({"-c", "protocol.file.allow=always", "fetch", "--no-tags", "--", bundle_path, options.ref});
    if (git.read({"rev-parse", "--verify", "FETCH_HEAD^{commit}"}) != options.commit) {
      throw std::runtime_error{"RepositoryCommitMismatch"};
    }

    ready(git, options.commit);
    if (!existing) {
      git.read({"config", "remote.origin.url", options.transport});
      git.read({"checkout", "--detach", options.commit});
      const auto relative = ds::format(memory, "{}/repository", stage_name);
      const Text published{memory, base};

      try {
        file_transfer::publish(parent.get(), relative.data(), published.data());
      } catch (const std::runtime_error& error) {
        throw std::runtime_error{std::string_view{error.what()} == "PathAlreadyExists" ? "RepositoryDestinationOccupied" : "RepositoryPublicationFailed"};
      }
    }

    return {.path = Text{memory, existing ? existing->view() : managed.view()}, .commit = Text{memory, options.commit}, .repository = Text{memory, options.identity}, .reused = existing.hasValue()};
  }

  constexpr std::size_t max_transfer_tips = 256;

  template <Allocator Memory>
  tbc::val_a<Text> tips(tbc::mut_a<Memory> memory, const RepositoryOptions& options) {
    Text listing{memory};
    const auto found = find(memory, options.identity, options.workspace);
    if (!found) {
      return listing;
    }

    Git git{memory, *found};

    try {
      ds::formatTo(listing, "{}\n", git.read({"rev-parse", "--verify", "--quiet", "HEAD"}));
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a clone without a HEAD lists only its refs
    }

    const auto refs = git.read({"for-each-ref", "--sort=-committerdate", ds::format(memory, "--count={}", max_transfer_tips), "--format=%(objectname)"});
    if (!refs.empty()) {
      ds::formatTo(listing, "{}\n", refs);
    }

    return listing;
  }

  namespace {

    void appendHashes(ds::Vec<Text, Memory>& hashes, std::string_view listing) {
      for (const auto line : std::views::split(listing, '\n')) {
        const std::string_view hash{line.begin(), line.end()};
        if (hashes.size() < max_transfer_tips && validCommit(hash)) {
          hashes.emplace(hashes.memory(), hash);
        }
      }
    }

    // The commit a transfer bundles, and the tips the other machine's clone listed.
    struct Negotiation {
      std::string_view commit;
      std::string_view listing;
    };

    // Whether the tips already reach the commit, which leaves nothing to bundle.
    bool tipsReach(tbc::mut_a<Memory> memory, Git& git, std::string_view commit, std::span<const Text> tips) {
      const ds::Array<std::string_view, 5> query{"rev-list", "--count", "--ignore-missing", commit, "--not"};
      ds::Vec<std::string_view, Memory> count{memory};

      count.extend(query.view());
      for (const auto& tip : tips) {
        count.push(tip.view());
      }

      return git.read(count.view()) == "0";
    }

    // What the bundle leaves out: the machine's tips, which its clone holds with
    // all their history. When they already reach `commit`, its parents instead,
    // since Git refuses an empty bundle. Only hashes pass, never an option.
    tbc::val_a<ds::Vec<Text, Memory>> exclusions(tbc::mut_a<Memory> memory, Git& git, Negotiation negotiation) {
      ds::Vec<Text, Memory> excluded{memory};

      appendHashes(excluded, negotiation.listing);
      if (!excluded.empty() && tipsReach(memory, git, negotiation.commit, excluded.view())) {
        excluded.clear();
        appendHashes(excluded, git.read({"rev-parse", ds::format(memory, "{}^@", negotiation.commit)}));
      }

      return excluded;
    }

    // What the receiving telar must report of the repository it prepared.
    struct ExpectedRepository {
      std::string_view commit;
      std::string_view identity;
    };

    template <Allocator Memory>
    tbc::val_a<PreparedRepository> parsePrepared(tbc::mut_a<Memory> memory, std::string_view output, ExpectedRepository expected) {
      const auto commit = expected.commit;
      const auto identity = expected.identity;
      const auto result = JsonNode<Memory>::parse(memory, output);
      const auto* path = result.find("path");
      const auto* received_commit = result.find("commit");
      const auto* repository = result.find("repository");
      const auto* ready = result.find("repository_ready");
      const auto* reused = result.find("reused");
      if (path == nullptr || path->kind() != JsonKind::string || !path->text().starts_with('/') || path->text().contains('\0') || received_commit == nullptr || received_commit->text() != commit || repository == nullptr || repository->text() != identity || ready == nullptr || ready->text() != "true" || reused == nullptr || (reused->text() != "true" && reused->text() != "false")) {
        throw std::runtime_error{"InvalidPreparationResult"};
      }

      return {.path = Text{memory, path->text()}, .commit = Text{memory, commit}, .repository = Text{memory, identity}, .reused = reused->text() == "true"};
    }

    // Reports what stays behind: the files the commit does not hold.
    void reportUncommitted(Git& git) {
      const auto status = git.read({"status", "--porcelain"});
      if (!status.empty()) {
        const auto dirty = static_cast<std::size_t>(std::ranges::count(status.view(), '\n')) + 1;

        writeFormatted(STDERR_FILENO, "telar repository: {} uncommitted files stay on this machine\n", dirty);
      }
    }

    // A directory of this process's own under TMPDIR.
    tbc::val_a<Text> makeTemporary(tbc::mut_a<Memory> memory) {
      const ProcessEnvironment environment;
      const auto base = environment.lookup("TMPDIR");
      auto temporary = ds::format(memory, "{}/telar-transfer-{:016x}{:016x}", base.empty() ? "/tmp" : base, randomIdentity(), randomIdentity());
      if (::mkdir(temporary.data(), private_directory_mode) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      return temporary;
    }

    // The bundle file in the temporary directory. TMPDIR may sit behind a symlink (macOS's /var);
    // only the directory just created, private to this process, must not be one.
    FileDescriptor createBundle(const Text& temporary) {
      FileDescriptor directory{::open(temporary.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!directory) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      FileDescriptor bundle{::openat(directory.get(), "history.bundle", combineFlags(O_CREAT, O_EXCL, O_RDWR, O_CLOEXEC), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
      if (!bundle) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      return bundle;
    }

  }

  tbc::val_a<PreparedRepository> prepare(tbc::mut_a<Memory> memory, const RepositoryOptions& options, std::string_view remote_program, RepositoryCapture& capture) {
    const auto cwd = sessions::realDirectory(memory, ".");
    const auto root = mainRoot(memory, cwd);
    Git git{memory, root};
    Text commit{memory};

    try {
      commit = git.read({"rev-parse", "--verify", "--quiet", "--end-of-options", ds::format(memory, "{}^{{commit}}", options.from)});
    } catch (const std::exception&) {
      throw std::runtime_error{"UnknownRevision"};
    }

    ready(git, commit);
    const auto origin = git.read({"config", "--get", "remote.origin.url"});
    const auto identity = normalize(memory, origin);
    const auto transport = sanitized(memory, origin);

    reportUncommitted(git);
    // Through `exec` like `receive`, so discovery there sees what it will see.
    const ds::Array<std::string_view, 8> tips_words{"exec", "--no-stdin", "--", remote_program, "repository", "tips", "--identity", identity};
    ds::Vec<std::string_view, Memory> query{memory};

    query.extend(tips_words.view());
    if (options.workspace) {
      query.push("--workspace");
      query.push(*options.workspace);
    }

    // Without an answer the whole history travels, as to a new clone.
    Text listing{memory};

    try {
      listing = capture(query.view(), -1);
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): without an answer the whole history travels, as to a new clone
    }

    const auto excluded = exclusions(memory, git, {.commit = commit, .listing = listing});
    const auto temporary = makeTemporary(memory);
    const StagingDirectory cleanup{temporary.clone()};
    auto bundle = createBundle(temporary);

    const auto ref = ds::format(memory, "refs/telar/transfer/{}", temporary.view().substr(temporary.view().rfind('/') + 1));

    git.read({"update-ref", ref, commit, ""});
    const auto delete_ref = [&] {
      try {
        git.read({"update-ref", "-d", ref, commit});
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): deleting the transfer ref is best effort; one left behind names a commit the clone holds
      }
    };

    try {
      ds::Vec<std::string_view, Memory> revisions{memory};

      revisions.push(ref.view());
      if (!excluded.empty()) {
        revisions.push("--ignore-missing");
        revisions.push("--not");
        for (const auto& hash : excluded) {
          revisions.push(hash.view());
        }
      }

      git.bundle(revisions.view(), bundle.get());
      struct stat inode{};
      if (::fstat(bundle.get(), &inode) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      if (::lseek(bundle.get(), 0, SEEK_SET) != 0) {
        throw std::runtime_error{sys::errorName(sys::lastError())};
      }

      const auto size = ds::format(memory, "{}", inode.st_size);
      ds::Vec<std::string_view, Memory> words{memory};

      const ds::Array<std::string_view, 15> receive_words{"exec", "--", remote_program, "repository", "receive", "--identity", identity, "--transport", transport, "--commit", commit, "--ref", ref, "--bytes", size};

      words.extend(receive_words.view());
      if (options.workspace) {
        words.push("--workspace");
        words.push(*options.workspace);
      }

      const auto output = capture(words.view(), bundle.get());
      auto result = parsePrepared(memory, output, {.commit = commit, .identity = identity});

      delete_ref();
      return result;
    } catch (...) {
      delete_ref();
      throw;
    }
  }

  namespace {

    // Runs the words on the machine `profile` names, over its SSH connection.
    template <Allocator Memory>
    class ProfileCapture final : public RepositoryCapture {
    public:
      ProfileCapture(Memory& memory, const machines::MachineProfile& profile)
          : memory_(memory),
            profile_(profile) {}

      Text operator()(std::span<const std::string_view> words, int input) override {
        return machine::capture(memory_, profile_, words, "RepositoryTransferFailed", input);
      }

    private:
      Memory& memory_;
      const machines::MachineProfile& profile_;
    };

  }

  tbc::val_a<PreparedRepository> prepare(tbc::mut_a<Memory> memory, const RepositoryOptions& options, const machines::MachineProfile& profile) {
    ProfileCapture<Memory> capture{memory, profile};

    return prepare(memory, options, profile.program().valueOr("telar"), capture);
  }

  int run(Memory& memory, const RepositoryOptions& options) {
    try {
      if (options.action == RepositoryOptions::Action::receive) {
        receive(memory, options).print(true);
      } else if (options.action == RepositoryOptions::Action::tips) {
        writeText(tips(memory, options));
      } else {
        const auto profile = machine::resolve(memory, *options.machine);
        if (!profile) {
          throw std::runtime_error{"PreparationNeedsAnotherMachine"};
        }

        prepare(memory, options, *profile).print();
      }

      return 0;
    } catch (const std::exception& error) {
      writeFormatted(STDERR_FILENO, "telar repository: {}\n", std::string_view{error.what()});
      return 1;
    }
  }

}

namespace telar::runtime::cli::sessions {

  namespace {

    constexpr unsigned char delete_character = 0x7f;

    enum class GitDirection : std::uint8_t {
      push,
      fetch,
    };

    // Descriptions of the errors only dispatch raises.
    std::string_view describeDispatchError(std::string_view name) {
      static constexpr ds::Array<std::pair<std::string_view, std::string_view>, 12> descriptions{
          {
              {"UnknownMachine", "no saved machine or local label has that name; see `telar machine list`"},
              {"FetchNeedsAnotherMachine", "fetch brings a branch from another machine; this label names this one"},
              {"NoOriginRemote", "the repository has no `origin` remote to find its clone by on the other machine"},
              {"UnsupportedOrigin", "the `origin` remote is a local path, which names no clone on another machine"},
              {"UnexpectedResolveOutput", "the machine answered `worktree resolve` with something else; is its telar up to date?"},
              {"MachineCommandFailed", "the command failed on the machine"},
              {"UnknownRevision", "that revision names no commit here"},
              {"GitPushFailed", "git push to the machine failed; a branch with other history there is never overwritten"},
              {"GitFetchFailed", "git fetch from the machine failed"},
              {"UnquotableSshOption", "telar's runtime directory has a quote in its path, which git cannot be given safely"},
              {"NotARepository", "not inside a git repository"},
          },
      };

      const auto* const found = std::ranges::find(descriptions, name, &std::pair<std::string_view, std::string_view>::first);

      return found == descriptions.end() ? name : found->second;
    }

    // One push or fetch: the clone on the other machine, what moves and which way.
    struct GitTransfer {
      std::string_view clone;
      std::string_view refspec;
      GitDirection direction;
    };

    // What a dispatch reads and builds lives in `memory`, region `a`; it reads the options and the
    // machine's profile it is given, region `b`.
    class WorktreeDispatch {
    public:
      WorktreeDispatch(tbc::mut_a<Memory> memory, tbc::ref_b<WorktreeOptions> options, tbc::ref_b<machines::MachineProfile> profile)
          : memory_(memory),
            options_(options),
            profile_(profile),
            git_(memory),
            root_(git_.root(realDirectory(memory, "."))) {}

      int create() {
        const auto branch = *options_.branch;
        const bool continued = git_.succeeds({"git", "-C", root_, "rev-parse", "--verify", "--quiet", ds::format(memory_, "refs/heads/{}", branch)});
        const auto source = continued ? branch : options_.from.valueOr("HEAD");
        const auto commit = commitOf(source);
        const RepositoryOptions prepare_options{
            .action = RepositoryOptions::Action::prepare,
            .from = commit,
            .workspace = options_.workspace,
        };

        const auto clone = repository::prepare(memory_, prepare_options, profile_).path;

        transfer({.clone = clone, .refspec = ds::format(memory_, "{}:refs/heads/{}", commit, branch), .direction = GitDirection::push});
        const auto profiles = machine::load(memory_, machine::profilesPath(memory_));
        const auto local_label = machine::localLabel(profiles);
        const auto local = local_label.view().substr(0, machines::MachineLimits::label_bytes);
        const auto coordinator = options_.coordinator ? options_.coordinator : sourceCoordinator();
        const auto coordinator_text = coordinator ? ds::Option{formatCoordinator(*coordinator)} : ds::none;
        ds::Vec<std::string_view, Memory> words{memory_};

        const ds::Array<std::string_view, 7> create_words{"worktree", "create", branch, "--workspace", clone, "--dispatched-from", local};

        words.extend(create_words.view());
        const auto optional = [&](std::string_view flag, ds::Option<std::string_view> value) {
          if (value) {
            words.push(flag);
            words.push(*value);
          }
        };

        optional("--title", options_.title);
        optional("--label", options_.label);
        optional("--coordinator", coordinator_text ? ds::Option{coordinator_text->view()} : ds::none);
        if (!continued) {
          words.push("--from");
          words.push(commit.view());
        }

        if (options_.setup) {
          words.push("--setup");
        }

        if (options_.json) {
          words.push("--json");
        }

        if (!options_.command.empty()) {
          words.push("--");
          for (const std::string_view word : options_.command) {
            words.push(word);
          }
        }

        return machine::forward(memory_, profile_, std::span<const std::string_view>{words.view()});
      }

      int fetch() {
        const auto branch = *options_.branch;
        const auto label = *options_.machine;
        const auto clone = findClone();
        const auto ref = ds::format(memory_, "refs/remotes/{}/{}", label, branch);

        transfer({.clone = clone, .refspec = ds::format(memory_, "+refs/heads/{}:{}", branch, ref), .direction = GitDirection::fetch});
        const auto commit = commitOf(ref);
        Output output{memory_};

        if (options_.json) {
          output.text("{\"machine\":").json(label).text(",\"branch\":").json(branch).text(",\"ref\":").json(ref).text(",\"commit\":").json(commit).text("}\n");
        } else {
          output.text(ds::format(memory_, "fetched {} from {} into {} at {}\n", branch, label, ref, commit));
        }

        output.flush();
        return 0;
      }

    private:
      tbc::val_a<Text> commitOf(std::string_view revision) {
        try {
          return git_.line({"git", "-C", root_, "rev-parse", "--verify", "--quiet", "--end-of-options", ds::format(memory_, "{}^{{commit}}", revision)});
        } catch (const std::exception&) {
          throw Failure{"UnknownRevision"};
        }
      }

      tbc::val_a<Text> originIdentity() {
        Text url{memory_};

        try {
          url = git_.line({"git", "-C", root_, "config", "--get", "remote.origin.url"});
        } catch (const std::exception&) {
          throw Failure{"NoOriginRemote"};
        }

        return repository::normalize(memory_, url);
      }

      // Asks the other machine which of its workspaces holds this repository.
      tbc::val_a<Text> findClone() {
        const auto identity = originIdentity();
        const ds::Array<std::string_view, 5> words{"worktree", "resolve", "--repository", identity, "--json"};
        const auto output = machine::capture(memory_, profile_, std::span<const std::string_view>{words.view()}, "MachineCommandFailed");

        try {
          const auto resolved = JsonNode<Memory>::parse(memory_, output);
          const auto* path = resolved.find("path");
          if (path != nullptr && path->kind() == JsonKind::string && path->text().starts_with('/')) {
            return Text{memory_, path->text()};
          }
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): an answer that does not parse is the unexpected output reported below
        }

        throw Failure{"UnexpectedResolveOutput"};
      }

      // One push or fetch against the other machine's clone, through the gateway
      // the dispatch uses. A push never forces.
      void transfer(const GitTransfer& request) {
        const auto clone = request.clone;
        const auto refspec = request.refspec;

        // Git speaks to the clone through the gateway program, which names the machine itself:
        // the URL's host is a placeholder Git only passes along.
        const auto url = ds::format(memory_, "ssh://telar{}", clone);
        const auto command = machine::gitGatewayCommand(memory_, profile_.destination());
        const ds::Array<std::pair<std::string_view, std::string_view>, 3> environment{{{"GIT_SSH_COMMAND", command}, {"GIT_SSH_VARIANT", "simple"}, {"GIT_TERMINAL_PROMPT", "0"}}};

        if (request.direction == GitDirection::push) {
          const ds::Array<std::string_view, 8> argv{"git", "-C", root_, "push", "--quiet", "--", url, refspec};

          git_.run(argv, "GitPushFailed", true, false, environment);
        } else {
          const ds::Array<std::string_view, 9> argv{"git", "-C", root_, "fetch", "--quiet", "--no-tags", "--", url, refspec};

          git_.run(argv, "GitFetchFailed", true, false, environment);
        }
      }

      // The agent session of the pane this command runs in, when the runtime
      // confirms the process descends from it.
      ds::Option<CoordinatorReference> sourceCoordinator() {
        const auto id = maybeUnsigned(process_environment.lookup("TELAR_PANE_ID"));
        const auto generation = maybeUnsigned(process_environment.lookup("TELAR_PANE_GENERATION"));
        if (!id || !generation || *id == 0 || *generation == 0) {
          return ds::none;
        }

        try {
          Channel session{memory_, ds::none, false};

          session.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = *id, .pane_generation = *generation});
          const auto agents = session.template exchange<AgentSnapshot>(QueryAgents{});

          for (const auto& entry : agents.entries) {
            if (entry.pane_id == *id && entry.pane_generation == *generation && std::ranges::any_of(entry.session_id, [](Byte byte) {
                  return byte != 0;
                })) {
              return CoordinatorReference{.session_id = entry.session_id, .pane_id = *id, .pane_generation = *generation};
            }
          }
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a pane the runtime cannot confirm names no coordinator
        }

        return ds::none;
      }

      tbc::val_a<Text> formatCoordinator(const CoordinatorReference& reference) {
        return ds::format(memory_, "{}:{}:{}", lowerHex(reference.session_id.view()), reference.pane_id, reference.pane_generation);
      }

      tbc::mut_a<Memory> memory_;
      tbc::ref_b<WorktreeOptions> options_;
      tbc::ref_b<machines::MachineProfile> profile_;
      tbc::val_a<WorktreeGit> git_;
      tbc::val_a<Text> root_;
    };

    constexpr std::size_t session_id_bytes = 16;
    constexpr std::size_t session_id_digits = 2 * session_id_bytes;

    // A session id as the 32 hexadecimal digits it is written in.
    FixedText<session_id_digits> hexSession(const ds::Array<Byte, session_id_bytes>& session) {
      ds::Array<char, session_id_digits> digits{};
      FixedText<session_id_digits> text;

      text.assign(encodeLowerHex(session.view(), digits.viewMut()));
      return text;
    }

    void worktreeAgent(Output& output, const AgentSnapshotEntry& agent) {
      constexpr auto escapes = JsonEscapes::control;

      output.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes).text(",\"provider_index\":").number(static_cast<Byte>(agent.provider)).text(",\"status\":").json(agentStatusName(agent.status), escapes).text(",\"workspace\":").json(agent.workspace_label, escapes).text(",\"tab\":").json(agent.tab_label, escapes).text(",\"title\":").json(agent.session_title, escapes).text(",\"cwd\":").json(agent.cwd_label, escapes).text(",\"blocked_reason\":").json(agentBlockedReasonName(agent.blocked_reason), escapes).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event, escapes).text(R"(,"plan":{"done":)").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step, escapes).text("},\"final_message\":").json(agent.final_message, escapes).text(",\"session_id\":").json(hexSession(agent.session_id).view(), escapes).text("}");
    }

    std::string_view worktreeState(WorktreeState state) {
      switch (state) {
      case WorktreeState::active:
        return "active";
      case WorktreeState::integrated:
        return "integrated";
      case WorktreeState::gone:
        return "gone";
      }

      return "active";
    }

    std::string_view commandState(CommandState state) {
      switch (state) {
      case CommandState::none:
        return "none";
      case CommandState::running:
        return "running";
      case CommandState::exited:
        return "exited";
      }

      return "none";
    }

    void worktreeEntry(Output& output, const WorktreeListEntry& entry, std::span<const AgentSnapshotEntry> agents, bool json) {
      constexpr auto escapes = JsonEscapes::control;

      if (!json) {
        const auto member = std::ranges::find(agents, entry.worktree, &AgentSnapshotEntry::work_tree);

        output.text(entry.branch).text("\t").text(entry.title.empty() ? entry.branch : entry.title).text("\t").text(worktreeState(entry.state)).text("\t").text(member == agents.end() ? "-" : agentStatusName(member->status)).text("\t+").number(entry.diff_added).text(" -").number(entry.diff_removed).text(" ").number(entry.diff_files).text(" files\t").text(entry.command_label.empty() ? "-" : entry.command_label).text(" ").text(commandState(entry.command_state)).text("\t").text(entry.path).text("\n");
        return;
      }

      output.text("{\"worktree_id\":").number(entry.worktree).text(",\"branch\":").json(entry.branch, escapes).text(",\"title\":").json(entry.title, escapes).text(",\"brief\":").json(entry.brief, escapes).text(",\"base\":").json(entry.base, escapes).text(",\"dispatched_from\":").json(entry.dispatched_from, escapes).text(",\"coordinator\":");
      if (entry.coordinator) {
        output.text("{\"session_id\":").json(hexSession(entry.coordinator->session_id).view()).text(",\"pane_id\":").number(entry.coordinator->pane_id).text(",\"pane_generation\":").number(entry.coordinator->pane_generation).text("}");
      } else {
        output.text("null");
      }

      output.text(",\"path\":").json(entry.path, escapes).text(",\"origin\":").json(entry.origin == WorktreeOrigin::telar ? "telar" : "external").text(",\"state\":").json(worktreeState(entry.state)).text(",\"source_workspace_id\":").number(entry.source).text(",\"workspace_id\":");
      if (entry.workspace) {
        output.number(*entry.workspace);
      } else {
        output.text("null");
      }

      output.text(R"(,"diff":{"added":)").number(entry.diff_added).text(",\"removed\":").number(entry.diff_removed).text(",\"files\":").number(entry.diff_files).text(",\"commits_ahead\":").number(entry.commits_ahead).text(R"(},"command":{"label":)").json(entry.command_label, escapes).text(",\"state\":").json(commandState(entry.command_state)).text(",\"exit_code\":").number(entry.command_exit).text("},\"agents\":[");
      bool first = true;

      for (const auto& agent : agents) {
        if (agent.work_tree != entry.worktree) {
          continue;
        }

        if (!first) {
          output.text(",");
        }

        worktreeAgent(output, agent);
        first = false;
      }

      output.text("]}");
    }

    struct WorktreeLaunch {
      ds::Option<std::uint64_t> setup;
      std::uint64_t worktree{};
      std::string_view path, branch, base;
      PaneOpened opened{};
    };

    void worktreeLaunch(Output& output, const WorktreeLaunch& launch, bool json) {
      if (json) {
        output.text("{\"worktree_id\":").number(launch.worktree).text(",\"setup_execution_id\":");
        if (launch.setup) {
          output.number(*launch.setup);
        } else {
          output.text("null");
        }

        output.text(",\"environment\":").json(launch.setup ? "ready" : "not_declared").text(",\"branch\":").json(launch.branch).text(",\"base\":").json(launch.base).text(",\"path\":").json(launch.path).text(",\"workspace_id\":").number(launch.opened.location.workspace.id).text(",\"tab_id\":").number(launch.opened.location.tab_id).text(",\"pane_id\":").number(launch.opened.pane_id).text(",\"pane_generation\":").number(launch.opened.pane_generation).text("}\n");
      } else {
        output.text("worktree ").text(launch.branch).text(" at ").text(launch.path).text(": pane ").number(launch.opened.pane_id).text(" in workspace ").number(launch.opened.location.workspace.id).text("\n");
      }
    }

    ds::Option<std::uint64_t> currentWorkspace() {
      return maybeUnsigned(process_environment.lookup("TELAR_WORKSPACE_ID"));
    }

    bool confirmRemoval(const char* question) {
      if (::isatty(STDIN_FILENO) == 0) {
        throw Failure{"this removal needs a person to confirm it at a terminal"};
      }

      constexpr std::size_t answer_bytes = 15;
      ds::Array<char, answer_bytes> buffer{};

      writeFormatted(STDERR_FILENO, "{}? [y/N] ", std::string_view{question});
      // The terminal hands over a line at most; what is left of a longer one waits for the next read.
      auto count = ::read(STDIN_FILENO, buffer.dataMut(), buffer.size());

      while (count < 0 && sys::lastError() == EINTR) {
        count = ::read(STDIN_FILENO, buffer.dataMut(), buffer.size());
      }

      if (count <= 0) {
        return false;
      }

      const std::string_view line{buffer.data(), static_cast<std::size_t>(count)};
      const auto answer = trimText(line.substr(0, line.find('\0')), " \r\t\n");

      return asciiEqualIgnoreCase(answer, "y") || asciiEqualIgnoreCase(answer, "yes");
    }

    // Reports what the command that exited printed, and gives its status.
    int reportExit(Output& output, bool json, const PaneOpened& opened, const PaneText& reply) {
      auto text = reply.text;

      while (text.ends_with(' ') || text.ends_with('\n')) {
        text.remove_suffix(1);
      }

      if (json) {
        output.text("{\"pane_id\":").number(opened.pane_id).text(",\"exit_code\":").number(*reply.exit_code).text(",\"truncated\":").boolean(reply.truncated).text(",\"output\":").json(text).text("}\n");
      } else {
        output.text(text).text("\n");
        if (reply.truncated) {
          writeText("telar worktree: older rows were omitted\n", STDERR_FILENO);
        }
      }

      return *reply.exit_code >= 0 && std::cmp_less_equal(*reply.exit_code, std::numeric_limits<std::uint8_t>::max()) ? *reply.exit_code : 1;
    }

    class WorktreeCommand {
    public:
      WorktreeCommand(Memory& memory, const WorktreeOptions& options)
          : memory_(memory),
            options_(options),
            catalog_channel_(memory, options.socket, true),
            catalog_(catalog_channel_.catalog()),
            session_(memory, options.socket, false),
            git_(memory),
            output_(memory),
            adopted_path_(memory),
            adopted_branch_(memory),
            adopted_base_(memory) {}

      WorktreeCommand(const WorktreeCommand&) = delete;
      WorktreeCommand& operator=(const WorktreeCommand&) = delete;
      WorktreeCommand(WorktreeCommand&&) = delete;
      WorktreeCommand& operator=(WorktreeCommand&&) = delete;
      ~WorktreeCommand() = default;

      int run() {
        using Action = WorktreeOptions::Action;
        int result = 0;

        switch (options_.action) {
        case Action::create:
          create();
          break;
        case Action::exec:
          result = exec();
          break;
        case Action::list:
          list();
          break;
        case Action::open:
          open();
          break;
        case Action::diff:
          diff();
          break;
        case Action::remove:
          remove();
          break;
        case Action::resolve:
          resolve();
          break;
        case Action::fetch:
          throw Failure{"fetch needs another machine"};
        }

        output_.flush();
        return result;
      }

    private:
      [[nodiscard]] const WorkspaceListEntry* workspace(std::uint64_t id) const {
        const auto found = std::ranges::find(catalog_.entries, id, &WorkspaceListEntry::workspace);

        return found == catalog_.entries.end() ? nullptr : &*found;
      }

      [[nodiscard]] const WorkspaceListEntry* workspaceAt(std::string_view path) const {
        for (const auto& entry : catalog_.entries) {
          const bool holds_worktree = std::ranges::any_of(catalog_.worktrees, [&](const auto& worktree) {
            return worktree.workspace == entry.workspace;
          });
          if (entry.path == path && !holds_worktree) {
            return &entry;
          }
        }

        return nullptr;
      }

      [[nodiscard]] const WorktreeListEntry* find(std::string_view reference) const {
        const WorktreeListEntry* found = nullptr;

        for (const auto& entry : catalog_.worktrees) {
          if (entry.branch != reference) {
            continue;
          }

          if (found != nullptr) {
            throw Failure{"more than one worktree has that branch or title; name it by the other"};
          }

          found = &entry;
        }

        if (found != nullptr) {
          return found;
        }

        for (const auto& entry : catalog_.worktrees) {
          if (!asciiEqualIgnoreCase(entry.title, reference)) {
            continue;
          }

          if (found != nullptr) {
            throw Failure{"more than one worktree has that branch or title; name it by the other"};
          }

          found = &entry;
        }

        return found;
      }

      Text originDirectory() {
        if (options_.workspace) {
          if (const auto id = maybeUnsigned(*options_.workspace)) {
            const auto* const entry = workspace(*id);
            if (entry == nullptr) {
              throw Failure{"workspace not found", 2};
            }

            return Text{memory_, entry->path};
          }

          return realDirectory(memory_, *options_.workspace);
        }

        if (const auto id = currentWorkspace()) {
          if (const auto* const entry = workspace(*id)) {
            return Text{memory_, entry->path};
          }
        }

        return realDirectory(memory_, ".");
      }

      std::uint64_t sourceWorkspace(std::string_view root) {
        if (options_.workspace) {
          if (const auto id = maybeUnsigned(*options_.workspace)) {
            return *id;
          }
        }

        if (const auto id = currentWorkspace()) {
          if (const auto* const entry = workspace(*id); entry != nullptr && checkoutOf(entry->path, root)) {
            return *id;
          }
        }

        if (const auto* const entry = workspaceAt(root)) {
          return entry->workspace;
        }

        const auto name = root.substr(root.rfind('/') + 1);
        const auto login = loginShell();
        const ds::Array shell{login.view()};
        const auto opened = session_.template exchange<PaneOpened>(CreateWorkspace{.size = workspace_size, .name = name, .launch = {.cwd = root, .arguments = shell}});

        return opened.location.workspace.id;
      }

      // Whether the workspace at `path` is a checkout of the repository at `root`.
      bool checkoutOf(std::string_view path, std::string_view root) {
        try {
          return git_.root(path) == root;
        } catch (const std::exception&) {
          return false;
        }
      }

      ds::Option<std::uint64_t> attributedPane() {
        // Each value is parsed before the next lookup, which may overwrite the storage it returned.
        const auto id = maybeUnsigned(process_environment.lookup("TELAR_PANE_ID"));
        const auto generation = maybeUnsigned(process_environment.lookup("TELAR_PANE_GENERATION"));
        if (!id || !generation || *id == 0 || *generation == 0) {
          return ds::none;
        }

        try {
          session_.template exchange<RequestCompleted>(VerifyPaneDescent{.pane_id = *id, .pane_generation = *generation});
          verified_generation_ = *generation;
          return *id;
        } catch (const std::exception&) {
          return ds::none;
        }
      }

      ds::Option<CoordinatorReference> coordinator(ds::Option<std::uint64_t> pane) {
        if (options_.coordinator) {
          return options_.coordinator;
        }

        if (!pane) {
          return ds::none;
        }

        const auto agents = session_.template exchange<AgentSnapshot>(QueryAgents{});

        for (const auto& entry : agents.entries) {
          if (entry.pane_id == *pane && entry.pane_generation == verified_generation_ && std::ranges::any_of(entry.session_id, [](Byte byte) {
                return byte != 0;
              })) {
            return CoordinatorReference{.session_id = entry.session_id, .pane_id = *pane, .pane_generation = verified_generation_};
          }
        }

        return ds::none;
      }

      [[nodiscard]] Text brief() const {
        Text result{memory_};

        for (std::size_t index = 1; index < options_.command.size(); ++index) {
          if (index != 1 && result.size() < brief_bytes) {
            result.push(' ');
          }

          for (const char character : std::string_view{options_.command[index]}) {
            const auto byte = static_cast<unsigned char>(character);

            if (result.size() == brief_bytes) {
              break;
            }

            if ((byte >= ' ' && byte != delete_character) || byte == '\n' || byte == '\t') {
              result.push(static_cast<char>(byte));
            }
          }
        }

        while (!result.empty()) {
          try {
            validateUtf8(result);
            break;
          } catch (const EncodingError&) {
            result.truncate(result.size() - 1);
          }
        }

        return result;
      }

      PaneOpened launch(std::uint64_t id, std::string_view directory) {
        ds::Vec<std::string_view, Memory> argv{memory_};
        const auto login = loginShell();
        const auto shell = login.view();

        if (options_.command.empty()) {
          argv.push(shell);
        } else {
          const auto line = loginShellScript(shell);
          if (!line.empty()) {
            const ds::Array<std::string_view, 5> login_words{shell, "-l", "-i", "-c", line};

            argv.extend(login_words.view());
          }

          for (const std::string_view word : options_.command) {
            argv.push(word);
          }
        }

        return session_.template exchange<PaneOpened>(LaunchWorktree{.worktree = id, .label = options_.label.valueOr(""), .size = launch_size, .launch = {.cwd = directory, .arguments = argv.view()}});
      }

      void create() {
        const auto directory = originDirectory();
        const auto root = git_.root(directory);
        const auto branch = *options_.branch;
        Text checkout{memory_};

        if (options_.directory) {
          checkout.assign(*options_.directory);
        } else {
          sessions::appendWorktreeCheckout(checkout, {.root = root, .branch = branch});
        }

        for (const auto& entry : catalog_.worktrees) {
          if (entry.path == checkout || entry.branch == branch) {
            throw Failure{"that worktree already exists; use `telar worktree exec` to run more there"};
          }
        }

        const auto base = options_.from ? Text{memory_, *options_.from} : git_.currentBranch(root);

        try {
          sessions::branch(base);
        } catch (const std::invalid_argument&) {
          throw Failure{"UnusableBase"};
        }

        constexpr std::size_t maximum_worktrees = 64;
        if (catalog_.worktrees.size() >= maximum_worktrees) {
          throw Failure{"WorktreeLimitReached"};
        }

        const auto source = sourceWorkspace(root);

        git_.add(root, checkout, branch, base);
        const auto pane = attributedPane();
        const auto reference = coordinator(pane);
        const auto description = brief();
        const auto registered = session_.template exchange<WorktreeRegistered>(RegisterWorktree{.source = source, .created_by = pane, .path = checkout, .branch = branch, .base = base, .title = options_.title.valueOr(""), .brief = description, .dispatched_from = options_.dispatched_from.valueOr(""), .coordinator = reference});
        const auto setup = project_setup::prepare(memory_, session_.control(), checkout, options_.setup);
        const auto opened = launch(registered.worktree, checkout);

        worktreeLaunch(output_, WorktreeLaunch{.setup = setup, .worktree = registered.worktree, .path = checkout, .branch = branch, .base = base, .opened = opened}, options_.json);
      }

      ds::Vec<GitWorktree, Memory> untracked() {
        // Keeps the worktrees the runtime does not track.
        class Untracked final : public WorktreeFilter {
        public:
          explicit Untracked(const WorkspaceList& catalog)
              : catalog_(catalog) {}

          bool operator()(std::string_view path) const override {
            return std::ranges::none_of(catalog_.worktrees, [&](const auto& tracked) {
              return tracked.path == path;
            });
          }

        private:
          const WorkspaceList& catalog_;
        };

        try {
          return git_.listed(realDirectory(memory_, "."), Untracked{catalog_});
        } catch (const std::exception&) {
          return ds::Vec<GitWorktree, Memory>{memory_};
        }
      }

      WorktreeListEntry findOrAdopt() {
        if (const auto* const entry = find(*options_.branch)) {
          return *entry;
        }

        for (const auto& entry : untracked()) {
          if (entry.branch != *options_.branch) {
            continue;
          }

          const auto root = git_.root(entry.path);

          // Copies in the command's memory, which outlive the list they were found in.
          adopted_path_ = Text{memory_, entry.path.view()};
          adopted_branch_ = Text{memory_, entry.branch.view()};
          adopted_base_ = git_.currentBranch(root);
          const auto source = sourceWorkspace(root);
          const auto pane = attributedPane();
          const auto reference = coordinator(pane);
          const auto registered = session_.template exchange<WorktreeRegistered>(RegisterWorktree{.source = source, .created_by = pane, .path = adopted_path_, .branch = adopted_branch_, .base = adopted_base_, .coordinator = reference});

          return {.worktree = registered.worktree, .source = source, .path = adopted_path_, .branch = adopted_branch_, .base = adopted_base_};
        }

        throw Failure{"no tracked worktree matches that branch or title", 2};
      }

      int exec() {
        const auto entry = findOrAdopt();
        const auto opened = launch(entry.worktree, entry.path);

        if (options_.wait) {
          return wait(opened);
        }

        worktreeLaunch(output_, WorktreeLaunch{.worktree = entry.worktree, .path = entry.path, .branch = entry.branch, .base = entry.base, .opened = opened}, options_.json);
        return 0;
      }

      int wait(const PaneOpened& opened) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{options_.timeout};
        constexpr std::uint16_t maximum_rows = 2000;
        constexpr unsigned wait_poll_ms = 250;

        for (;;) {
          const auto reply = session_.template exchange<PaneText>(ReadPane{.pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .rows = maximum_rows, .source = PaneTextSource::recent});
          if (reply.exit_code) {
            return reportExit(output_, options_.json, opened, reply);
          }

          if (std::chrono::steady_clock::now() >= deadline) {
            writeFormatted(STDERR_FILENO, "telar worktree: the command is still running after {}s; pane {}\n", options_.timeout, opened.pane_id);
            return 3;
          }

          std::this_thread::sleep_for(std::chrono::milliseconds{wait_poll_ms});
        }
      }

      void list() {
        Channel agents_channel{memory_, options_.socket, false};
        const auto agents = agents_channel.template exchange<AgentSnapshot>(QueryAgents{});
        ds::Option<std::uint64_t> source;

        if (options_.workspace) {
          source = maybeUnsigned(*options_.workspace);
          if (!source) {
            const auto* const entry = workspaceAt(*options_.workspace);
            if (entry == nullptr) {
              throw Failure{"workspace not found", 2};
            }

            source = entry->workspace;
          }
        }

        output_.text(options_.json ? "[" : "BRANCH\tTITLE\tSTATE\tAGENT\tDIFF\tCOMMAND\tPATH\n");
        bool first = true;

        for (const auto& entry : catalog_.worktrees) {
          if (source && entry.source != *source) {
            continue;
          }

          if (options_.json && !first) {
            output_.text(",");
          }

          worktreeEntry(output_, entry, agents.entries, options_.json);
          first = false;
        }

        for (const auto& entry : untracked()) {
          if (options_.json) {
            if (!first) {
              output_.text(",");
            }

            output_.text(R"({"worktree_id":null,"branch":)").json(entry.branch, JsonEscapes::control).text(",\"path\":").json(entry.path, JsonEscapes::control).text(R"(,"origin":"untracked","agents":[]})");
          } else {
            output_.text(entry.branch).text("\t-\tuntracked\t-\t-\t-\t").text(entry.path).text("\n");
          }

          first = false;
        }

        if (options_.json) {
          output_.text("]\n");
        }
      }

      void open() {
        const auto* const entry = find(*options_.branch);
        if (entry == nullptr) {
          throw Failure{"no tracked worktree matches that branch or title", 2};
        }

        if (!entry->workspace) {
          throw Failure{"nothing was launched in that worktree yet; use `telar worktree exec`", 2};
        }

        const auto clients = session_.template exchange<ClientList>(QueryClients{});
        ClientDescriptor client;

        try {
          client = chooseClient(clients.entries, options_.client);
        } catch (const Failure&) {
          throw Failure{"no UI client is attached; pass --client ID"};
        }

        RequestClientCommand request;

        request.route = {.id = client.id, .generation = client.generation};
        request.action = ClientAction::workspace_select;
        request.target_id = *entry->workspace;
        const auto reply = session_.template exchange<ClientCommandResult>(request);
        if (reply.status == ClientCommandStatus::failed) {
          throw Failure{"the UI client could not open the worktree"};
        }

        if (options_.json) {
          output_.text("{\"worktree_id\":").number(entry->worktree).text(",\"workspace_id\":").number(*entry->workspace).text(",\"client_id\":").number(client.id).text("}\n");
        } else {
          output_.text("opened ").text(entry->branch).text(" in client ").number(client.id).text("\n");
        }
      }

      void diff() {
        const auto entry = findOrAdopt();
        const auto against = options_.uncommitted ? Text{memory_, "HEAD"} : git_.line({"git", "-C", entry.path, "merge-base", entry.base.empty() ? "HEAD" : entry.base, "HEAD"});
        ds::Vec<std::string_view, Memory> argv{memory_};

        const ds::Array<std::string_view, 5> diff_words{"git", "-C", entry.path, "--no-pager", "diff"};

        argv.extend(diff_words.view());
        if (options_.stat) {
          argv.push("--stat");
        }

        argv.push(against.view());
        git_.run(argv.view(), "GitDiffFailed", true);
      }

      void remove() {
        const auto* const entry = find(*options_.branch);
        if (entry == nullptr) {
          throw Failure{"no tracked worktree matches that branch or title", 2};
        }

        ds::Option<Text> root;

        try {
          root = git_.root(entry->path);
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a checkout Git no longer knows leaves the catalog without a removal
        }

        if (root && !options_.force && !git_.run({"git", "-C", entry->path, "status", "--porcelain"}, "GitFailed").empty()) {
          throw Failure{"the worktree has local changes; commit them or pass --force"};
        }

        if (options_.force && !confirmRemoval("Remove the worktree and discard its local changes")) {
          throw Failure{"removal cancelled"};
        }

        const bool merged = options_.delete_branch && root && git_.merged({.root = *root, .branch = entry->branch});
        if (options_.delete_branch && !merged && !confirmRemoval("Also delete its branch and the commits no other branch has")) {
          throw Failure{"removal cancelled"};
        }

        if (root) {
          if (options_.force) {
            git_.run({"git", "-C", *root, "worktree", "remove", "--force", "--", entry->path}, "git worktree remove failed");
          } else {
            git_.run({"git", "-C", *root, "worktree", "remove", "--", entry->path}, "git worktree remove failed");
          }
        }

        // Only a checkout that is gone leaves the runtime's catalog; one Git kept stays tracked.
        session_.template exchange<RequestCompleted>(ForgetWorktree{.worktree = entry->worktree});
        if (root && options_.delete_branch) {
          git_.run({"git", "-C", *root, "branch", merged ? "-d" : "-D", "--", entry->branch}, "git branch deletion failed; the branch may not be merged");
        }

        if (options_.json) {
          output_.text("{\"worktree_id\":").number(entry->worktree).text(",\"path\":").json(entry->path).text(",\"branch_deleted\":").boolean(options_.delete_branch).text("}\n");
        } else {
          output_.text("removed ").text(entry->branch).text(" at ").text(entry->path).text("\n");
        }
      }

      // `repository_discovery.find`, with this command's descriptions of its errors.
      void resolve() {
        static constexpr ds::Array<std::pair<std::string_view, const char*>, 4> descriptions{
            {
                {"RepositoryNotInWorkspace", "that workspace holds another repository"},
                {"AmbiguousRepository", "several clones of this repository are open on the machine; pass --workspace PATH"},
                {"WorkspaceNotFound", "workspace not found"},
                {"NotARepository", "not inside a git repository"},
            },
        };

        ds::Option<Text> found;

        try {
          found = repository::find(memory_, *options_.repository, options_.workspace, options_.socket);
        } catch (const std::runtime_error& error) {
          const auto* const description = std::ranges::find(descriptions, std::string_view{error.what()}, &std::pair<std::string_view, const char*>::first);
          if (description == descriptions.end()) {
            throw;
          }

          throw Failure{description->second, description->first == "WorkspaceNotFound" ? 2 : 1};
        }

        if (!found) {
          throw Failure{"no workspace on the machine holds this repository; open one there or pass --workspace PATH"};
        }

        if (options_.json) {
          output_.text("{\"repository\":").json(*options_.repository).text(",\"path\":").json(*found).text("}\n");
        } else {
          output_.text(*found).text("\n");
        }
      }

      Memory& memory_;
      const WorktreeOptions& options_;
      Channel catalog_channel_;
      // Views what the catalog channel decoded.
      tbc::val_self<WorkspaceList> catalog_;
      Channel session_;
      WorktreeGit git_;
      Output output_;
      std::uint64_t verified_generation_ = 0;
      Text adopted_path_, adopted_branch_, adopted_base_;
    };

  }

  int worktree(Memory& memory, const WorktreeOptions& options) {
    try {
      // The machine's own label runs here like any other create.
      if (options.machine) {
        if (const auto profile = machine::resolve(memory, *options.machine)) {
          WorktreeDispatch dispatch{memory, options, *profile};

          return options.action == WorktreeOptions::Action::fetch ? dispatch.fetch() : dispatch.create();
        }

        if (options.action == WorktreeOptions::Action::fetch) {
          throw Failure{"FetchNeedsAnotherMachine"};
        }
      }

      return WorktreeCommand{memory, options}.run();
    } catch (const Failure& error) {
      const auto message = describeDispatchError(error.what());

      writeFormatted(STDERR_FILENO, "telar worktree: {}\n", message);
      return error.status() == 2 || error.code() == FailureCode::worktree_not_found || error.code() == FailureCode::workspace_not_found ? 2 : 1;
    } catch (const std::exception& error) {
      const auto message = describeDispatchError(error.what());

      writeFormatted(STDERR_FILENO, "telar worktree: {}\n", message);
      return 1;
    }
  }

}

namespace telar::runtime::cli::repository {

}

namespace telar::runtime::cli::sessions {

}

namespace telar::runtime::cli::repository {

}

namespace telar::runtime::cli {

  namespace {

    RepositoryOptions::Action repositoryAction(std::string_view action) {
      if (action == "prepare") {
        return RepositoryOptions::Action::prepare;
      }

      if (action == "receive") {
        return RepositoryOptions::Action::receive;
      }

      if (action == "tips") {
        return RepositoryOptions::Action::tips;
      }

      throw std::invalid_argument{"UnknownRepositoryAction"};
    }

    // An option of a repository action, with the value it takes.
    void repositoryOption(tbc::mut_a<RepositoryOptions> self, std::string_view arg, Cursor& cursor) {
      using Action = RepositoryOptions::Action;
      const auto value = cursor.take("MissingRepositoryOptionValue");

      if (arg == "--machine" && self.action == Action::prepare) {
        self.machine = value;
      } else if (arg == "--from" && self.action == Action::prepare) {
        self.from = value;
      } else if (arg == "--workspace") {
        self.workspace = value;
      } else if (arg == "--identity" && self.action != Action::prepare) {
        self.identity = value;
      } else if (arg == "--transport" && self.action == Action::receive) {
        self.transport = value;
      } else if (arg == "--commit" && self.action == Action::receive) {
        self.commit = value;
      } else if (arg == "--ref" && self.action == Action::receive) {
        self.ref = value;
      } else if (arg == "--bytes" && self.action == Action::receive) {
        self.bytes = parseUnsigned<std::uint64_t>(value);
      } else {
        throw std::invalid_argument{"UnknownRepositoryOption"};
      }
    }

  }

  RepositoryOptions RepositoryOptions::parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingRepositoryAction"};
    }

    RepositoryOptions self{.action = repositoryAction(words.front())};
    Cursor cursor{words.subspan(1)};

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json") {
        self.json = true;
      } else {
        repositoryOption(self, arg, cursor);
      }
    }

    if (self.action == Action::prepare && !self.machine) {
      throw std::invalid_argument{"MissingMachineLabel"};
    }

    if (self.action == Action::tips && self.identity.empty()) {
      throw std::invalid_argument{"MissingRepositoryIdentity"};
    }

    return self;
  }

}

namespace telar::runtime::cli::repository {

  void PreparedRepository::print(bool receiver) const {
    DescriptorWriter output{STDOUT_FILENO};

    output.print(R"({{"path":{},"commit":{},"repository":{},)", quoteJson(path), quoteJson(commit), quoteJson(repository));
    if (receiver) {
      output.print(R"("repository_ready":true,"reused":{})", jsonBoolean(reused));
    } else {
      output.print(R"("reused":{},"repository_ready":true)", jsonBoolean(reused));
    }

    output.print(",\"environment\":\"not_run\"}}\n");
    output.flush();
  }

}
