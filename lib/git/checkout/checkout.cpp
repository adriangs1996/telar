module telar.git.checkout;

import std;
import telar.tbc;
import telar.base.text;
import telar.platform.fs;
import telar.vocabulary;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> GitFiles::join(std::string_view directory, std::string_view suffix, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    while (directory.ends_with('/')) {
      directory.remove_suffix(1);
    }

    const auto length = directory.size() + 1 + suffix.size();
    if (length >= buffer.size()) {
      return ds::none;
    }

    std::memcpy(buffer.data(), directory.data(), directory.size());
    buffer[directory.size()] = '/';
    std::memcpy(buffer.data() + directory.size() + 1, suffix.data(), suffix.size());
    buffer[length] = '\0';
    return std::string_view{buffer.data(), length};
  }

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> GitFiles::resolve(std::string_view directory, std::string_view path, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    if (path.empty() || path.contains('\0')) {
      return ds::none;
    }

    if (!path.starts_with('/')) {
      return join(directory, path, buffer);
    }

    if (path.size() >= buffer.size()) {
      return ds::none;
    }

    std::memcpy(buffer.data(), path.data(), path.size());
    buffer[path.size()] = '\0';
    return std::string_view{buffer.data(), path.size()};
  }

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> GitFiles::directory(std::string_view root, tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept {
    ds::Array<char, PATH_MAX> path;
    const auto dot_git = join(root, ".git", path.viewMut());
    ds::Array<char, PATH_MAX + 16> bytes;
    const auto pointer = dot_git ? readRegularFile(*dot_git, bytes.viewMut()) : ds::none;
    if (!pointer) {
      return ds::none;
    }

    const auto contents = trimText(*pointer, " \t\r\n");
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return ds::none;
    }

    return resolve(root, trimText(contents.substr(prefix.size()), " \t"), buffer);
  }

  ds::Option<std::string_view> GitHead::read(std::string_view root) noexcept {
    const auto direct = GitFiles::join(root, ".git/HEAD", path_.viewMut());
    if (!direct) {
      return ds::none;
    }

    if (const auto contents = readRegularFile(*direct, head_.viewMut())) {
      return parse(*contents);
    }

    ds::Array<char, PATH_MAX> resolved;
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
      contents = trimText(contents.substr(reference.size()), " ");
      return contents.starts_with(branch) ? contents.substr(branch.size()) : contents;
    }

    constexpr std::size_t abbreviated_hash_length = 8;

    return contents.substr(0, abbreviated_hash_length);
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

      const auto scope = listing.substr(0, scope_end);

      listing.remove_prefix(scope_end + 1);
      const auto entry_end = listing.find('\0');
      if (entry_end == std::string_view::npos) {
        return ds::none;
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
  HardenedGit<Memory>::HardenedGit(Memory& memory, std::string_view root)
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
  ds::Option<bool> HardenedGit<Memory>::overrideFilters(int status, std::string_view listing) {
    const auto facts = status > 1 ? ds::none : GitRepositoryFacts::parse(listing);
    if (!facts) {
      return ds::none;
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto suffix : {".clean=", ".smudge=", ".process="}) {
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

    complete.reserve(git_observation_options.size() + 2 * overrides_.size() + arguments.size());
    complete.extend({git_observation_options.begin(), git_observation_options.end()});
    for (const auto& override : overrides_) {
      complete.push("-c");
      complete.push(override);
    }

    complete.extend({arguments.begin(), arguments.end()});
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

        return branch ? ds::Option{Found{directory.size(), *branch}} : ds::none;
      }

      while (directory.size() > 1 && directory.ends_with('/')) {
        directory.remove_suffix(1);
      }

      const auto separator = directory.rfind('/');
      if (directory.size() <= 1 || separator == std::string_view::npos) {
        return ds::none;
      }

      directory = directory.substr(0, std::max<std::size_t>(1, separator));
    }

    return ds::none;
  }

  ds::Option<std::string_view> LinkedWorktree::mainBranch(std::string_view root) noexcept {
    ds::Array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory.viewMut());
    if (!directory) {
      return ds::none;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_.viewMut());
    ds::Array<char, PATH_MAX> contents;
    const auto common = common_path ? readRegularFile(*common_path, contents.viewMut()) : ds::none;
    ds::Array<char, PATH_MAX> resolved;
    const auto common_directory = common ? GitFiles::resolve(*directory, trimText(*common, " \t\r\n"), resolved.viewMut()) : ds::none;
    const auto head_path = common_directory ? GitFiles::join(*common_directory, "HEAD", path_.viewMut()) : ds::none;
    const auto head = head_path ? readRegularFile(*head_path, head_.viewMut()) : ds::none;
    if (!head) {
      return ds::none;
    }

    const auto text = trimText(*head, " \r\n");
    constexpr std::string_view prefix = "ref: refs/heads/";

    return text.starts_with(prefix) && text.size() > prefix.size() ? ds::Option{text.substr(prefix.size())} : ds::none;
  }

  ds::Option<std::string_view> LinkedWorktree::linkedBranch(std::string_view root) noexcept {
    ds::Array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory.viewMut());
    if (!directory) {
      return ds::none;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_.viewMut());
    ds::Array<char, PATH_MAX> common;
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
