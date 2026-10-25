#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include <cstdio>
#include <fstream>
#include <optional>
#include <variant>
#include <vector>

class ProtocolFailure : public std::runtime_error {
public:
  ProtocolFailure(telar::FailureCode code, std::string_view message)
      : std::runtime_error(std::string{message}),
        code(code) {}

  telar::FailureCode code;
};

class ProtocolPeer {
public:
  explicit ProtocolPeer(const char *socket, bool acknowledge_frames = true)
      : client_(telar::Client::init(socket)),
        incoming_(telar::max_payload_size),
        outgoing_(telar::max_payload_size + telar::frame_prefix_size),
        scratch_(512 * 1024), acknowledge_frames_(acknowledge_frames) {
    client_.handshake();
    const timeval timeout{.tv_sec = 15,
                          .tv_usec = 0};
    ::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  }

  ~ProtocolPeer() {
    client_.deinit();
  }

  ProtocolPeer(const ProtocolPeer &) = delete;
  ProtocolPeer &operator=(const ProtocolPeer &) = delete;

  void reconnect(const char *socket) {
    client_.deinit();
    client_ = telar::Client::init(socket);
    client_.handshake();
    const timeval timeout{.tv_sec = 15, .tv_usec = 0};
    ::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  }

  int descriptor() const noexcept {
    return client_.descriptor();
  }

  std::span<const telar::Byte> receivePayload() {
    return client_.receiveFrame(incoming_);
  }

  template <typename Message>
  void send(const Message &message) {
    client_.send(message, outgoing_);
  }

  template <typename Reply, typename Request>
  Reply exchange(const Request &request) {
    send(request);
    for (;;) {
      const auto reply = receive<Reply>();
      if constexpr (requires { reply.request_id; request.request_id; }) {
        if (reply.request_id != request.request_id) {
          continue;
        }
      }
      return reply;
    }
  }

  template <typename Reply>
  Reply receive() {
    return std::get<Reply>(receiveAny<Reply>());
  }

  template <typename... Replies>
  std::variant<Replies...> receiveAny() {
    for (;;) {
      const auto payload = client_.receiveFrame(incoming_);
      telar::DecodeStorage storage{scratch_};
      std::optional<std::variant<Replies...>> reply;
      ([&] {
        if (payload.front() == static_cast<telar::Byte>(telar::MessageSchema<Replies>::tag)) {
          reply.emplace(std::in_place_type<Replies>, telar::Codec::decode<Replies>(payload, storage));
        }
      }(),
       ...);
      if (reply) {
        return std::move(*reply);
      }
      if (payload.front() == static_cast<telar::Byte>(telar::ServerTag::pane_frame)) {
        const auto frame = telar::Codec::decode<telar::PaneFrame>(payload, storage);
        if (acknowledge_frames_) {
          send(telar::FrameAck{frame.pane_id, frame.frame_id});
        }
      } else if (payload.front() == static_cast<telar::Byte>(telar::ServerTag::request_failed)) {
        const auto failure = telar::Codec::decode<telar::RequestFailed>(payload, storage);
        throw ProtocolFailure{failure.code, failure.message};
      }
    }
  }

  template <typename Message>
  void record(std::ostream &output, const Message &message) {
    const auto payload = telar::Codec::encode(message, outgoing_);
    output.write(reinterpret_cast<const char *>(payload.data()), static_cast<std::streamsize>(payload.size()));
  }

private:
  telar::Client client_;
  std::vector<telar::Byte> incoming_;
  std::vector<telar::Byte> outgoing_;
  std::vector<telar::Byte> scratch_;
  bool acknowledge_frames_;
};
