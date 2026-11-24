module telar.git;

import std;
import telar.sys.posix;
import telar.base.text;
import telar.platform.fs;
import telar.base.ds;

namespace telar::git {

  using telar::runtime::asciiEqualIgnoreCase;
  using telar::runtime::substring;
  using telar::runtime::trimText;

  namespace {

    // The buffer of a small file, as large as its default limit.
    constexpr std::size_t small_file_capacity = default_limits::small_file;

    constexpr std::string_view heads_prefix = "refs/heads/";
    constexpr std::string_view symbolic_prefix = "ref:";

    // The branches visitBranches lists: at most `limit` valid ref names of at most `path_length`,
    // `count` of them so far, each handed to `visit`.
    struct BranchWalk {
      std::size_t limit = 0;
      std::size_t path_length = 0;
      // The bytes of the namespace and its slash that the names handed to `visit` leave out.
      std::size_t space = 0;
      std::size_t count = 0;
      void* target = nullptr;
      void (*visit)(void*, std::string_view) = nullptr;
    };

    bool ownedByCaller(const struct stat& status) noexcept {
      return status.st_uid == ::geteuid();
    }

    // Refs that live in the git directory of each worktree rather than the common one.
    bool perWorktreeReference(std::string_view name) noexcept {
      return name == "HEAD" || name.starts_with("refs/bisect/") || name.starts_with("refs/worktree/") || name.starts_with("refs/rewritten/");
    }

    std::string_view trimLineEnd(std::string_view text) noexcept {
      while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
        text.remove_suffix(1);
      }

      return text;
    }

    // A fetch refspec's mapping of `reference`, as git's match_name_with_pattern.
    bool mapRefspec(std::string_view source, std::string_view destination, std::string_view reference, PathName& mapped) noexcept {
      const auto star = source.find('*');
      if (star == std::string_view::npos) {
        return source == reference && mapped.assign({destination});
      }

      const auto prefix = substring(source, 0, star);
      const auto suffix = substring(source, star + 1);
      if (reference.size() < prefix.size() + suffix.size() || !reference.starts_with(prefix) || !reference.ends_with(suffix)) {
        return false;
      }

      const auto captured = substring(reference, prefix.size(), reference.size() - prefix.size() - suffix.size());
      const auto target = destination.find('*');
      if (target == std::string_view::npos) {
        return false;
      }

      return mapped.assign({substring(destination, 0, target), captured, substring(destination, target + 1)});
    }

    std::string_view shortReference(std::string_view name) noexcept {
      for (const auto prefix : {heads_prefix, std::string_view{"refs/remotes/"}}) {
        if (name.starts_with(prefix)) {
          return substring(name, prefix.size());
        }
      }

      return name;
    }

