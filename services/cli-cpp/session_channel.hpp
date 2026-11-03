#pragma once

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
// connection from exchanges, and own their borrowed strings for the command's life.
template <Allocator Memory>
class Channel {
public:
  Channel(Memory &memory, std::optional<std::string_view> socket, bool start)
      : paths_(memory, socketOptions(socket), ProcessEnvironment{}),
        incoming_(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory}),
        decoded_(max_payload_size, Byte{}, AllocatorRef<Byte, Memory>{memory}) {
    const auto options = socketOptions(socket);
    std::optional<RuntimeConnection> probe;
    if (start && !connectExisting(probe, paths_.socket.c_str()) && startRuntime(memory, options, paths_) != RuntimeStart::listening) {
      throw Failure{"the local runtime is not reachable"};
    }

    try {
      connection_.emplace(paths_.socket.c_str());
    } catch (const SystemError &error) {
      switch (error.code()) {
      case ENOENT:
        throw Failure{"FileNotFound"};
      case ECONNREFUSED:
        throw Failure{"ConnectionRefused"};
      case EACCES:
        throw Failure{"PermissionDenied"};
      case ENOTDIR:
        throw Failure{"NotDir"};
      case ELOOP:
        throw Failure{"SymLinkLoop"};
      case ENAMETOOLONG:
        throw Failure{"NameTooLong"};
      default:
        throw Failure{"the local runtime is not reachable"};
      }
    }
    connection_->receiveTimeout(reply_timeout_seconds);
  }

  template <typename Reply, typename Request>
  Reply exchange(Request request, bool reason = true) {
    request.request_id = next_request_++;
    connection_->send(request, outgoing_);
    for (;;) {
      const auto frame = receive();
      DecodeStorage storage{decoded_};
      if (frame.front() == static_cast<Byte>(MessageSchema<Reply>::tag)) {
        const auto reply = Codec::decode<Reply>(frame, storage);
        if constexpr (requires { reply.request_id; }) {
          if (reply.request_id == request.request_id) {
            return reply;
          }
        } else {
          return reply;
        }
      } else if (frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
        const auto failure = Codec::decode<RequestFailed>(frame, storage);
        if (failure.request_id == request.request_id) {
          throw Failure{reason ? failure.message : controlFailureDescription(failure.code), 1, failure.code};
        }
      }
    }
  }

  WorkspaceList catalog() {
    std::uint64_t identity{};
    while (identity == 0) {
      ::arc4random_buf(&identity, sizeof(identity));
    }
    connection_->send(RequestRuntimeState{.client_identity = identity, .interactive = false}, outgoing_);
    for (;;) {
      const auto frame = receive();
      if (frame.front() == static_cast<Byte>(ServerTag::workspace_list)) {
        DecodeStorage storage{decoded_};
        return Codec::decode<WorkspaceList>(frame, storage);
      }
    }
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

  std::span<const Byte> receive() {
    try {
      const auto frame = connection_->receive(incoming_);
      if (frame.empty()) {
        throw Failure{"unexpected reply from the runtime"};
      }
      if (frame.front() == static_cast<Byte>(ServerTag::runtime_stopping)) {
        throw Failure{"RuntimeStopping"};
      }
      return frame;
    } catch (const SocketError &) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        throw Failure{"RuntimeTimeout", 3};
      }
      throw Failure{"unexpected reply from the runtime"};
    }
  }

  static constexpr unsigned reply_timeout_seconds = 30;
  static constexpr std::size_t request_bytes = 65536 + 4096 + 1024;
  RuntimePaths<Memory> paths_;
  std::optional<RuntimeConnection> connection_;
  std::array<Byte, request_bytes> outgoing_;
  Vector<Byte, Memory> incoming_, decoded_;
  std::uint64_t next_request_ = 1;
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
