#pragma once

#include "command_io.hpp"
#include "control_session.hpp"
#include "failure.hpp"
#include "output.hpp"
#include "json_text.hpp"
#include "server.hpp"
#include "session_arguments.hpp"
#include <filesystem>
#include <pwd.h>

namespace telar::runtime::cli::sessions {


inline std::string realDirectory(std::string_view path) {
  std::error_code error;
  auto resolved = std::filesystem::canonical(path, error);
  if (error) {
    throw Failure{error == std::errc::no_such_file_or_directory ? "FileNotFound" : error == std::errc::not_a_directory ? "NotDir"
                                                                                                                       : "AccessDenied"};
  }

  if (!std::filesystem::is_directory(resolved, error)) {
    throw Failure{"NotDir"};
  }

  return resolved.string();
}

inline std::string_view loginShell() {
  if (const auto shell = ::getenv("SHELL"); shell && *shell) {
    return shell;
  }

  if (const auto entry = ::getpwuid(::getuid()); entry && entry->pw_shell && *entry->pw_shell) {
    return entry->pw_shell;
  }

  return "/bin/sh";
}

inline void wireTabLabel(std::string_view value, bool empty = false) {
  if ((!empty && value.empty()) || value.size() > tab_label_bytes) {
    throw Failure{"InvalidByteString"};
  }
  try {
    validateUtf8(value);
  } catch (const EncodingError &) {
    throw Failure{"InvalidUtf8"};
  }
  for (const unsigned char byte : value) {
    if (byte < ' ' || byte == 0x7f) {
      throw Failure{"InvalidTabLabel"};
    }
  }
}

// Catalog subscriptions also carry unrelated broadcasts. Keep them on a separate
// connection from exchanges. The protocol is ControlSession's; Channel adds
// the sessions commands' runtime start and their descriptions of failures.
template <Allocator Memory>
class Channel {
public:
  Channel(Memory &memory, std::optional<std::string_view> socket, bool start)
      : paths_(memory, socketOptions(socket), ProcessEnvironment{}) {
    std::optional<RuntimeConnection> probe;
    if (start && !connectExisting(probe, paths_.socket.c_str()) && startRuntime(memory, socketOptions(socket), paths_) != RuntimeStart::listening) {
      throw Failure{"the local runtime is not reachable"};
    }

    try {
      session_.emplace(memory, paths_.socket.c_str());
    } catch (const SystemError &error) {
      throw Failure{connectionFailure(error.code())};
    }

    session_->receiveTimeout(reply_timeout_seconds);
  }

  // `reason` reports the runtime's own words for a refusal; otherwise the
  // refusal's generic description.
  template <typename Reply, typename Request>
  Reply exchange(Request request, bool reason = true) {
    return translated([&] { return session_->template exchange<Reply>(request); }, reason);
  }

  WorkspaceList catalog() {
    return translated([&] {
      session_->send(RequestRuntimeState{.client_identity = randomIdentity(), .interactive = false});
      return session_->template receive<WorkspaceList>();
    });
  }

  const char *socket() const {
    return paths_.socket.c_str();
  }

private:
  static ServerOptions socketOptions(std::optional<std::string_view> socket) {
    ServerOptions options;
    options.socket = socket.value_or("");
    return options;
  }

  static const char *connectionFailure(int code) noexcept {
    switch (code) {
    case ENOENT:
      return "FileNotFound";
    case ECONNREFUSED:
      return "ConnectionRefused";
    case EACCES:
      return "PermissionDenied";
    case ENOTDIR:
      return "NotDir";
    case ELOOP:
      return "SymLinkLoop";
    case ENAMETOOLONG:
      return "NameTooLong";
    default:
      return "the local runtime is not reachable";
    }
  }

  template <typename Operation>
  static auto translated(Operation &&operation, bool reason = true) {
    try {
      return operation();
    } catch (const ControlFailure &failure) {
      throw Failure{reason ? failure.message() : std::string_view{controlFailureDescription(failure.code())}, 1, failure.code()};
    } catch (const SocketError &) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        throw Failure{"RuntimeTimeout", 3};
      }

      throw Failure{"unexpected reply from the runtime"};
    } catch (const EncodingError &) {
      throw Failure{"unexpected reply from the runtime"};
    } catch (const std::runtime_error &error) {
      if (std::string_view{error.what()} == "RuntimeStopping") {
        throw Failure{"RuntimeStopping"};
      }

      throw;
    }
  }

  static constexpr unsigned reply_timeout_seconds = 30;
  RuntimePaths<Memory> paths_;
  std::optional<ControlSession<Memory>> session_;
};


inline void checkLocation(TabLocation actual, TabLocation expected) {
  if (actual.workspace.kind != expected.workspace.kind || actual.workspace.id != expected.workspace.id || actual.tab_id != expected.tab_id) {
    throw Failure{"unexpected reply from the runtime"};
  }
}

inline ClientDescriptor chooseClient(std::span<const ClientDescriptor> clients, std::uint64_t wanted) {
  std::optional<ClientDescriptor> chosen;
  for (const auto &client : clients) {
    if (wanted != 0) {
      if (client.id == wanted) {
        return client;
      }
      continue;
    }

    if (!chosen || client.last_input_sequence > chosen->last_input_sequence) {
      chosen = client;
    }
  }

  if (!chosen) {
    throw Failure{"ClientNotFound", 2};
  }
  return *chosen;
}

}