    // HEAD and either commondir or objects/ and refs/, before anything is read.
    bool looksLikeGitDirectory(int directory) noexcept {
      struct stat status{};
      if (::fstatat(directory, "HEAD", &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(status.st_mode)) {
        return false;
      }

      if (::fstatat(directory, "commondir", &status, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(status.st_mode)) {
        return true;
      }

      return ::fstatat(directory, "objects", &status, 0) == 0 && S_ISDIR(status.st_mode) && ::fstatat(directory, "refs", &status, 0) == 0 && S_ISDIR(status.st_mode);
    }

    // A remote's HEAD names its default branch: it is no branch of its own.
    bool remoteHead(std::string_view name) noexcept {
      return name.starts_with("refs/remotes/") && name.ends_with("/HEAD");
    }

    // The loose refs beneath `heads`, a namespace such as refs/heads, depth first in readdir's
    // order and at most `maximum_depth` directories deep; `name` holds the ref name of the entry
    // being read.
    void looseBranches(int heads, ds::String<Memory>& name, BranchWalk& walk) {
      constexpr std::size_t maximum_depth = 16;
      // The open directories from refs/heads down, and the length of `name` where each one's
      // entries start.
      ds::Array<ds::Option<runtime::DirectoryStream>, maximum_depth + 1> levels{};
      ds::Array<std::size_t, maximum_depth + 1> name_sizes{};
      std::size_t depth = 0;

      levels.atMut(0).emplace(heads);
      for (;;) {
        const auto directory = levels[depth]->descriptor();
        const auto* const entry = levels.atMut(depth).getMut().next();
        if (entry == nullptr) {
          if (depth == 0) {
            return;
          }

          levels.atMut(depth).reset();
          --depth;
          name.resize(name_sizes[depth]);
          continue;
        }

        if (walk.count >= walk.limit) {
          return;
        }

        const char* const child_name = std::data(entry->d_name);
        const std::string_view child{child_name};
        if (child == "." || child == "..") {
          continue;
        }

        struct stat state{};
        if (::fstatat(directory, child_name, &state, AT_SYMLINK_NOFOLLOW) != 0) {
          continue;
        }

        const auto size = name.size();

        name.push('/');
        name.append(child);
        if (S_ISDIR(state.st_mode) && depth < maximum_depth) {
          auto nested = openDirectory(directory, child_name, FinalLink::refuse);
          if (nested) {
            name_sizes.atMut(depth) = size;
            ++depth;
            levels.atMut(depth).emplace(std::move(nested));
            continue;
          }
        } else if (S_ISREG(state.st_mode) && validReferenceName(name, walk.path_length) && !remoteHead(name)) {
          walk.visit(walk.target, substring(name.view(), walk.space));
          ++walk.count;
        }

        name.resize(size);
      }
    }

  }

  Status::Status(Memory& memory)
      : branch(memory),
        upstream_name(memory) {}

  StatusReader::StatusReader(Memory& memory, Limits limits)
      : memory_(memory),
        limits_(limits),
        status_(memory),
        objects_(memory),
        graph_(memory),
        shallow_(memory),
        walk_(memory),
        index_(memory),
        staged_(memory),
        unstaged_(memory),
        config_bytes_(memory),
        worktree_config_bytes_(memory),
        config_scratch_(memory),
        packed_refs_(memory),
        head_reference_(memory),
        upstream_reference_(memory),
        commit_(memory),
        parents_(memory) {}

  const Status& StatusReader::read(std::string_view directory) noexcept {
    try {
      readRepository(directory);
    } catch (...) {
      forget();
      reset(RepositoryState::unknown);
    }

    try {
      objects_.trim();
    } catch (...) { // NOLINT(bugprone-empty-catch): trimming the caches is best effort; the status read stands without it
    }

    return status_;
  }

  const Status& StatusReader::refs(std::string_view directory) noexcept {
    try {
      readRepository(directory, true);
    } catch (...) {
      forget();
      reset(RepositoryState::unknown);
    }

    try {
      objects_.trim();
    } catch (...) { // NOLINT(bugprone-empty-catch): trimming the caches is best effort; the status read stands without it
    }

    return status_;
  }

  const Status& StatusReader::status() const noexcept {
    return status_;
  }

  void StatusReader::visitRemotes(void* target, void (*visit)(void*, std::string_view)) noexcept {
    if (status_.repository != RepositoryState::ready) {
      return;
    }

    try {
      static_cast<void>(parseConfig(std::string_view{config_bytes_}, config_scratch_, [&](const ConfigEntry& entry) {
        if (asciiEqualIgnoreCase(entry.section, "remote") && asciiEqualIgnoreCase(entry.key, "url") && !entry.subsection.empty()) {
          visit(target, entry.subsection);
        }

        return true;
      }));
    } catch (...) { // NOLINT(bugprone-empty-catch): a config that fails to parse lists the remotes visited before it
    }
  }

  std::size_t StatusReader::stashes(std::size_t limit) const noexcept {
    if (status_.repository != RepositoryState::ready || !common_) {
      return 0;
    }

    try {
      ds::String<Memory> log{memory_};
      if (readWhole(common_.get(), "logs/refs/stash", log, limits_.packed_refs, nullptr) != ReadStatus::ok) {
        return 0;
      }

      return std::min<std::size_t>(limit, static_cast<std::size_t>(std::ranges::count(std::string_view{log}, '\n')));
    } catch (...) {
      return 0;
    }
  }

  void StatusReader::visitReferences(std::string_view space, std::size_t limit, void* target, void (*visit)(void*, std::string_view)) const noexcept {
    if (status_.repository != RepositoryState::ready || !common_) {
      return;
    }

    BranchWalk walk{.limit = limit, .path_length = limits_.path_length, .space = space.size() + 1, .target = target, .visit = visit};

    try {
      ds::String<Memory> name{memory_, space};
      PathName terminated;
      const auto heads = terminated.assign({space}) ? openDirectory(common_.get(), terminated.cString(), FinalLink::refuse) : FileDescriptor{};
      if (heads) {
        looseBranches(heads.get(), name, walk);
      }
    } catch (...) { // NOLINT(bugprone-empty-catch): the packed refs are listed after loose ones that failed to read
    }

    if (packed_state_ != ReadStatus::ok) {
      return;
    }

    const std::string_view text{packed_refs_};

    for (std::size_t from = 0; from < text.size() && walk.count < limit;) {
      const auto end = std::min(text.find('\n', from), text.size());
      const auto line = trimLineEnd(substring(text, from, end - from));

      from = end + 1;
      const auto separator = line.find(' ');
      if (line.starts_with('#') || line.starts_with('^') || separator == std::string_view::npos) {
        continue;
      }

      const auto reference = substring(line, separator + 1);
      if (reference.size() > walk.space && reference.starts_with(space) && reference[space.size()] == '/' && validReferenceName(reference, limits_.path_length) && !remoteHead(reference)) {
        visit(target, substring(reference, walk.space));
        ++walk.count;
      }
    }
  }

  bool StatusReader::changed() const noexcept {
    if (!gitdir_ || status_.repository != RepositoryState::ready) {
      return true;
    }

    return probe() != inputs_ || (worktree_ && fingerprintAt(gitdir_.get(), "index") != index_.fingerprint());
  }

  void StatusReader::reset(RepositoryState state) {
    status_.repository = state;
    status_.bare = false;
    status_.linked_worktree = false;
    status_.head = HeadState::unknown;
    status_.branch.clear();
    status_.head_id = {};
    status_.upstream = UpstreamState::none;
    status_.upstream_name.clear();
    status_.upstream_id = {};
    status_.divergence = Accuracy::not_applicable;
    status_.ahead = 0;
    status_.behind = 0;
    status_.staged = Accuracy::not_applicable;
    status_.unstaged = Accuracy::not_applicable;
    status_.changes = {};
  }

  void StatusReader::forget() noexcept {
    worktree_.reset();
    gitdir_.reset();
    common_.reset();
    gitdir_identity_ = {};
    common_identity_ = {};
    inputs_ = {};
    config_loaded_ = false;
    packed_loaded_ = false;
    staged_current_ = false;
    divergence_current_ = false;
    staged_head_ = {};
    staged_index_ = {};
    objects_.close();
    graph_.clear();
    refs_current_ = false;
  }

  Inputs StatusReader::probe() const noexcept {
    Inputs inputs;

    inputs.head = fingerprintAt(gitdir_.get(), "HEAD");
    inputs.config = fingerprintAt(common_.get(), "config");
    inputs.worktree_config = config_.worktree_config ? fingerprintAt(gitdir_.get(), "config.worktree") : Fingerprint{};
    inputs.packed_refs = fingerprintAt(common_.get(), "packed-refs");
    inputs.branch = referenceFingerprint(head_reference_);
    inputs.upstream = referenceFingerprint(upstream_reference_);
    inputs.shallow = fingerprintAt(common_.get(), "shallow");
    return inputs;
  }

  Fingerprint StatusReader::referenceFingerprint(std::string_view name) const noexcept {
    PathName path;
    if (name.empty() || !path.assign({name})) {
      return {};
    }

    return fingerprintAt(perWorktreeReference(name) ? gitdir_.get() : common_.get(), path.cString());
  }

  void StatusReader::readRepository(std::string_view directory, bool refs_only) {
    status_.work = {};
    objects_.resetObjectsRead();
    walk_.resetCommitsRead();
    staged_.resetTreesRead();
    unstaged_.resetWork();

    Discovery found;

    switch (discover(directory, found)) {
    case Discovered::repository:
      break;
    case Discovered::none:
      forget();
      reset(RepositoryState::none);
      return;
    case Discovered::not_owned:
      forget();
      reset(RepositoryState::not_owned);
      return;
    case Discovered::invalid:
      forget();
      reset(RepositoryState::invalid);
      return;
    case Discovered::error:
      forget();
      reset(RepositoryState::unknown);
      return;
    }

    struct stat gitdir_status{};
    struct stat common_status{};
    if (::fstat(found.gitdir.get(), &gitdir_status) != 0 || ::fstat(found.common.get(), &common_status) != 0) {
      forget();
      reset(RepositoryState::unknown);
      return;
    }

    const auto gitdir_identity = fingerprintOf(gitdir_status);
    const auto common_identity = fingerprintOf(common_status);
    if (gitdir_identity.device != gitdir_identity_.device || gitdir_identity.inode != gitdir_identity_.inode ||
        common_identity.device != common_identity_.device || common_identity.inode != common_identity_.inode) {
      forget();
      gitdir_identity_ = gitdir_identity;
      common_identity_ = common_identity;
    }

    worktree_ = std::move(found.worktree);
    gitdir_ = std::move(found.gitdir);
    common_ = std::move(found.common);
    status_.linked_worktree = !sameFile(gitdir_status, common_status);

    if (const auto state = loadConfig(); state != RepositoryState::ready) {
      refs_current_ = false;
      reset(state);
      return;
    }

    if (config_.bare) {
      worktree_.reset();
    } else if (config_.has_worktree && !status_.linked_worktree) {
      if (const auto state = openConfiguredWorktree(); state != RepositoryState::ready) {
        refs_current_ = false;
        reset(state);
        return;
      }
    }

    status_.repository = RepositoryState::ready;
    status_.format = config_.format;
    status_.bare = !worktree_;

    if (!objects_.open(common_.get(), config_.format, limits_)) {
      refs_current_ = false;
      reset(RepositoryState::invalid);
      return;
    }

    const auto inputs = probe();
    if (!refs_current_ || inputs != inputs_) {
      readReferences();
    }

    if (refs_only) {
      return;
    }

    readDivergence();
    readChanges();

    status_.work.objects_read = objects_.objectsRead();
    status_.work.commits_read = walk_.commitsRead();
    status_.work.trees_read = staged_.treesRead();
    status_.work.entries_checked = unstaged_.work().entries_checked;
    status_.work.files_hashed = unstaged_.work().files_hashed;
    status_.work.bytes_hashed = unstaged_.work().bytes_hashed;
  }

  Discovered StatusReader::discover(std::string_view directory, Discovery& found) const {
    PathName start;
    if (directory.empty() || directory.front() != '/' || !start.assign({directory})) {
      return Discovered::error;
    }

    auto current = openDirectory(AT_FDCWD, start.cString());
    if (!current) {
      return sys::lastError() == ENOENT || sys::lastError() == ENOTDIR ? Discovered::none : Discovered::error;
    }

    struct stat current_status{};
    if (::fstat(current.get(), &current_status) != 0) {
      return Discovered::error;
    }

    const auto device = current_status.st_dev;

    for (std::size_t depth = 0; depth < limits_.discovery_depth; ++depth) {
      if (const auto dot_git = discoverDotGit(current, current_status, found)) {
        return *dot_git;
      }

      if (looksLikeGitDirectory(current.get())) {
        const auto checked = checkGitDirectory(current.get(), found.common);
        if (checked == Discovered::repository) {
          found.gitdir = std::move(current);
        }

        return checked;
      }

      auto parent = openDirectory(current.get(), "..");
      struct stat parent_status{};
      if (!parent || ::fstat(parent.get(), &parent_status) != 0) {
        return Discovered::error;
      }

      if (sameFile(parent_status, current_status) || parent_status.st_dev != device) {
        return Discovered::none;
      }

      current = std::move(parent);
      current_status = parent_status;
    }

    return Discovered::none;
  }

  ds::Option<Discovered> StatusReader::discoverDotGit(FileDescriptor& current, const struct stat& current_status, Discovery& found) const {
    struct stat dot{};
    if (::fstatat(current.get(), ".git", &dot, 0) != 0) {
      return sys::lastError() == ENOENT || sys::lastError() == ENOTDIR ? ds::none : ds::Option{Discovered::error};
    }

    if (S_ISREG(dot.st_mode)) {
      if (!ownedByCaller(current_status) || !ownedByCaller(dot)) {
        return Discovered::not_owned;
      }

      return readGitFile(current, found);
    }

    if (!S_ISDIR(dot.st_mode)) {
      return Discovered::invalid;
    }

    auto candidate = openDirectory(current.get(), ".git");
    if (!candidate) {
      return Discovered::error;
    }

    if (!looksLikeGitDirectory(candidate.get())) {
      return ds::none;
    }

    if (!ownedByCaller(current_status)) {
      return Discovered::not_owned;
    }

    const auto checked = checkGitDirectory(candidate.get(), found.common);
    if (checked == Discovered::repository) {
      found.worktree = std::move(current);
      found.gitdir = std::move(candidate);
    }

    return checked;
  }

  Discovered StatusReader::readGitFile(FileDescriptor& current, Discovery& found) const {
    ds::Array<char, small_file_capacity> bytes{};
    std::string_view contents;
    if (readSmall(current.get(), ".git", bytes.viewMut().first(std::min(bytes.size(), limits_.small_file)), contents) != ReadStatus::ok) {
      return Discovered::invalid;
    }

    contents = trimLineEnd(contents);
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return Discovered::invalid;
    }

    const auto target = trimText(substring(contents, prefix.size()), " \t");
    PathName path;
    if (target.empty() || !path.assign({target})) {
      return Discovered::invalid;
    }

    auto candidate = openDirectory(current.get(), path.cString());
    if (!candidate || !looksLikeGitDirectory(candidate.get())) {
      return Discovered::invalid;
    }

    const auto checked = checkGitDirectory(candidate.get(), found.common);
    if (checked == Discovered::repository) {
      found.worktree = std::move(current);
      found.gitdir = std::move(candidate);
    }

    return checked;
  }

