#pragma once

#include "telar_platform/read_file.hpp"
#include "telar_platform/resolve_relative_path.hpp"
#include "telar_platform/write_private_file.hpp"
#include <optional>

namespace telar::runtime::cli::integration {

template <Allocator Memory>
String<Memory> joinPath(Memory &memory, std::string_view directory, std::string_view name) {
  String<Memory> path{directory, AllocatorRef<char, Memory>{memory}};
  path += '/';
  path += name;
  if (path.size() >= PATH_MAX || path.contains('\0')) {
    throw std::length_error{"Invalid integration file path"};
  }

  return path;
}

template <Allocator Memory>
std::optional<String<Memory>> read(Memory &memory, const String<Memory> &path, std::size_t maximum_bytes) {
  FileDescriptor file{::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)};
  if (!file) {
    if (errno == ENOENT) {
      return std::nullopt;
    }

    throw SystemError{"Read integration file"};
  }

  return readFileContents(memory, file.get(), maximum_bytes - 1);
}

template <Allocator Memory>
void createParents(const String<Memory> &path) {
  std::array<char, PATH_MAX> directory;
  if (path.size() >= directory.size() || path.contains('\0')) {
    throw std::length_error{"Invalid integration file path"};
  }

  std::copy(path.begin(), path.end(), directory.begin());
  directory[path.size()] = '\0';
  for (std::size_t index = 1; index < path.size(); ++index) {
    if (directory[index] == '/') {
      directory[index] = '\0';
      if (::mkdir(directory.data(), 0777) != 0 && errno != EEXIST) {
        throw SystemError{"Create integration directory"};
      }

      directory[index] = '/';
    }
  }
}

template <Allocator Memory>
void write(Memory &memory, const String<Memory> &path, std::string_view source, bool preserve_settings) {
  String<Memory> target{path, AllocatorRef<char, Memory>{memory}};
  std::optional<mode_t> permissions;
  if (preserve_settings) {
    std::array<char, PATH_MAX> resolved;
    if (::realpath(path.c_str(), resolved.data()) != nullptr) {
      target = resolved.data();
    }

    struct stat state{};
    if (::stat(target.c_str(), &state) == 0) {
      permissions = state.st_mode & 07777;
    }
  }

  resolveAbsolutePath(target);
  createParents(target);
  const auto separator = target.rfind('/');
  String<Memory> parent{target.data(), separator == 0 ? 1 : separator, AllocatorRef<char, Memory>{memory}};
  FileDescriptor directory{::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!directory) {
    throw SystemError{"Open integration directory"};
  }

  const auto name = std::string_view{target}.substr(separator + 1);
  if (const int error = writePrivateFile(directory.get(), name, {reinterpret_cast<const unsigned char *>(source.data()), source.size()}, PrivateFileMode::replace)) {
    throw SystemError{"Publish integration file", error};
  }
  if (permissions && ::chmod(target.c_str(), *permissions) != 0) {
    throw SystemError{"Restore integration settings permissions"};
  }
}

}
