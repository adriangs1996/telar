#pragma once

#include "telar_platform/random_bytes.hpp"
#include "cli_install.hpp"
#include "machine_options.hpp"
#include "telar_client/machines/profile_codec.hpp"
#include "telar_platform/private_directory.hpp"
#include "telar_platform/private_file.hpp"
#include "telar_platform/process_environment.hpp"
#include "telar_platform/write_private_file.hpp"
#include <filesystem>
#include <sys/file.h>

namespace telar::runtime::cli::machine {

using namespace machines;

inline std::string profilesPath() {
  const ProcessEnvironment environment;
  const auto config = environment.lookup("XDG_CONFIG_HOME");
  if (!config.empty()) {
    return std::string{config} + "/telar/machines.json";
  }

  const auto home = environment.lookup("HOME");
  if (home.empty()) {
    throw CommandError{"HomeUnavailable"};
  }

  return std::string{home} + "/.config/telar/machines.json";
}

template <Allocator Memory>
MachineProfiles load(Memory &memory, const std::string &path) {
  Vector<unsigned char, Memory> source{AllocatorRef<unsigned char, Memory>{memory}};
  try {
    if (!readPrivateFile(AT_FDCWD, path, source, MachineLimits::file_bytes)) {
      return {};
    }
  } catch (const SystemError &error) {
    if (error.code() == EACCES || error.code() == ELOOP || error.code() == EISDIR) {
      throw CommandError{"InsecureFile"};
    }

    if (error.code() == EFBIG) {
      throw CommandError{"StreamTooLong"};
    }

    throw fileError(error.code());
  }

  return MachineProfileCodec::parse(memory, {reinterpret_cast<const char *>(source.data()), source.size()});
}

inline std::string localLabel(const MachineProfiles &profiles) {
  if (const auto label = profiles.localLabel()) {
    return std::string{*label};
  }

  std::array<char, 256> name{};
  return ::gethostname(name.data(), name.size()) == 0 ? std::string{name.data()} : "localhost";
}

inline void requireNotLocal(const MachineProfiles &profiles, std::string_view label) {
  if (label == localLabel(profiles)) {
    throw MachineFailure{MachineError::duplicate_label};
  }
}

struct Random {
  void fill(std::span<std::uint8_t> bytes) {
    randomBytes(bytes.data(), bytes.size());
  }
};

inline MachineProfile newProfile(const MachineProfiles &profiles, const MachineOptions &options) {
  requireNotLocal(profiles, options.label);
  Random random;
  return MachineProfile::create(MachineId::generate(random), {
                                                                 .label = options.label,
                                                                 .destination = options.value,
                                                                 .color = options.color,
                                                                 .enabled = !options.disabled,
                                                             });
}

inline void change(MachineProfiles &profiles, const MachineOptions &options) {
  switch (options.action) {
  case MachineOptions::Action::add:
    profiles.add(newProfile(profiles, options));
    break;
  case MachineOptions::Action::remove:
    profiles.remove(options.label);
    break;
  case MachineOptions::Action::rename:
    requireNotLocal(profiles, options.value);
    profiles.rename(options.label, options.value);
    break;
  case MachineOptions::Action::enable:
  case MachineOptions::Action::disable:
    profiles.enable(options.label, options.action == MachineOptions::Action::enable);
    break;
  default:
    throw std::logic_error{"Expected a machine profile edit"};
  }
}

template <Allocator Memory, typename Edit>
void update(Memory &memory, const std::string &path, Edit edit) {
  const auto absolute = std::filesystem::absolute(path);
  createPrivateDirectory(absolute.parent_path().string());
  auto parent = openPrivateParent(absolute.string());
  const auto name = absolute.filename().string();
  const auto lock_name = name + ".lock";
  FileDescriptor lock{::openat(parent.get(), lock_name.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600)};
  struct stat state{};
  if (!lock || ::fstat(lock.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
    throw CommandError{"InsecureFile"};
  }

  while (::flock(lock.get(), LOCK_EX) != 0) {
    if (errno != EINTR) {
      throw fileError(errno);
    }
  }

  auto profiles = load(memory, absolute.string());
  edit(profiles);
  const auto source = MachineProfileCodec::format(memory, profiles);
  const auto error = writePrivateFile(parent.get(), name, byteView(source), PrivateFileMode::replace);
  if (error != 0) {
    throw fileError(error);
  }
}

inline const char *describe(std::string_view error) {
  if (error == "SetupBinaryCompanionsMissing") {
    return "a C++ --binary needs telar-runtime and telar-config-check beside it";
  }

  if (error == "InsecureFile") {
    return "machines.json must be a regular file only its owner can read and write (chmod 600)";
  }

  if (error == "UnknownMachine") {
    return "no saved machine has that label; see `telar machine list`";
  }

  if (error == "DuplicateMachineLabel") {
    return "that label is already taken, by a saved machine or by this machine";
  }

  if (error == "DuplicateMachineDestination") {
    return "two saved machines cannot share one SSH destination";
  }

  if (error == "TooManyMachines") {
    return "machines.json already holds the most machines it can";
  }

  if (error == "InvalidMachineLabel") {
    return "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit";
  }

  if (error == "InvalidMachineColor") {
    return "colors are #RRGGBB or a theme role such as red or accent";
  }

  if (error == "InvalidRemoteDestination") {
    return "destinations are an ssh host alias or user@host, without spaces or a leading '-'";
  }

  if (error == "InvalidRemoteTelarPath") {
    return "telar paths are absolute and hold only letters, digits, '/', '.', '_', '+' or '-'";
  }

  if (error == "InvalidMachineProfiles") {
    return "machines.json is not a file this telar can read";
  }

  if (error == "IncompatibleMachineProfiles") {
    return "machines.json was written by a newer telar; update this one to read it";
  }

  return nullptr;
}

inline int report(const std::exception &error) {
  const auto *text = describe(error.what());
  std::fprintf(stderr, "telar machine: %s\n", text ? text : error.what());
  return 1;
}

template <Allocator Memory>
int list(Memory &memory, const MachineProfiles &profiles, bool json) {
  if (json) {
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += "{\"local\":";
    appendJsonString(output, localLabel(profiles));
    output += ",\"machines\":[";
    bool first = true;
    for (const auto &profile : profiles.rows()) {
      if (!first) {
        output += ',';
      }

      first = false;
      MachineProfileCodec::appendProfile(output, profile);
    }

    output += "]}\n";
    std::fwrite(output.data(), 1, output.size(), stdout);
  } else {
    std::printf("%s\tlocal\n", localLabel(profiles).c_str());
    for (const auto &profile : profiles.rows()) {
      std::printf("%.*s\t%.*s\t%s", static_cast<int>(profile.label().size()), profile.label().data(), static_cast<int>(profile.destination().size()), profile.destination().data(), profile.enabled() ? "enabled" : "disabled");
      if (const auto color = profile.color()) {
        std::printf("\t%.*s", static_cast<int>(color->size()), color->data());
      }

      bool first = true;
      for (const auto agent : machine_agents) {
        if (const auto login = profile.login(agent)) {
          std::printf("%s%s %s", first ? "\tlogins: " : ", ", machine_agent_names.at(static_cast<std::size_t>(agent)).data(), machine_login_names.at(static_cast<std::size_t>(*login)).data());
          first = false;
        }
      }

      std::putchar('\n');
    }
  }

  return 0;
}

}