  Discovered StatusReader::checkGitDirectory(int directory, FileDescriptor& common) const {
    struct stat status{};
    if (::fstat(directory, &status) != 0) {
      return Discovered::error;
    }

    if (!ownedByCaller(status)) {
      return Discovered::not_owned;
    }

    ds::Array<char, small_file_capacity> bytes{};
    std::string_view contents;
    const auto small = bytes.viewMut().first(std::min(bytes.size(), limits_.small_file));
    const auto common_file = readSmall(directory, "commondir", small, contents);
    if (common_file == ReadStatus::ok) {
      PathName path;
      const auto target = trimLineEnd(contents);
      if (target.empty() || !path.assign({target})) {
        return Discovered::invalid;
      }

      common = openDirectory(directory, path.cString());
    } else if (common_file == ReadStatus::missing) {
      common = openDirectory(directory, ".");
    } else {
      return Discovered::invalid;
    }

    if (!common) {
      return Discovered::invalid;
    }

    if (::fstat(common.get(), &status) != 0) {
      return Discovered::error;
    }

    if (!ownedByCaller(status)) {
      return Discovered::not_owned;
    }

    if (readSmall(directory, "HEAD", small, contents) != ReadStatus::ok) {
      return Discovered::invalid;
    }

    contents = trimLineEnd(contents);
    const bool symbolic = contents.starts_with(symbolic_prefix) && trimText(substring(contents, symbolic_prefix.size()), " \t").starts_with("refs/");
    if (!symbolic && !ObjectId::fromHex(contents, ObjectFormat::sha1) && !ObjectId::fromHex(contents, ObjectFormat::sha256)) {
      return Discovered::invalid;
    }

    if (::fstatat(common.get(), "objects", &status, 0) != 0 || !S_ISDIR(status.st_mode) || ::fstatat(common.get(), "refs", &status, 0) != 0 || !S_ISDIR(status.st_mode)) {
      return Discovered::invalid;
    }

    return Discovered::repository;
  }

