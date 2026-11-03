#pragma once

#include "control_session.hpp"
#include "json_text.hpp"
#include "server.hpp"
#include "session_arguments.hpp"
#include <filesystem>
#include <pwd.h>

namespace telar::runtime::cli::sessions {

class Failure : public std::runtime_error {
public:
  explicit Failure(std::string_view message, int status = 1, std::optional<FailureCode> code = std::nullopt)
      : std::runtime_error{std::string{message}},
        status_(status),
        code_(code) {}

  int status() const noexcept {
    return status_;
  }

  std::optional<FailureCode> code() const noexcept {
    return code_;
  }

private:
  int status_;
  std::optional<FailureCode> code_;
};

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

inline void ensureRuntime(auto &memory, const auto &paths, const ServerOptions &options) {
  std::optional<RuntimeConnection> connection;
  if (connectExisting(connection, paths.socket.c_str())) {
    return;
  }

  paths.prepareSocket();
  const auto child = launchDaemon(memory, options, paths, ExecutablePath{runtime_program});
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  while (!connectExisting(connection, paths.socket.c_str())) {
    int status{};
    if (::waitpid(child, &status, WNOHANG) == child || std::chrono::steady_clock::now() >= deadline) {
      throw Failure{"the local runtime is not reachable"};
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{10});
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
    if (start) {
      ensureRuntime(memory, paths_, options);
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

template <Allocator Memory>
class Output {
public:
  explicit Output(Memory &memory)
      : bytes_(AllocatorRef<char, Memory>{memory}) {}

  Output &raw(std::string_view value) {
    bytes_.append(value);
    return *this;
  }

  Output &number(std::uint64_t value) {
    return raw(std::to_string(value));
  }

  Output &signedNumber(std::int64_t value) {
    return raw(std::to_string(value));
  }

  Output &boolean(bool value) {
    return raw(value ? "true" : "false");
  }

  Output &quoted(std::string_view value, JsonEscapes escapes = JsonEscapes::standard) {
    appendJsonText(bytes_, value, escapes);
    return *this;
  }

  void flush() {
    std::fwrite(bytes_.data(), 1, bytes_.size(), stdout);
    bytes_.clear();
  }

private:
  String<Memory> bytes_;
};

inline void checkLocation(TabLocation actual, TabLocation expected) {
  if (actual.workspace.kind != expected.workspace.kind || actual.workspace.id != expected.workspace.id || actual.tab_id != expected.tab_id) {
    throw Failure{"unexpected reply from the runtime"};
  }
}

inline std::string_view actionName(ClientAction action) {
  switch (action) {
  case ClientAction::workspace_select:
    return "workspace_select";
  case ClientAction::tab_create:
    return "tab_create";
  case ClientAction::tab_select:
    return "tab_select";
  case ClientAction::tab_next:
    return "tab_next";
  case ClientAction::tab_previous:
    return "tab_previous";
  default:
    throw Failure{"unexpected reply from the runtime"};
  }
}

inline std::string_view statusName(ClientCommandStatus status) {
  switch (status) {
  case ClientCommandStatus::applied:
    return "applied";
  case ClientCommandStatus::admitted:
    return "admitted";
  default:
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

template <Allocator Memory>
int routed(Memory &memory, const RoutedOptions &options) {
  try {
    Channel session{memory, options.socket, false};
    const auto clients = session.template exchange<ClientList>(QueryClients{}, false);
    const auto client = chooseClient(clients.entries, options.client);
    RequestClientCommand request;
    request.route = {.id = client.id, .generation = client.generation};
    request.action = options.action;
    request.target_id = options.target;
    request.text = options.label;
    const auto reply = session.template exchange<ClientCommandResult>(request, false);
    if (reply.route.id != client.id || reply.route.generation != client.generation || reply.action != request.action || reply.target_id != request.target_id || reply.status == ClientCommandStatus::request) {
      throw Failure{"unexpected reply from the runtime"};
    }

    if (reply.status == ClientCommandStatus::failed) {
      throw Failure{reply.text};
    }
    Output output{memory};
    if (options.json) {
      output.raw("{\"client_id\":").number(client.id).raw(",\"client_generation\":").number(client.generation).raw(",\"action\":").quoted(actionName(reply.action)).raw(",\"status\":").quoted(statusName(reply.status)).raw(",\"target_id\":").number(reply.target_id).raw(",\"value\":").signedNumber(reply.value).raw(",\"text\":").quoted(reply.text).raw("}\n");
    } else {
      output.raw(actionName(reply.action)).raw(": ").raw(statusName(reply.status));
      if (!reply.text.empty()) {
        output.raw(" ").raw(reply.text);
      }
      output.raw("\n");
    }

    output.flush();
    return 0;
  } catch (const Failure &error) {
    std::fprintf(stderr, "telar: %s\n", error.what());
    return error.status();
  }
}

}
