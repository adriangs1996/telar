module telar.runtime.nvim.provision;

import std;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.platform.process;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.wire.nvim;
import telar.base.memory.allocators;

namespace telar::runtime {

  namespace {

#include "nvim_provision.inc"

    // What names telar's configuration on disk: another configuration is another directory, so
    // a runtime never starts Neovim on the files of an older one.
    constexpr std::uint64_t digest(std::string_view text) noexcept {
      constexpr std::uint64_t offset = 0xcbf29ce484222325ULL;
      constexpr std::uint64_t prime = 0x100000001b3ULL;
      std::uint64_t hash = offset;

      for (const auto character : text) {
        hash = (hash ^ static_cast<unsigned char>(character)) * prime;
      }

      return hash;
    }

    constexpr std::uint64_t own_digest = digest(own_init);

    bool executable(const ds::String<ConcurrentMemory>& path) noexcept {
      struct stat status{};

      return ::stat(path.data(), &status) == 0 && S_ISREG(status.st_mode) && ::access(path.data(), X_OK) == 0;
    }

    // Whether this host runs the Neovim telar brings: its releases for Linux are built for
    // glibc, and a host without glibc's loader, as one of musl, cannot start them.
    bool runsReleases() noexcept {
#if defined(__linux__) && defined(__x86_64__)
      return ::access("/lib64/ld-linux-x86-64.so.2", F_OK) == 0;
#elif defined(__linux__) && defined(__aarch64__)
      return ::access("/lib/ld-linux-aarch64.so.1", F_OK) == 0;
#else
      return true;
#endif
    }