  RepositoryState StatusReader::openConfiguredWorktree() {
    PathName path;
    if (configured_worktree_.empty() || !path.assign({configured_worktree_})) {
      return RepositoryState::invalid;
    }

    auto directory = openDirectory(gitdir_.get(), path.cString());
    struct stat status{};
    if (!directory || ::fstat(directory.get(), &status) != 0) {
      return RepositoryState::invalid;
    }

    if (!ownedByCaller(status)) {
      return RepositoryState::not_owned;
    }

    worktree_ = std::move(directory);
    return RepositoryState::ready;
  }

  RepositoryState StatusReader::loadConfig() {
    const auto identity = fingerprintAt(common_.get(), "config");
    const auto worktree_identity = fingerprintAt(gitdir_.get(), "config.worktree");
    if (config_loaded_ && identity == inputs_.config && (!config_.worktree_config || worktree_identity == inputs_.worktree_config)) {
      return config_state_;
    }

    config_loaded_ = true;
    refs_current_ = false;
    config_ = {};
    configured_worktree_.clear();
    config_state_ = RepositoryState::ready;
    Fingerprint read_identity;
    const auto read = readWhole(common_.get(), "config", config_bytes_, limits_.config_file, &read_identity);

    inputs_.config = read_identity;
    if (read == ReadStatus::invalid) {
      config_state_ = RepositoryState::invalid;
      return config_state_;
    }

    bool valid = true;
    const auto visit = [&](bool worktree_file) {
      return [&, worktree_file](const ConfigEntry& entry) {
        if (asciiEqualIgnoreCase(entry.section, "core") && entry.subsection.empty()) {
          valid = coreVariable(entry, worktree_file) && valid;
        } else if (asciiEqualIgnoreCase(entry.section, "extensions") && entry.subsection.empty() && !worktree_file) {
          extension(entry);
        }

        return true;
      };
    };
    if (read == ReadStatus::ok && !parseConfig(std::string_view{config_bytes_}, config_scratch_, visit(false))) {
      valid = false;
    }

    if (valid && config_.version == 0) {
      // Repository format 0 ignores extensions, except that it honours worktreeConfig.
      config_.format = ObjectFormat::sha1;
      config_.unsupported = false;
    }

    if (valid && config_.worktree_config) {
      const auto worktree_read = readWhole(gitdir_.get(), "config.worktree", worktree_config_bytes_, limits_.config_file, &inputs_.worktree_config);
      if (worktree_read == ReadStatus::invalid ||
          (worktree_read == ReadStatus::ok && !parseConfig(std::string_view{worktree_config_bytes_}, config_scratch_, visit(true)))) {
        valid = false;
      }
    } else {
      inputs_.worktree_config = {};
    }

    if (!valid) {
      config_state_ = RepositoryState::invalid;
    } else if (config_.version > 1 || config_.unsupported) {
      config_state_ = RepositoryState::unsupported;
    }

    return config_state_;
  }

