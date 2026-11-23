module telar.gui.foundation.system;

import std;
import telar.sys.posix;

import telar.base.ds;
import telar.base.memory.allocators;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;

namespace telar::gui::inline foundation::inline system {

  FileTreeFile::FileTreeFile(Memory& memory, std::string_view name)
      : path(memory, name),
        content(memory) {}

  namespace {

    struct Walk {
      Memory& memory;
      FileTreeLimits limits;
      ds::Vec<FileTreeFile, Memory>& files;
      std::size_t bytes = 0;
    };

    // Reads what `directory` holds, below `prefix`; false once a limit is passed.
    bool walk(Walk& state, int directory, ds::String<Memory>& prefix, std::size_t depth) { // NOLINT(misc-no-recursion): a tree is read as deep as its limits say, and no deeper
      ds::Vec<ds::String<Memory>, Memory> names{state.memory};

      {
        runtime::DirectoryStream entries{directory};

        for (const auto* entry = entries.next(); entry != nullptr; entry = entries.next()) {
          // What starts with a dot, "." and ".." among them, is the machine's own.
          if (entry->d_name[0] != '.') {
            names.emplace(state.memory, std::string_view{std::data(entry->d_name)});
          }
        }
      }

      const auto base = prefix.size();

      for (const auto& name : names) {
        prefix.truncate(base);
        prefix.append(name.view());
        struct stat status{};
        // A link is what it points at; one that points nowhere is left out.
        if (::fstatat(directory, name.data(), &status, 0) != 0) {
          continue;
        }

        if (S_ISDIR(status.st_mode)) {
          if (depth + 1 >= state.limits.depth) {
            return false;
          }

          const runtime::FileDescriptor child{::openat(directory, name.data(), runtime::combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
          if (!child) {
            throw runtime::SystemError{"Open a directory of the editor's configuration"};
          }

          prefix.append("/");
          if (!walk(state, child.get(), prefix, depth + 1)) {
            return false;
          }

          continue;
        }

        if (!S_ISREG(status.st_mode)) {
          continue;
        }

        if (state.files.size() >= state.limits.files || std::cmp_greater(status.st_size, state.limits.bytes - state.bytes)) {
          return false;
        }

        const runtime::FileDescriptor file{::openat(directory, name.data(), runtime::combineFlags(O_RDONLY, O_CLOEXEC, O_NONBLOCK, O_NOCTTY))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
        if (!file) {
          throw runtime::SystemError{"Open a file of the editor's configuration"};
        }

        const auto size = runtime::boundedFileSize(file.get(), state.limits.bytes - state.bytes);
        auto& read = state.files.emplace(state.memory, prefix.view());

        read.content.resize(size);

        const auto bytes = read.content.viewMut();

        runtime::readFileBytes(file.get(), std::span<char>{reinterpret_cast<char*>(bytes.data()), bytes.size()}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast,clang-diagnostic-unsafe-buffer-usage-in-container): the file's bytes, read as the characters read takes, and as many as the span they come from holds
        state.bytes += size;
      }

      prefix.truncate(base);
      return true;
    }

  }

  FileTreeRead readFileTree(Memory& memory, std::string_view directory, FileTreeLimits limits, ds::Vec<FileTreeFile, Memory>& files) {
    files.clear();

    const ds::String<Memory> path{memory, directory};
    const runtime::FileDescriptor root{::open(path.data(), runtime::combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!root) {
      if (sys::lastError() == ENOENT) {
        return FileTreeRead::absent;
      }

      throw runtime::SystemError{"Open the editor's configuration directory"};
    }

    Walk state{.memory = memory, .limits = limits, .files = files};
    ds::String<Memory> prefix{memory};

    if (!walk(state, root.get(), prefix, 0)) {
      files.clear();
      return FileTreeRead::too_large;
    }

    return FileTreeRead::read;
  }

}
