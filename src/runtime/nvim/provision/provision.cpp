module telar.runtime.nvim.provision;

import std;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace telar::runtime {

  namespace {

#include "nvim_provision.inc"

    // What names telar's configuration on disk: another configuration is another directory, so
    // a runtime never starts Neovim on the files of an older one.
    constexpr std::uint64_t digest(std::string_view one, std::string_view other) noexcept {
      constexpr std::uint64_t offset = 0xcbf29ce484222325ULL;
      constexpr std::uint64_t prime = 0x100000001b3ULL;
      std::uint64_t hash = offset;

      for (const auto text : {one, other}) {
        for (const auto character : text) {
          hash = (hash ^ static_cast<unsigned char>(character)) * prime;
        }
      }

      return hash;
    }

    constexpr std::uint64_t own_digest = digest(own_init, own_lock);

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

    bool directory(const ds::String<ConcurrentMemory>& path) noexcept {
      struct stat status{};

      return ::stat(path.data(), &status) == 0 && S_ISDIR(status.st_mode);
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
    if (host.data_home.empty() || host.config_home.empty()) {
      return;
    }

    ds::String<ConcurrentMemory> users{memory_, host.config_home};

    users.append("/nvim");
    if (directory(users)) {
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
      keep(root, "lazy-lock.json", own_lock);
      init_.assign(root.view());
      init_.append("/init.lua");
    } catch (const SystemError&) {
      // Neovim starts on its defaults when telar's configuration cannot be written.
      init_.clear();
    }
  }

  std::string_view NvimProvision::program() const noexcept {
    return program_.view();
  }

  std::string_view NvimProvision::ownInit() const noexcept {
    return init_.view();
  }

  std::span<const EnvironmentEntry> nvimEnvironment(std::span<const std::string_view> arguments) noexcept {
    static constexpr ds::Array<EnvironmentEntry, 1> own{EnvironmentEntry{.name = "NVIM_APPNAME", .value = NvimProvision::own_name}};

    if (!std::ranges::contains(arguments, std::string_view{"-u"})) {
      return {};
    }

    return own.view();
  }

}