  bool StatusReader::coreVariable(const ConfigEntry& entry, bool worktree_file) {
    if (asciiEqualIgnoreCase(entry.key, "repositoryformatversion") && !worktree_file) {
      const auto version = entry.value ? telar::runtime::unsignedDecimal<unsigned>(*entry.value) : ds::none;

      config_.version = version.valueOr(0);
      return version.hasValue();
    }

    if (asciiEqualIgnoreCase(entry.key, "bare")) {
      const auto value = configBoolean(entry.value);

      config_.bare = value.valueOr(false);
      return value.hasValue();
    }

    if (asciiEqualIgnoreCase(entry.key, "filemode")) {
      const auto value = configBoolean(entry.value);

      config_.file_mode = value.valueOr(true);
      return value.hasValue();
    }

    if (asciiEqualIgnoreCase(entry.key, "symlinks")) {
      const auto value = configBoolean(entry.value);

      config_.symlinks = value.valueOr(true);
      return value.hasValue();
    }

    if (asciiEqualIgnoreCase(entry.key, "worktree") && entry.value) {
      config_.has_worktree = true;
      configured_worktree_.assign(*entry.value);
    }

    return true;
  }

  void StatusReader::extension(const ConfigEntry& entry) {
    const auto value = entry.value.valueOr("");

    if (asciiEqualIgnoreCase(entry.key, "objectformat")) {
      if (asciiEqualIgnoreCase(value, "sha1")) {
        config_.format = ObjectFormat::sha1;
      } else if (asciiEqualIgnoreCase(value, "sha256")) {
        config_.format = ObjectFormat::sha256;
      } else {
        config_.unsupported = true;
      }
    } else if (asciiEqualIgnoreCase(entry.key, "refstorage")) {
      config_.unsupported = config_.unsupported || !asciiEqualIgnoreCase(value, "files");
    } else if (asciiEqualIgnoreCase(entry.key, "worktreeconfig")) {
      config_.worktree_config = configBoolean(entry.value).valueOr(false);
    } else {
      // Extensions that change nothing this reader reads; any other is unknown to it.
      bool known = false;

      for (const auto* const name : {"noop", "noop-v1", "preciousobjects", "partialclone", "compatobjectformat", "relativeworktrees", "submodulepathconfig"}) {
        known = known || asciiEqualIgnoreCase(entry.key, name);
      }

      config_.unsupported = config_.unsupported || !known;
    }
  }