    // Writes a file of telar's configuration unless it is there: its directory is named by what
    // it holds.
    void keep(const ds::String<ConcurrentMemory>& root, std::string_view name, std::string_view content) {
      FileDescriptor opened{::open(root.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!opened) {
        throw SystemError{"Open the editor's configuration directory"};
      }

      ds::Array<char, NAME_MAX + 1> terminated{};

      std::ranges::copy(name, terminated.viewMut().begin());
      struct stat status{};
      if (::fstatat(opened.get(), terminated.data(), &status, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(status.st_mode) && std::cmp_equal(status.st_size, content.size())) {
        return;
      }

      if (const int failure = writePrivateFile(opened.get(), name, byteView(content), PrivateFileMode::replace); failure != 0) {
        throw SystemError{"Write the editor's configuration", failure};
      }
    }

  }

  std::string_view pinnedNeovim() noexcept {
    return pinned_version;
  }

  NvimProvision::NvimProvision(ConcurrentMemory& memory)
      : memory_(memory),
        program_(memory),
        init_(memory) {}

  void NvimProvision::resolve(const NvimHost& host) {
    program_.assign(host.configured);
    if (!host.configured.starts_with('/') || !executable(program_)) {
      program_.assign(host.data_home);
      program_.append("/telar/nvim/");
      program_.append(pinned_version);
      program_.append("/bin/nvim");
      const bool brought = runsReleases();

      if (!brought || host.data_home.empty() || !executable(program_)) {
        program_.assign(host.shipped);
        if (!brought || !host.shipped.starts_with('/') || !executable(program_)) {
          program_.assign("nvim");
        }
      }
    }

    init_.clear();
    if (host.data_home.empty()) {
      return;
    }

    constexpr std::size_t digest_digits = 16;
    ds::Array<char, digest_digits> digits{};

    std::format_to_n(digits.dataMut(), digits.size(), "{:016x}", own_digest);
    try {
      ds::String<ConcurrentMemory> root{memory_, host.data_home};

      root.append("/telar/nvim-config/");
      root.append(std::string_view{digits.data(), digits.size()});
      createPrivateDirectory(root.view());
      keep(root, "init.lua", own_init);
      init_.assign(root.view());
      init_.append("/init.lua");
    } catch (const SystemError&) {
      // Neovim starts on no configuration at all when telar's cannot be written.
      init_.clear();
    }
  }

  std::string_view NvimProvision::program() const noexcept {
    return program_.view();
  }

  std::string_view NvimProvision::ownInit() const noexcept {
    return init_.view();
  }

  namespace {

    // The parsers and queries telar's package brings the editor: share/telar/editor, beside the
    // directory of its programs, resolved; none when this telar has none.
    struct EditorRuntime {
      ds::Array<char, PATH_MAX> path{};
      bool found = false;
    };

    EditorRuntime findEditorRuntime() noexcept {
      constexpr std::string_view relative = "../share/telar/editor";
      EditorRuntime runtime;

      try {
        const ExecutablePath self;
        const std::string_view own = self.view();
        // Up to the last slash and with it; nothing of a path without one.
        const std::string_view directory{own.data(), own.rfind('/') + 1};
        ds::Array<char, PATH_MAX> joined{};
        struct stat status{};

        if (directory.size() + relative.size() >= joined.size()) {
          return runtime;
        }

        std::ranges::copy(relative, std::ranges::copy(directory, joined.dataMut()).out);
        runtime.found = ::stat(joined.data(), &status) == 0 && S_ISDIR(status.st_mode) && ::realpath(joined.data(), runtime.path.dataMut()) != nullptr;
      } catch (const SystemError&) {
        runtime.found = false;
      }

      return runtime;
    }

  }

  std::span<const EnvironmentEntry> nvimEnvironment(std::span<const std::string_view> arguments) noexcept {
    // Where this runtime's programs are does not change while it runs.
    static const EditorRuntime runtime = findEditorRuntime();
    static const ds::Array<EnvironmentEntry, 2> own{
        EnvironmentEntry{.name = "NVIM_APPNAME", .value = NvimProvision::own_name},
        EnvironmentEntry{.name = "TELAR_EDITOR_RUNTIME", .value = runtime.found ? std::string_view{runtime.path.data()} : std::string_view{}},
    };

    if (!std::ranges::contains(arguments, std::string_view{"-u"})) {
      return {};
    }

    return own.view().first(runtime.found ? 2 : 1);
  }

  namespace {

    // The deepest a configuration's path goes, and the deepest the directory is walked to prune.
    constexpr std::size_t max_configuration_depth = 32;

    // A path a configuration may name: relative, below its directory, of printable names that do
    // not start with a dot.
    bool configurationPath(std::string_view path) noexcept {
      if (path.empty() || path.size() >= PATH_MAX || path.front() == '/' || path.back() == '/') {
        return false;
      }

      std::size_t depth = 0;

      for (const auto part : std::views::split(path, '/')) {
        const std::string_view name{part};
        const bool printable = std::ranges::none_of(name, [](char character) {
          constexpr unsigned char first_printable = 0x20;
          constexpr unsigned char delete_character = 0x7f;
          const auto byte = static_cast<unsigned char>(character);

          return byte < first_printable || byte == delete_character || byte == '\\';
        });

        if (name.empty() || name.size() > NAME_MAX || name.front() == '.' || !printable || ++depth > max_configuration_depth) {
          return false;
        }
      }

      return true;
    }

    FileDescriptor openDirectoryAt(int parent, const char* name) noexcept {
      return FileDescriptor{::openat(parent, name, combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    }

    // Removes `name` in `parent` and everything below it, without following a link.
    void removeTree(int parent, const char* name) { // NOLINT(misc-no-recursion): it goes as deep as the directories on disk, which the length of a path bounds
      if (::unlinkat(parent, name, 0) == 0) {
        return;
      }

      const auto directory = openDirectoryAt(parent, name);
      if (!directory) {
        throw SystemError{"Open a directory of the editor's configuration"};
      }

      DirectoryStream entries{directory.get()};
      ds::Array<char, NAME_MAX + 1> child{};

      for (const auto* entry = entries.next(); entry != nullptr; entry = entries.next()) {
        const std::string_view child_name{std::data(entry->d_name)};
        if (child_name == "." || child_name == "..") {
          continue;
        }

        std::ranges::fill(child.viewMut(), '\0');
        std::ranges::copy(child_name, child.viewMut().begin());
        removeTree(directory.get(), child.data());
      }

      if (::unlinkat(parent, name, AT_REMOVEDIR) != 0) {
        throw SystemError{"Remove a directory of the editor's configuration"};
      }
    }

    // The directory `path` names below `root`, made where it is missing; a file in its place goes.
    FileDescriptor openPath(int root, std::string_view path, NvimConfigurationChange& change) {
      FileDescriptor current;
      ds::Array<char, NAME_MAX + 1> name{};

      for (const auto part : std::views::split(path, '/')) {
        const std::string_view component{part};
        const int parent = current ? current.get() : root;

        std::ranges::fill(name.viewMut(), '\0');
        std::ranges::copy(component, name.viewMut().begin());
        auto next = openDirectoryAt(parent, name.data());
        if (!next && (sys::lastError() == ENOTDIR || sys::lastError() == ELOOP)) {
          if (::unlinkat(parent, name.data(), 0) != 0) {
            throw SystemError{"Remove a file of the editor's configuration"};
          }

          ++change.removed;
        }

        if (!next && ::mkdirat(parent, name.data(), S_IRWXU) != 0 && sys::lastError() != EEXIST) {
          throw SystemError{"Create a directory of the editor's configuration"};
        }

        if (!next) {
          next = openDirectoryAt(parent, name.data());
        }

        if (!next) {
          throw SystemError{"Open a directory of the editor's configuration"};
        }

        current = std::move(next);
      }

      return current;
    }

    // Whether `directory` already holds `name` with exactly `content`.
    bool holds(ConcurrentMemory& memory, int directory, std::string_view name, std::span<const Byte> content) {
      ds::Vec<unsigned char, ConcurrentMemory> present{memory};

      try {
        if (!readPrivateFile(directory, name, present, content.size())) {
          return false;
        }
      } catch (const SystemError&) {
        // Larger than what replaces it, a directory, or a link: it is not the same file.
        return false;
      }

      return std::ranges::equal(present.view(), content);
    }

    struct Pruning {
      ConcurrentMemory& memory;
      // The paths the client sent, sorted.
      std::span<const std::string_view> kept;
      NvimConfigurationChange& change;
    };

    // Removes what is below `directory`, at `prefix`, that the client did not send. False when
    // the directory is left holding nothing.
    bool prune(Pruning& pruning, int directory, ds::String<ConcurrentMemory>& prefix, std::size_t depth) { // NOLINT(misc-no-recursion): a configuration is max_configuration_depth directories deep at most
      ds::Vec<ds::String<ConcurrentMemory>, ConcurrentMemory> names{pruning.memory};

      {
        DirectoryStream entries{directory};

        for (const auto* entry = entries.next(); entry != nullptr; entry = entries.next()) {
          names.emplace(pruning.memory, std::string_view{std::data(entry->d_name)});
        }
      }

      bool holding = false;
      const auto base = prefix.size();

      for (const auto& name : names) {
        if (name.view() == "." || name.view() == "..") {
          continue;
        }

        // What starts with a dot is the machine's own, as are the temporary files of a write.
        if (name.view().starts_with('.')) {
          holding = true;
          continue;
        }

        prefix.truncate(base);
        prefix.append(name.view());
        struct stat state{};
        if (::fstatat(directory, name.data(), &state, AT_SYMLINK_NOFOLLOW) != 0) {
          continue;
        }

        if (S_ISDIR(state.st_mode)) {
          if (depth >= max_configuration_depth) {
            holding = true;
            continue;
          }

          // A directory a kept file is below holds it; one left empty goes.
          const auto child = openDirectoryAt(directory, name.data());

          prefix.append("/");
          if ((child && prune(pruning, child.get(), prefix, depth + 1)) || ::unlinkat(directory, name.data(), AT_REMOVEDIR) != 0) {
            holding = true;
          }

          continue;
        }

        if (std::ranges::binary_search(pruning.kept, prefix.view())) {
          holding = true;
          continue;
        }

        if (::unlinkat(directory, name.data(), 0) != 0) {
          throw SystemError{"Remove a file of the editor's configuration"};
        }

        ++pruning.change.removed;
      }

      prefix.truncate(base);
      return holding;
    }

  }

  NvimConfigurationChange mirrorNvimConfiguration(ConcurrentMemory& memory, std::string_view directory, std::span<const NvimConfigurationFile> files) {
    ds::Vec<std::string_view, ConcurrentMemory> kept{memory};

    kept.reserve(files.size());
    for (const auto& file : files) {
      if (!configurationPath(file.path)) {
        throw std::invalid_argument{"A path of the editor's configuration is not a plain relative path"};
      }

      kept.push(file.path);
    }

    std::ranges::sort(kept.viewMut());
    if (std::ranges::adjacent_find(kept.view()) != kept.view().end()) {
      throw std::invalid_argument{"The editor's configuration names a path twice"};
    }

    createPrivateDirectory(directory);
    const ds::String<ConcurrentMemory> path{memory, directory};
    const FileDescriptor root{::open(path.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!root) {
      throw SystemError{"Open the editor's configuration directory"};
    }

    NvimConfigurationChange change;
    ds::Array<char, NAME_MAX + 1> name{};

    for (const auto& file : files) {
      const auto slash = file.path.rfind('/');
      const auto parent = slash == std::string_view::npos ? FileDescriptor{} : openPath(root.get(), file.path.substr(0, slash), change);
      const int holder = parent ? parent.get() : root.get();
      const auto base = slash == std::string_view::npos ? file.path : file.path.substr(slash + 1);

      if (holds(memory, holder, base, file.content)) {
        continue;
      }

      std::ranges::fill(name.viewMut(), '\0');
      std::ranges::copy(base, name.viewMut().begin());
      struct stat state{};
      // A directory where the client has a file goes, with what it holds.
      if (::fstatat(holder, name.data(), &state, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(state.st_mode)) {
        removeTree(holder, name.data());
        ++change.removed;
      }

      if (const int failure = writePrivateFile(holder, base, file.content, PrivateFileMode::replace); failure != 0) {
        throw SystemError{"Write a file of the editor's configuration", failure};
      }

      ++change.written;
    }

    ds::String<ConcurrentMemory> prefix{memory};
    Pruning pruning{.memory = memory, .kept = kept.view(), .change = change};

    static_cast<void>(prune(pruning, root.get(), prefix, 0));
    return change;
  }

}
