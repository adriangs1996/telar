#pragma once

#include "../platform/git_repository.hpp"
#include "index_storage.hpp"
#include "telar_platform/trace.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unordered_set>

namespace telar::runtime {

template <Allocator Memory>
class PathIndexBuilder {
public:
  explicit PathIndexBuilder(Memory &memory, PathIndexStorage<Memory> &storage)
      : memory_(memory),
        storage_(storage) {}

  void build(const char *root) noexcept {
    TELAR_TRACE("paths.build");
    try {
      FileDescriptor directory{::open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!directory) {
        storage_.failure = PathBuildFailure::unreadable;
      } else {
        if (insideGit(root)) {
          tracked(root);
        }
        if (storage_.count == 0 && !storage_.cancelled.load(std::memory_order_relaxed)) {
          walk(directory.get());
        }
      }
    } catch (const std::bad_alloc &) {
      storage_.failure = PathBuildFailure::allocation;
    } catch (...) {
      storage_.truncated = true;
    }

    storage_.finish();
  }

private:
  using Directories = std::unordered_set<std::string_view, std::hash<std::string_view>, std::equal_to<std::string_view>, AllocatorRef<std::string_view, Memory>>;

  static bool acceptable(std::string_view relative) noexcept {
    try {
      DisplayText16<1024, false>::validate(relative);
      return !relative.empty();
    } catch (const EncodingError &) {
      return false;
    }
  }

  static bool insideGit(std::string_view path) noexcept {
    std::array<char, 4102> marker;
    while (!path.empty() && path.ends_with('/')) {
      path.remove_suffix(1);
    }
    for (;;) {
      if (path.size() + 6 > marker.size()) {
        return false;
      }

      std::copy(path.begin(), path.end(), marker.begin());
      std::memcpy(marker.data() + path.size(), "/.git", 6);
      if (::access(marker.data(), F_OK) == 0) {
        return true;
      }
      const auto parent = path.rfind('/');
      if (parent == std::string_view::npos) {
        return false;
      }
      path = path.substr(0, parent);
    }
  }

  bool appendTracked(std::string_view relative, Directories &directories) {
    if (!acceptable(relative)) {
      return true;
    }

    for (auto separator = relative.find('/'); separator != std::string_view::npos; separator = relative.find('/', separator + 1)) {
      const auto directory = relative.substr(0, separator + 1);
      if (directories.contains(directory)) {
        continue;
      }

      if (!storage_.append(directory, PathKind::directory)) {
        return false;
      }
      directories.insert(storage_.path(storage_.entry(storage_.count - 1)));
    }

    return storage_.append(relative, PathKind::file);
  }

  void tracked(const char *root) {
    try {
      const auto configuration_deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
      GitRepository git{memory_, root, configuration_deadline, storage_.cancelled};
      Directories directories{0, std::hash<std::string_view>{}, std::equal_to<std::string_view>{}, AllocatorRef<std::string_view, Memory>{memory_}};
      std::array<char, 1024> relative;
      std::size_t length = 0;
      bool oversized = false;

      git.stream({"ls-files", "-z", "--cached", "--others", "--exclude-standard"}, [&](std::span<const Byte> bytes) {
        for (const auto byte : bytes) {
          if (storage_.cancelled.load(std::memory_order_relaxed)) {
            return false;
          }
          if (byte == 0) {
            if (!oversized && !appendTracked({relative.data(), length}, directories)) {
              return false;
            }
            length = 0;
            oversized = false;
          } else if (length < relative.size()) {
            relative[length++] = static_cast<char>(byte);
          } else {
            oversized = true;
          }
        }

        return true;
      });
    } catch (const SystemError &) {
    } catch (const RequestError &) {
    }
  }

  static FileDescriptor openRelative(int root, std::string_view relative) {
    FileDescriptor current{::fcntl(root, F_DUPFD_CLOEXEC, 3)};
    while (current && !relative.empty()) {
      const auto separator = relative.find('/');
      const auto name = relative.substr(0, separator);
      std::array<char, NAME_MAX + 1> component{};
      if (name.empty() || name.size() > NAME_MAX || name == "..") {
        return FileDescriptor{};
      }
      std::copy(name.begin(), name.end(), component.begin());
      current.reset(::openat(current.get(), component.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
      if (separator == std::string_view::npos) {
        break;
      }
      relative.remove_prefix(separator + 1);
    }

    return current;
  }

  void walk(int root) {
    list(root, {});
    for (std::size_t index = 0; index < storage_.count; ++index) {
      if (storage_.cancelled.load(std::memory_order_relaxed) || storage_.truncated) {
        return;
      }
      const auto &entry = storage_.entry(index);
      if (entry.kind != PathKind::directory) {
        continue;
      }

      const auto relative = storage_.path(entry);
      auto child = openRelative(root, relative);
      if (child) {
        list(child.get(), relative);
      }
    }
  }

  void list(int directory, std::string_view prefix) {
    FileDescriptor copy{::fcntl(directory, F_DUPFD_CLOEXEC, 3)};
    std::unique_ptr<DIR, decltype(&::closedir)> stream{::fdopendir(copy.get()), ::closedir};
    if (!stream) {
      return;
    }
    copy.release();
    while (const auto *entry = ::readdir(stream.get())) {
      if (storage_.cancelled.load(std::memory_order_relaxed)) {
        return;
      }
      const std::string_view name{entry->d_name};
      if (name.starts_with('.')) {
        continue;
      }

      struct stat status{};
      if (::fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        continue;
      }
      const bool child_directory = S_ISDIR(status.st_mode);
      if (child_directory && (name == "node_modules" || name == "zig-out" || name == "target" || name == "__pycache__")) {
        continue;
      }

      std::array<char, 1024> relative;
      const auto length = prefix.size() + name.size() + child_directory;
      if (length > relative.size()) {
        continue;
      }
      std::copy(prefix.begin(), prefix.end(), relative.begin());
      std::copy(name.begin(), name.end(), relative.begin() + prefix.size());
      if (child_directory) {
        relative[length - 1] = '/';
      }

      const std::string_view value{relative.data(), length};
      if (acceptable(value) && !storage_.append(value, child_directory ? PathKind::directory : PathKind::file)) {
        return;
      }
    }
  }

  Memory &memory_;
  PathIndexStorage<Memory> &storage_;
};

}