  void StatusReader::readReferences() {
    resolveReferences();
    // A large packed-refs is read again when a ref changes rather than kept.
    constexpr std::size_t retained = std::size_t{1} << 20U;
    if (packed_refs_.capacity() > retained) {
      packed_refs_.clear();
      packed_refs_.shrinkToFit();
      packed_loaded_ = false;
    }
  }

  void StatusReader::resolveReferences() {
    refs_current_ = true;
    status_.head = HeadState::unknown;
    status_.branch.clear();
    status_.head_id = {};
    status_.upstream = UpstreamState::none;
    status_.upstream_name.clear();
    status_.upstream_id = {};
    head_reference_.clear();
    upstream_reference_.clear();
    inputs_.branch = {};
    inputs_.upstream = {};
    inputs_.shallow = fingerprintAt(common_.get(), "shallow");

    ds::Array<char, small_file_capacity> bytes{};
    std::string_view contents;
    const auto small = bytes.viewMut().first(std::min(bytes.size(), limits_.small_file));
    const auto packed = fingerprintAt(common_.get(), "packed-refs");
    if (!packed_loaded_ || packed != inputs_.packed_refs) {
      packed_loaded_ = true;
      packed_state_ = readWhole(common_.get(), "packed-refs", packed_refs_, limits_.packed_refs, &inputs_.packed_refs);
      if (packed_state_ == ReadStatus::missing) {
        inputs_.packed_refs = {};
      }
    }

    if (readSmall(gitdir_.get(), "HEAD", small, contents, &inputs_.head) != ReadStatus::ok) {
      inputs_.head = {};
      return;
    }

    contents = trimLineEnd(contents);
    if (!contents.starts_with(symbolic_prefix)) {
      if (const auto id = ObjectId::fromHex(contents, config_.format)) {
        status_.head = HeadState::detached;
        status_.head_id = *id;
      }

      return;
    }

    const auto target = trimText(substring(contents, symbolic_prefix.size()), " \t");
    if (!target.starts_with("refs/") || !validReferenceName(target, limits_.path_length)) {
      return;
    }

    head_reference_.assign(target);
    status_.branch.assign(target.starts_with(heads_prefix) ? substring(target, heads_prefix.size()) : target);
    // Resolved into copies: resolving reads the reader, so it cannot also write its fields.
    auto head_id = status_.head_id;
    auto branch = inputs_.branch;
    const auto head = resolve(target, head_id, &branch);

    status_.head_id = head_id;
    inputs_.branch = branch;
    switch (head) {
    case RefLookup::found:
      status_.head = HeadState::branch;
      break;
    case RefLookup::missing:
      status_.head = HeadState::unborn;
      break;
    case RefLookup::invalid:
      status_.head = HeadState::unknown;
      return;
    }

    readUpstream();
  }

