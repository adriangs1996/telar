module telar.git.checkout;

import std;
import telar.tbc;
import telar.base.text;
import telar.platform.fs;
import telar.vocabulary;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // text.substr(offset, count) without its throw: an offset past the end gives an empty view.
    std::string_view substring(std::string_view text, std::size_t offset, std::size_t count = std::string_view::npos) noexcept {
      text.remove_prefix(std::min(offset, text.size()));
      text.remove_suffix(text.size() - std::min(count, text.size()));
      return text;
    }

    // Whether the config `key` lets the repository fetch objects lazily.
    bool fetchesLazily(std::string_view key) noexcept {
      return key == "extensions.partialclone" || (key.starts_with("remote.") && (key.ends_with(".promisor") || key.ends_with(".partialclonefilter") || key.ends_with(".uploadpack")));
    }

    // The driver a `filter.<driver>.<variable>` key names; none when `key` is no filter's.
    tbc::val_a<ds::Option<std::string_view>> filterDriver(tbc::val_a<std::string_view> key) noexcept {
      constexpr std::string_view prefix = "filter.";
      const auto variable = key.rfind('.');
      if (!key.starts_with(prefix) || variable < prefix.size()) {
        return ds::none;
      }

      return substring(key, prefix.size(), variable - prefix.size());
    }

  }

  tbc::val_a<ds::Option<std::string_view>> GitFiles::join(std::string_view directory, std::string_view suffix, tbc::val_a<std::span<char>> buffer) noexcept {
    while (directory.ends_with('/')) {
      directory.remove_suffix(1);
    }

    const auto length = directory.size() + 1 + suffix.size();
    if (length >= buffer.size()) {
      return ds::none;
    }

    std::ranges::copy(directory, buffer.begin());
    buffer[directory.size()] = '/';
    std::ranges::copy(suffix, buffer.subspan(directory.size() + 1).begin());
    buffer[length] = '\0';
    return std::string_view{buffer.data(), length};
  }

  tbc::val_a<ds::Option<std::string_view>> GitFiles::resolve(std::string_view directory, std::string_view path, tbc::val_a<std::span<char>> buffer) noexcept {
    if (path.empty() || path.contains('\0')) {
      return ds::none;
    }

    if (!path.starts_with('/')) {
      return join(directory, path, buffer);
    }

    if (path.size() >= buffer.size()) {
      return ds::none;
    }

    std::ranges::copy(path, buffer.begin());
    buffer[path.size()] = '\0';
    return std::string_view{buffer.data(), path.size()};
  }

  tbc::val_a<ds::Option<std::string_view>> GitFiles::directory(std::string_view root, tbc::val_a<std::span<char>> buffer) noexcept {
    // Room for the "gitdir: " prefix and the whitespace around the path.
    constexpr std::size_t gitdir_line_slack = 16;

    ds::Array<char, PATH_MAX> path{};
    const auto dot_git = join(root, ".git", path.viewMut());
    ds::Array<char, PATH_MAX + gitdir_line_slack> bytes{};
    const auto pointer = dot_git ? readRegularFile(*dot_git, bytes.viewMut()) : ds::none;
    if (!pointer) {
      return ds::none;
    }

    const auto contents = trimText(*pointer, " \t\r\n");
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return ds::none;
    }

    return resolve(root, trimText(substring(contents, prefix.size()), " \t"), buffer);
  }

  ds::Option<std::string_view> GitHead::read(std::string_view root) noexcept {
    const auto direct = GitFiles::join(root, ".git/HEAD", path_.viewMut());
    if (!direct) {
      return ds::none;
    }

    if (const auto contents = readRegularFile(*direct, head_.viewMut())) {
      return parse(*contents);
    }

    ds::Array<char, PATH_MAX> resolved{};
    const auto directory = GitFiles::directory(root, resolved.viewMut());
    if (!directory) {
      return ds::none;
    }

    const auto linked = GitFiles::join(*directory, "HEAD", path_.viewMut());
    const auto head = linked ? readRegularFile(*linked, head_.viewMut()) : ds::none;

    return head ? ds::Option{parse(*head)} : ds::none;
  }

  std::string_view GitHead::parse(std::string_view contents) noexcept {
    contents = trimText(contents, " \r\n");
    constexpr std::string_view reference = "ref:";
    constexpr std::string_view branch = "refs/heads/";

    if (contents.starts_with(reference)) {
      contents = trimText(substring(contents, reference.size()), " ");
      return contents.starts_with(branch) ? substring(contents, branch.size()) : contents;
    }

    constexpr std::size_t abbreviated_hash_length = 8;

    return substring(contents, 0, abbreviated_hash_length);
  }

  ds::Option<GitRepositoryFacts> GitRepositoryFacts::parse(std::string_view listing) noexcept {
    GitRepositoryFacts facts;

    while (!listing.empty()) {
      const auto scope_end = listing.find('\0');
      if (scope_end == 0) {
        break;
      }

      if (scope_end == std::string_view::npos) {
        return ds::none;
      }

      const auto scope = substring(listing, 0, scope_end);

      listing.remove_prefix(scope_end + 1);
      const auto entry_end = listing.find('\0');
      if (entry_end == std::string_view::npos) {
        return ds::none;
      }

      const auto entry = substring(listing, 0, entry_end);

      listing.remove_prefix(entry_end + 1);
      if (scope != "local" && scope != "worktree") {
        continue;
      }

      const auto key = substring(entry, 0, entry.find('\n'));
      if (fetchesLazily(key)) {
        facts.may_fetch = true;
        continue;
      }

      const auto filter = filterDriver(key);
      if (!filter) {
        continue;
      }

      const auto driver = *filter;
      if (driver.find_first_of("=\n") != std::string_view::npos) {
        return ds::none;
      }

      bool known = false;

      for (std::size_t index = 0; index < facts.driver_count; ++index) {
        known |= facts.drivers[index] == driver;
      }

      if (!known) {
        if (facts.driver_count == maximum_drivers) {
          return ds::none;
        }

        facts.drivers.atMut(facts.driver_count++) = driver;
      }
    }

    return facts;
  }

  template <Allocator Memory>
  HardenedGit<Memory>::HardenedGit(tbc::mut_a<Memory> memory, std::string_view root)
      : memory_(memory),
        root_(memory, root),
        overrides_(memory) {}

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

    const auto number = substring(version, prefix.size());
    const auto dot = number.find('.');
    if (dot == std::string_view::npos) {
      return false;
    }

    // The minor version is the run of digits after the dot, as in "2.45.1" or "2.39.5 (Apple Git-154)".
    const auto subversion = substring(number, dot + 1);
    const auto major = parseExact<unsigned>(substring(number, 0, dot));
    const auto minor = parseExact<unsigned>(substring(subversion, 0, subversion.find_first_not_of("0123456789")));
    if (!major || !minor) {
      return false;
    }

    constexpr unsigned lazy_fetch_major = 2;
    constexpr unsigned lazy_fetch_minor = 45;

    return *major > lazy_fetch_major || (*major == lazy_fetch_major && *minor >= lazy_fetch_minor);
  }

  template <Allocator Memory>
  ds::Option<bool> HardenedGit<Memory>::overrideFilters(int status, std::string_view listing) {
    const auto facts = status > 1 ? ds::none : GitRepositoryFacts::parse(listing);
    if (!facts) {
      return ds::none;
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto* const suffix : {".clean=", ".smudge=", ".process="}) {
        overrides_.emplace(memory_, "filter.");
        overrides_.atMut(overrides_.size() - 1).append(facts->drivers[index]);
        overrides_.atMut(overrides_.size() - 1).append(suffix);
      }
    }

    return facts->may_fetch;
  }

  template <Allocator Memory>
  Command<Memory> HardenedGit<Memory>::commandFor(std::span<const std::string_view> arguments) const {
    ds::Vec<std::string_view, Memory> complete{memory_};

    complete.reserve(git_observation_options.size() + (2 * overrides_.size()) + arguments.size());
    complete.extend(git_observation_options.view());
    for (const auto& override : overrides_) {
      complete.push("-c");
      complete.push(override);
    }

    complete.extend(arguments);
    return Command<Memory>{memory_, Launch{.cwd = root_, .arguments = complete}, CommandPurpose::administration};
  }

  template class HardenedGit<Memory>;
  template class HardenedGit<ConcurrentMemory>;

  ds::Option<LinkedWorktree::Found> LinkedWorktree::find(std::string_view directory) noexcept {
    if (!directory.starts_with('/') || directory.contains('\0')) {
      return ds::none;
    }

    constexpr unsigned maximum_depth = 64;

    for (unsigned depth = 0; depth < maximum_depth; ++depth) {
      const auto dot_git = GitFiles::join(directory, ".git", path_.viewMut());
      if (!dot_git) {
        return ds::none;
      }

      struct stat status{};
      if (::stat(dot_git->data(), &status) == 0) {
        if (S_ISDIR(status.st_mode)) {
          return ds::none;
        }

        const auto branch = linkedBranch(directory);

        return branch ? ds::Option{Found{.root_length = directory.size(), .branch = *branch}} : ds::none;
      }

      while (directory.size() > 1 && directory.ends_with('/')) {
        directory.remove_suffix(1);
      }

      const auto separator = directory.rfind('/');
      if (directory.size() <= 1 || separator == std::string_view::npos) {
        return ds::none;
      }

      directory = substring(directory, 0, std::max<std::size_t>(1, separator));
    }

    return ds::none;
  }

  ds::Option<std::string_view> LinkedWorktree::mainBranch(std::string_view root) noexcept {
    ds::Array<char, PATH_MAX> git_directory{};
    const auto directory = GitFiles::directory(root, git_directory.viewMut());
    if (!directory) {
      return ds::none;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_.viewMut());
    ds::Array<char, PATH_MAX> contents{};
    const auto common = common_path ? readRegularFile(*common_path, contents.viewMut()) : ds::none;
    ds::Array<char, PATH_MAX> resolved{};
    const auto common_directory = common ? GitFiles::resolve(*directory, trimText(*common, " \t\r\n"), resolved.viewMut()) : ds::none;
    const auto head_path = common_directory ? GitFiles::join(*common_directory, "HEAD", path_.viewMut()) : ds::none;
    const auto head = head_path ? readRegularFile(*head_path, head_.viewMut()) : ds::none;
    if (!head) {
      return ds::none;
    }

    const auto text = trimText(*head, " \r\n");
    constexpr std::string_view prefix = "ref: refs/heads/";

    return text.starts_with(prefix) && text.size() > prefix.size() ? ds::Option{substring(text, prefix.size())} : ds::none;
  }

  ds::Option<std::string_view> LinkedWorktree::linkedBranch(std::string_view root) noexcept {
    ds::Array<char, PATH_MAX> git_directory{};
    const auto directory = GitFiles::directory(root, git_directory.viewMut());
    if (!directory) {
      return ds::none;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_.viewMut());
    ds::Array<char, PATH_MAX> common{};
    if (!common_path || !readRegularFile(*common_path, common.viewMut())) {
      return ds::none;
    }

    const auto head_path = GitFiles::join(*directory, "HEAD", path_.viewMut());
    const auto head = head_path ? readRegularFile(*head_path, head_.viewMut()) : ds::none;
    if (!head) {
      return ds::none;
    }

    const auto branch = GitHead::parse(*head);

    return branch.empty() ? ds::none : ds::Option{branch};
  }

}
