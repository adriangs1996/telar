module telar.git.checkout;

import std;
import telar.tbc;
import telar.base.text;
import telar.platform.fs;
import telar.vocabulary;
import telar.sys.posix;

namespace telar::runtime {

  tbc::view<std::optional<std::string_view>, tbc::lt::a> GitFiles::join(std::string_view directory, std::string_view suffix, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    while (directory.ends_with('/')) {
      directory.remove_suffix(1);
    }

    const auto length = directory.size() + 1 + suffix.size();
    if (length >= buffer.size()) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), directory.data(), directory.size());
    buffer[directory.size()] = '/';
    std::memcpy(buffer.data() + directory.size() + 1, suffix.data(), suffix.size());
    buffer[length] = '\0';
    return std::string_view{buffer.data(), length};
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> GitFiles::resolve(std::string_view directory, std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    if (path.empty() || path.contains('\0')) {
      return std::nullopt;
    }

    if (!path.starts_with('/')) {
      return join(directory, path, buffer);
    }

    if (path.size() >= buffer.size()) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), path.data(), path.size());
    buffer[path.size()] = '\0';
    return std::string_view{buffer.data(), path.size()};
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> GitFiles::directory(std::string_view root, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    std::array<char, PATH_MAX> path;
    const auto dot_git = join(root, ".git", path);
    std::array<char, PATH_MAX + 16> bytes;
    const auto pointer = dot_git ? readRegularFile(*dot_git, bytes) : std::nullopt;
    if (!pointer) {
      return std::nullopt;
    }

    const auto contents = trimText(*pointer, " \t\r\n");
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return std::nullopt;
    }

    return resolve(root, trimText(contents.substr(prefix.size()), " \t"), buffer);
  }

  std::optional<std::string_view> GitHead::read(std::string_view root) noexcept {
    const auto direct = GitFiles::join(root, ".git/HEAD", path_);
    if (!direct) {
      return std::nullopt;
    }

    if (const auto contents = readRegularFile(*direct, head_)) {
      return parse(*contents);
    }

    std::array<char, PATH_MAX> resolved;
    const auto directory = GitFiles::directory(root, resolved);
    if (!directory) {
      return std::nullopt;
    }

    const auto linked = GitFiles::join(*directory, "HEAD", path_);
    const auto head = linked ? readRegularFile(*linked, head_) : std::nullopt;

    return head ? std::optional{parse(*head)} : std::nullopt;
  }

  std::string_view GitHead::parse(std::string_view contents) noexcept {
    contents = trimText(contents, " \r\n");
    constexpr std::string_view reference = "ref:";
    constexpr std::string_view branch = "refs/heads/";

    if (contents.starts_with(reference)) {
      contents = trimText(contents.substr(reference.size()), " ");
      return contents.starts_with(branch) ? contents.substr(branch.size()) : contents;
    }

    constexpr std::size_t abbreviated_hash_length = 8;

    return contents.substr(0, abbreviated_hash_length);
  }

  std::optional<GitRepositoryFacts> GitRepositoryFacts::parse(std::string_view listing) noexcept {
    GitRepositoryFacts facts;

    while (!listing.empty()) {
      const auto scope_end = listing.find('\0');
      if (scope_end == 0) {
        break;
      }

      if (scope_end == std::string_view::npos) {
        return std::nullopt;
      }

      const auto scope = listing.substr(0, scope_end);

      listing.remove_prefix(scope_end + 1);
      const auto entry_end = listing.find('\0');
      if (entry_end == std::string_view::npos) {
        return std::nullopt;
      }

      const auto entry = listing.substr(0, entry_end);

      listing.remove_prefix(entry_end + 1);
      if (scope != "local" && scope != "worktree") {
        continue;
      }

      const auto key = entry.substr(0, entry.find('\n'));
      if (key == "extensions.partialclone" || (key.starts_with("remote.") && (key.ends_with(".promisor") || key.ends_with(".partialclonefilter") || key.ends_with(".uploadpack")))) {
        facts.may_fetch = true;
        continue;
      }

      constexpr std::string_view prefix = "filter.";
      const auto variable = key.rfind('.');
      if (!key.starts_with(prefix) || variable < prefix.size()) {
        continue;
      }

      const auto driver = key.substr(prefix.size(), variable - prefix.size());
      if (driver.find_first_of("=\n") != std::string_view::npos) {
        return std::nullopt;
      }

      bool known = false;

      for (std::size_t index = 0; index < facts.driver_count; ++index) {
        known |= facts.drivers[index] == driver;
      }

      if (!known) {
        if (facts.driver_count == maximum_drivers) {
          return std::nullopt;
        }

        facts.drivers[facts.driver_count++] = driver;
      }
    }

    return facts;
  }

  template <Allocator Memory>
  HardenedGit<Memory>::HardenedGit(Memory& memory, std::string_view root)
      : memory_(memory),
        root_(root, AllocatorRef<char, Memory>{memory}),
        overrides_(AllocatorRef<String<Memory>, Memory>{memory}) {}

  template <Allocator Memory>
  void HardenedGit<Memory>::configure(Command<Memory>& command) {
    command.removeEnvironmentPrefix("GIT_");
    command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
    command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
    command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    command.setEnvironment("LC_ALL", "C");
  }

  template <Allocator Memory>
  bool HardenedGit<Memory>::honorsLazyFetchControl(std::string_view version) noexcept {
    while (!version.empty() && (version.back() == '\n' || version.back() == '\r')) {
      version.remove_suffix(1);
    }

    constexpr std::string_view prefix = "git version ";
    if (!version.starts_with(prefix)) {
      return false;
    }

    const auto number = version.substr(prefix.size());
    unsigned major = 0;
    const auto parsed = std::from_chars(number.data(), number.data() + number.size(), major);
    if (parsed.ec != std::errc{} || parsed.ptr == number.data() + number.size() || *parsed.ptr != '.') {
      return false;
    }

    unsigned minor = 0;
    const auto subversion = std::from_chars(parsed.ptr + 1, number.data() + number.size(), minor);
    constexpr unsigned lazy_fetch_major = 2;
    constexpr unsigned lazy_fetch_minor = 45;

    return subversion.ec == std::errc{} && (major > lazy_fetch_major || (major == lazy_fetch_major && minor >= lazy_fetch_minor));
  }

  template <Allocator Memory>
  std::optional<bool> HardenedGit<Memory>::overrideFilters(int status, std::string_view listing) {
    const auto facts = status > 1 ? std::nullopt : GitRepositoryFacts::parse(listing);
    if (!facts) {
      return std::nullopt;
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto suffix : {".clean=", ".smudge=", ".process="}) {
        overrides_.emplace_back("filter.", AllocatorRef<char, Memory>{memory_});
        overrides_.back() += facts->drivers[index];
        overrides_.back() += suffix;
      }
    }

    return facts->may_fetch;
  }

  template <Allocator Memory>
  Command<Memory> HardenedGit<Memory>::commandFor(std::span<const std::string_view> arguments) const {
    Vector<std::string_view, Memory> complete{AllocatorRef<std::string_view, Memory>{memory_}};

    complete.reserve(git_observation_options.size() + 2 * overrides_.size() + arguments.size());
    complete.insert(complete.end(), git_observation_options.begin(), git_observation_options.end());
    for (const auto& override : overrides_) {
      complete.push_back("-c");
      complete.push_back(override);
    }

    complete.insert(complete.end(), arguments.begin(), arguments.end());
    return Command<Memory>{memory_, Launch{.cwd = root_, .arguments = complete}, CommandPurpose::administration};
  }

  template class HardenedGit<Memory>;
  template class HardenedGit<ConcurrentMemory>;

  std::optional<LinkedWorktree::Found> LinkedWorktree::find(std::string_view directory) noexcept {
    if (!directory.starts_with('/') || directory.contains('\0')) {
      return std::nullopt;
    }

    constexpr unsigned maximum_depth = 64;

    for (unsigned depth = 0; depth < maximum_depth; ++depth) {
      const auto dot_git = GitFiles::join(directory, ".git", path_);
      if (!dot_git) {
        return std::nullopt;
      }

      struct stat status{};
      if (::stat(dot_git->data(), &status) == 0) {
        if (S_ISDIR(status.st_mode)) {
          return std::nullopt;
        }

        const auto branch = linkedBranch(directory);

        return branch ? std::optional{Found{directory.size(), *branch}} : std::nullopt;
      }

      while (directory.size() > 1 && directory.ends_with('/')) {
        directory.remove_suffix(1);
      }

      const auto separator = directory.rfind('/');
      if (directory.size() <= 1 || separator == std::string_view::npos) {
        return std::nullopt;
      }

      directory = directory.substr(0, std::max<std::size_t>(1, separator));
    }

    return std::nullopt;
  }

  std::optional<std::string_view> LinkedWorktree::mainBranch(std::string_view root) noexcept {
    std::array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory);
    if (!directory) {
      return std::nullopt;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_);
    std::array<char, PATH_MAX> contents;
    const auto common = common_path ? readRegularFile(*common_path, contents) : std::nullopt;
    std::array<char, PATH_MAX> resolved;
    const auto common_directory = common ? GitFiles::resolve(*directory, trimText(*common, " \t\r\n"), resolved) : std::nullopt;
    const auto head_path = common_directory ? GitFiles::join(*common_directory, "HEAD", path_) : std::nullopt;
    const auto head = head_path ? readRegularFile(*head_path, head_) : std::nullopt;
    if (!head) {
      return std::nullopt;
    }

    const auto text = trimText(*head, " \r\n");
    constexpr std::string_view prefix = "ref: refs/heads/";

    return text.starts_with(prefix) && text.size() > prefix.size() ? std::optional{text.substr(prefix.size())} : std::nullopt;
  }

  std::optional<std::string_view> LinkedWorktree::linkedBranch(std::string_view root) noexcept {
    std::array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory);
    if (!directory) {
      return std::nullopt;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_);
    std::array<char, PATH_MAX> common;
    if (!common_path || !readRegularFile(*common_path, common)) {
      return std::nullopt;
    }

    const auto head_path = GitFiles::join(*directory, "HEAD", path_);
    const auto head = head_path ? readRegularFile(*head_path, head_) : std::nullopt;
    if (!head) {
      return std::nullopt;
    }

    const auto branch = GitHead::parse(*head);

    return branch.empty() ? std::nullopt : std::optional{branch};
  }

}