  void StatusReader::readUpstream() {
    if (!head_reference_.view().starts_with(heads_prefix)) {
      return;
    }

    PathName remote;
    PathName merge;
    const auto configured = branchUpstream(remote, merge);
    if (!configured) {
      status_.upstream = UpstreamState::unknown;
      return;
    }

    if (!*configured) {
      return;
    }

    PathName tracking;
    const auto mapped = trackingReference(remote, merge, tracking);
    if (!mapped) {
      status_.upstream = UpstreamState::unknown;
      return;
    }

    if (!*mapped) {
      return;
    }

    if (!validReferenceName(tracking.view(), limits_.path_length)) {
      status_.upstream = UpstreamState::unknown;
      return;
    }

    upstream_reference_.assign(tracking.view());
    status_.upstream_name.assign(shortReference(tracking.view()));
    auto upstream_id = status_.upstream_id;
    auto upstream = inputs_.upstream;
    const auto found = resolve(tracking.view(), upstream_id, &upstream);

    status_.upstream_id = upstream_id;
    inputs_.upstream = upstream;
    switch (found) {
    case RefLookup::found:
      status_.upstream = UpstreamState::tracking;
      break;
    case RefLookup::missing:
      status_.upstream = UpstreamState::gone;
      break;
    case RefLookup::invalid:
      status_.upstream = UpstreamState::unknown;
      break;
    }
  }

  ds::Option<bool> StatusReader::branchUpstream(PathName& remote, PathName& merge) {
    const std::string_view branch{status_.branch};
    bool have_remote = false;
    bool have_merge = false;
    bool valid = true;
    const auto branches = [&](const ConfigEntry& entry) {
      if (!asciiEqualIgnoreCase(entry.section, "branch") || entry.subsection != branch || !entry.value) {
        return true;
      }

      if (asciiEqualIgnoreCase(entry.key, "remote")) {
        have_remote = remote.assign({*entry.value});
        valid = valid && have_remote;
      } else if (asciiEqualIgnoreCase(entry.key, "merge") && !have_merge) {
        // git tracks the first merge value of a branch.
        have_merge = merge.assign({*entry.value});
        valid = valid && have_merge;
      }

      return true;
    };
    if (!parseConfig(std::string_view{config_bytes_}, config_scratch_, branches) ||
        (config_.worktree_config && !parseConfig(std::string_view{worktree_config_bytes_}, config_scratch_, branches)) || !valid) {
      return ds::none;
    }

    if (!have_merge || !have_remote || remote.view().empty()) {
      return false;
    }

    if (!merge.view().starts_with("refs/") || !validReferenceName(merge.view(), limits_.path_length)) {
      return ds::none;
    }

    return true;
  }

  ds::Option<bool> StatusReader::trackingReference(const PathName& remote, const PathName& merge, PathName& tracking) {
    if (remote.view() == ".") {
      tracking.assign({merge.view()});
      return true;
    }

    bool matched = false;
    const auto remotes = [&](const ConfigEntry& entry) {
      if (!asciiEqualIgnoreCase(entry.section, "remote") || entry.subsection != remote.view() || !asciiEqualIgnoreCase(entry.key, "fetch") || !entry.value) {
        return true;
      }

      // A negative refspec only keeps refs out of a fetch; git still names the branch the
      // positive ones map to as the upstream.
      auto spec = *entry.value;
      if (spec.starts_with('^')) {
        return true;
      }

      if (spec.starts_with('+')) {
        spec.remove_prefix(1);
      }

      const auto colon = spec.find(':');
      if (!matched && colon != std::string_view::npos) {
        matched = mapRefspec(substring(spec, 0, colon), substring(spec, colon + 1), merge.view(), tracking);
      }

      return true;
    };
    if (!parseConfig(std::string_view{config_bytes_}, config_scratch_, remotes)) {
      return ds::none;
    }

    return matched;
  }

  RefLookup StatusReader::resolve(std::string_view name, ObjectId& id, Fingerprint* identity) {
    for (std::size_t depth = 0; depth <= limits_.symbolic_depth; ++depth) {
      PathName path;
      if (!validReferenceName(name, limits_.path_length) || !path.assign({name})) {
        return RefLookup::invalid;
      }

      ds::Array<char, small_file_capacity> bytes{};
      std::string_view contents;
      Fingerprint loose;
      const auto read = readSmall(perWorktreeReference(name) ? gitdir_.get() : common_.get(), path.cString(), bytes.viewMut().first(std::min(bytes.size(), limits_.small_file)), contents, &loose);

      if (depth == 0 && identity != nullptr) {
        *identity = read == ReadStatus::ok ? loose : Fingerprint{};
      }

      if (read == ReadStatus::invalid) {
        return RefLookup::invalid;
      }

      if (read == ReadStatus::missing) {
        return packedReference(name, id);
      }

      contents = trimLineEnd(contents);
      if (contents.starts_with(symbolic_prefix)) {
        const auto target = trimText(substring(contents, symbolic_prefix.size()), " \t");
        if (!target.starts_with("refs/")) {
          return RefLookup::invalid;
        }

        symbolic_.assign(target);
        name = symbolic_;
        continue;
      }

      const auto parsed = ObjectId::fromHex(trimText(contents, " \t"), config_.format);
      if (!parsed) {
        return RefLookup::invalid;
      }

      id = *parsed;
      return RefLookup::found;
    }

    return RefLookup::invalid;
  }

