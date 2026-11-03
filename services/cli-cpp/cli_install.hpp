#pragma once

#include "command_error.hpp"

#include "telar_platform/executable_path.hpp"
#include <array>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace telar::runtime::cli {

inline CommandError fileError(int code) {
  return CommandError{code == ENOENT ? "FileNotFound" : code == EACCES || code == EPERM ? "AccessDenied"
                                                    : code == ENOTDIR                   ? "NotDir"
                                                    : code == EINVAL                    ? "NotLink"
                                                    : code == ENAMETOOLONG              ? "NameTooLong"
                                                                                        : "Unexpected"};
}

struct CliInstallOptions {
  std::string_view action;
  std::optional<std::string_view> directory;
};

inline CliInstallOptions parseCliInstall(std::span<char *const> args) {
  if (args.empty()) {
    throw std::invalid_argument{"MissingCliAction"};
  }

  const std::string_view action = args[0];
  if (action != "install" && action != "uninstall" && action != "status") {
    throw std::invalid_argument{"UnknownCliAction"};
  }

  std::optional<std::string_view> directory;
  for (std::size_t index = 1; index < args.size(); index += 2) {
    if (std::string_view{args[index]} != "--dir") {
      throw std::invalid_argument{"UnknownCliOption"};
    }

    if (directory) {
      throw std::invalid_argument{"DuplicateDirOption"};
    }

    if (index + 1 == args.size()) {
      throw std::invalid_argument{"MissingDirPath"};
    }

    directory = args[index + 1];
  }

  return {.action = action, .directory = directory};
}

inline int runCliInstall(std::span<char *const> args) {
  const auto options = parseCliInstall(args);
  const auto action = options.action;
  const auto directory = options.directory;

  const auto path = std::string{directory.value_or("/usr/local/bin")} + "/telar";
  const ExecutablePath target;
  std::array<char, PATH_MAX> buffer;
  const auto count = ::readlink(path.c_str(), buffer.data(), buffer.size());
  if (count < 0 && errno != ENOENT) {
    if (errno == EINVAL && action != "status") {
      std::fprintf(stderr, "telar cli: %s exists and is not a symlink; refusing to replace it\n", path.c_str());
    }

    throw fileError(errno);
  }

  if (action == "status") {
    if (count < 0) {
      std::printf("telar cli: %s is not installed\n", path.c_str());
    } else {
      std::printf("telar cli: %s -> %.*s\n", path.c_str(), static_cast<int>(count), buffer.data());
    }

    return 0;
  }

  if (count >= 0 && ::unlink(path.c_str()) != 0) {
    throw fileError(errno);
  }

  if (action == "install") {
    if (::symlink(target.c_str(), path.c_str()) != 0) {
      const auto failure = errno;
      if (failure == EACCES || failure == EPERM) {
        std::fprintf(stderr, "telar cli: cannot write %s; rerun with sudo or pass --dir ~/.local/bin\n", path.c_str());
      }

      throw fileError(failure);
    }

    std::printf("telar cli: installed %s -> %s\n", path.c_str(), target.c_str());
  } else {
    std::printf("telar cli: removed %s\n", path.c_str());
  }

  return 0;
}

}
