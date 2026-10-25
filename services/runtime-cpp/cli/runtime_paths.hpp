#pragma once

#include "../memory/allocator.hpp"
#include "../platform/private_directory.hpp"
#include "../platform/process_environment.hpp"
#include "server_options.hpp"
#include <charconv>
#include <sys/un.h>

namespace telar::runtime::cli {

template <EnvironmentLookup Environment>
struct DefaultSocketEnvironment {
  const Environment &source;

  std::string_view lookup(const char *name) const noexcept {
    const std::string_view key{name};
    return key == "TELAR_SOCKET" || key == "TELAR_SOCKET_PATH" ? std::string_view{} : source.lookup(name);
  }
};

template <Allocator Memory>
class RuntimePaths {
public:
  template <EnvironmentLookup Environment>
  explicit RuntimePaths(Memory &memory, const ServerOptions &options, const Environment &environment)
      : socket(AllocatorRef<char, Memory>{memory}),
        history(AllocatorRef<char, Memory>{memory}),
        session(AllocatorRef<char, Memory>{memory}) {
    resolveSocket(options.socket, environment);
  }

  template <EnvironmentLookup Environment>
  void resolveStorage(const ServerOptions &options, const Environment &environment) {
    history = options.history.empty() ? environment.lookup("TELAR_HISTORY") : options.history;
    if (history.empty()) {
      const auto data_home = environment.lookup("XDG_DATA_HOME");
      if (!data_home.empty()) {
        history = data_home;
      } else {
        const auto home = environment.lookup("HOME");
        if (home.empty()) {
          throw std::invalid_argument{"Home directory unavailable"};
        }

        history = home;
        history += "/.local/share";
      }

      history += "/telar/history.db";
      history_managed = true;
    }

    if (options.persist_session) {
      if (!options.session.empty()) {
        session = options.session;
      } else {
        session.assign(std::string_view{history}.substr(0, history.find_last_of('/') + 1));
        session += "session.ckpt";
      }
    }
  }

  void prepareSocket() const {
    if (socket_managed) {
      createPrivateDirectory(std::string_view{socket}.substr(0, socket.rfind('/')));
    }
  }

  template <EnvironmentLookup Environment>
  bool isDefaultSocket(const Environment &environment) const {
    const RuntimePaths expected{socket.get_allocator().memory(), ServerOptions{}, DefaultSocketEnvironment<Environment>{environment}};
    return socket == expected.socket;
  }

  void prepareStorage() const {
    if (history_managed) {
      createPrivateDirectory(std::string_view{history}.substr(0, history.rfind('/')));
    }
  }

  String<Memory> socket;
  String<Memory> history;
  String<Memory> session;
  bool socket_managed = false;
  bool history_managed = false;

private:
  template <EnvironmentLookup Environment>
  void resolveSocket(std::string_view override, const Environment &environment) {
    for (const auto candidate : {override, environment.lookup("TELAR_SOCKET"), environment.lookup("TELAR_SOCKET_PATH")}) {
      if (!candidate.empty()) {
        socket = candidate;
        validateSocket();
        return;
      }
    }

    socket_managed = true;
    if (const auto runtime_directory = environment.lookup("XDG_RUNTIME_DIR"); !runtime_directory.empty()) {
      socket = runtime_directory;
      appendSocketDirectory("telar");
    } else {
      const auto temporary_directory = environment.lookup("TMPDIR");
      socket = temporary_directory.empty() ? "/tmp" : temporary_directory;
      std::array<char, 32> name;
      constexpr std::string_view prefix = "telar-";
      std::copy(prefix.begin(), prefix.end(), name.begin());
      const auto converted = std::to_chars(name.data() + prefix.size(), name.data() + name.size(), ::getuid());
      appendSocketDirectory({name.data(), converted.ptr});
    }

    validateSocket();
  }

  void appendSocketDirectory(std::string_view name) {
    if (socket.back() != '/') {
      socket.push_back('/');
    }

    socket += name;
    socket += "/runtime.sock";
  }

  void validateSocket() const {
    if (socket.empty() || socket.front() != '/' || socket.size() >= sizeof(sockaddr_un::sun_path) || socket.back() == '/' || socket.contains('\0')) {
      throw std::invalid_argument{"Invalid absolute runtime socket path"};
    }
  }
};

}