  RefLookup StatusReader::packedReference(std::string_view name, ObjectId& id) const {
    if (packed_state_ == ReadStatus::missing) {
      return RefLookup::missing;
    }

    if (packed_state_ != ReadStatus::ok) {
      return RefLookup::invalid;
    }

    const std::string_view text{packed_refs_};
    const auto digits = 2 * hashSize(config_.format);

    for (std::size_t from = 0;;) {
      const auto found = text.find(name, from);
      if (found == std::string_view::npos) {
        return RefLookup::missing;
      }

      from = found + 1;
      const auto after = found + name.size();
      if (found < digits + 1 || text[found - 1] != ' ' || (after < text.size() && text[after] != '\n' && text[after] != '\r')) {
        continue;
      }

      const auto line = found - digits - 1;
      if (line != 0 && text[line - 1] != '\n') {
        continue;
      }

      const auto parsed = ObjectId::fromHex(substring(text, line, digits), config_.format);
      if (!parsed) {
        return RefLookup::invalid;
      }

      id = *parsed;
      return RefLookup::found;
    }
  }

  void StatusReader::readDivergence() {
    if (status_.upstream != UpstreamState::tracking || status_.head != HeadState::branch) {
      status_.divergence = status_.upstream == UpstreamState::unknown || status_.head == HeadState::unknown ? Accuracy::unknown : Accuracy::not_applicable;
      status_.ahead = 0;
      status_.behind = 0;
      return;
    }

    // Commits never change, so a divergence holds while both tips do. A failed
    // walk is kept as well, so a limit is not hit again on every read.
    if (!divergence_current_ || status_.head_id != divergence_left_ || status_.upstream_id != divergence_right_) {
      divergence_current_ = true;
      divergence_left_ = status_.head_id;
      divergence_right_ = status_.upstream_id;
      divergence_result_ = Accuracy::unknown;
      divergence_ = {};
      if (shallow_.load(common_.get(), config_.format, limits_)) {
        // git ignores the commit-graph of a shallow clone, whose parents it rewrites.
        graph_.load(objects_.objects(), config_.format, limits_, !shallow_.empty());
        if (const auto counted = walk_.count({.objects = objects_, .graph = graph_, .shallow = shallow_, .limits = limits_}, status_.head_id, status_.upstream_id)) {
          divergence_result_ = Accuracy::exact;
          divergence_ = *counted;
        }
      }
    }

    status_.divergence = divergence_result_;
    status_.ahead = divergence_.ahead;
    status_.behind = divergence_.behind;
  }

  void StatusReader::readChanges() {
    if (!worktree_) {
      status_.staged = Accuracy::not_applicable;
      status_.unstaged = Accuracy::not_applicable;
      status_.changes = {};
      return;
    }

    const auto state = index_.load(gitdir_.get(), config_.format, limits_);
    if (state != IndexState::ready) {
      status_.staged = state == IndexState::unsupported ? Accuracy::unsupported : Accuracy::unknown;
      status_.unstaged = status_.staged;
      status_.changes = {};
      staged_current_ = false;
      return;
    }

    if (status_.head == HeadState::unknown) {
      status_.staged = Accuracy::unknown;
      staged_current_ = false;
    } else if (!staged_current_ || status_.head_id != staged_head_ || index_.fingerprint() != staged_index_) {
      // A failed comparison is cached too, so a limit is not hit again on every read.
      staged_counts_ = {};
      staged_result_ = compareStaged() ? Accuracy::exact : Accuracy::unknown;
      staged_current_ = true;
      staged_head_ = status_.head_id;
      staged_index_ = index_.fingerprint();
      status_.staged = staged_result_;
    } else {
      status_.staged = staged_result_;
    }

    ChangeCounts counts;

    status_.unstaged = unstaged_.compare(worktree_.get(), index_, {.format = config_.format, .file_mode = config_.file_mode, .symlinks = config_.symlinks}, limits_, counts) ? Accuracy::exact : Accuracy::unknown;
    status_.changes = status_.unstaged == Accuracy::exact ? counts : ChangeCounts{};
    if (status_.staged == Accuracy::exact) {
      status_.changes.staged_added = staged_counts_.staged_added;
      status_.changes.staged_modified = staged_counts_.staged_modified;
      status_.changes.staged_deleted = staged_counts_.staged_deleted;
    }
  }

  bool StatusReader::compareStaged() {
    ds::Option<ObjectId> tree;

    if (status_.head_id) {
      ObjectType type = ObjectType::none;
      CommitHeader header;

      parents_.clear();
      if (objects_.read(status_.head_id, type, commit_, limits_.commit_header) != Lookup::found || type != ObjectType::commit ||
          !parseCommit(commit_, config_.format, limits_.commit_parents, header, parents_)) {
        return false;
      }

      tree = header.tree;
    }

    return staged_.compare(objects_, index_, tree, limits_, staged_counts_);
  }

}
