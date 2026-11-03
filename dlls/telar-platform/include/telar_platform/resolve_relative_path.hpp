#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_platform/error.hpp"
#include <array>
#include <limits.h>
#include <string_view>
#include <unistd.h>

namespace telar::runtime {

template <Allocator Memory>
void resolveRelativePath(String<Memory> &path, std::string_view directory) {
  if (path.empty() || path.front() == '/') {
    return;
  }

  String<Memory> combined{directory, path.get_allocator()};
  combined += '/';
  combined += path;
  path.clear();
  std::string_view remaining{combined};
  while (!remaining.empty()) {
    const auto end = remaining.find('/');
    const auto component = remaining.substr(0, end);
    if (component == "..") {
      const auto slash = path.rfind('/');
      path.resize(slash == String<Memory>::npos ? 0 : slash);
    } else if (!component.empty() && component != ".") {
      path += '/';
      path += component;
    }
    if (end == std::string_view::npos) {
      break;
    }

    remaining.remove_prefix(end + 1);
  }

  if (path.empty()) {
    path = "/";
  }
}

template <Allocator Memory>
void resolveAbsolutePath(String<Memory> &path) {
  if (path.starts_with('/')) {
    return;
  }
  std::array<char, PATH_MAX> directory;
  if (::getcwd(directory.data(), directory.size()) == nullptr) {
    throw SystemError{"Resolve working directory"};
  }
  resolveRelativePath(path, directory.data());
}

}
