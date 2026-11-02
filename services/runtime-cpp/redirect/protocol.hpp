#pragma once

#include "../plugins/frame_reader.hpp"
#include "../plugins/frame_writer.hpp"
#include "../proxy/socket.hpp"
#include "connection.hpp"
#include <sys/uio.h>

namespace telar::runtime::redirect {

inline constexpr std::string_view socket_suffix = ".redirect";
enum class Kind : Byte { monitor = 1, connection = 2 };
enum class MonitorState : Byte { idle, starting, active, stopping, cleanup_required };
enum class MonitorUpdate : Byte { active = 1, stopped = 2 };
inline constexpr Byte stop_request = 1;

class Protocol {
public:
  static constexpr std::uint32_t magic = 0x31524454;
  static constexpr std::size_t frame_bytes = 128;
  static constexpr std::size_t descriptor_count = 2;
  static constexpr std::size_t header_bytes = sizeof(std::uint32_t) + sizeof(Byte) + sizeof(std::uint32_t);
  static constexpr std::size_t tail_bytes = sizeof(std::uint16_t);

  static std::span<const Byte> encode(std::span<Byte> output, Kind kind, const Target &target) {
    plugins::FrameWriter writer{output};
    writer.integer(magic);
    writer.tag(kind);
    writer.text(target.host.view());
    writer.integer(target.port);
    return writer.finish();
  }

  static void send(int channel, const Connection &connection) {
    std::array<Byte, frame_bytes> output;
    const auto frame = encode(output, Kind::connection, connection.target);
    iovec vector{.iov_base = const_cast<Byte *>(frame.data()), .iov_len = frame.size()};
    alignas(cmsghdr) std::array<Byte, CMSG_SPACE(descriptor_count * sizeof(int))> control{};
    msghdr message{};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.data();
    message.msg_controllen = control.size();
    auto *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(descriptor_count * sizeof(int));
    const std::array descriptors{connection.child.get(), connection.origin.get()};
    std::memcpy(CMSG_DATA(header), descriptors.data(), sizeof(descriptors));
    ssize_t written;
    do {
      written = ::sendmsg(channel, &message, 0);
    } while (written < 0 && errno == EINTR);
    if (written <= 0) {
      throw SystemError{"Transfer redirected sockets"};
    }
    auto remaining = frame.subspan(static_cast<std::size_t>(written));
    while (!remaining.empty()) {
      written = ::send(channel, remaining.data(), remaining.size(), 0);
      if (written < 0 && errno == EINTR) {
        continue;
      }
      if (written <= 0) {
        throw SystemError{"Finish redirected socket transfer"};
      }
      remaining = remaining.subspan(static_cast<std::size_t>(written));
    }
    ::shutdown(channel, SHUT_WR);
  }
};

// Descriptors are adopted immediately, including on malformed/truncated frames.
// A failed decode therefore closes every received descriptor.
class Incoming {
public:
  bool receive(int channel) {
    iovec vector{.iov_base = bytes_.data() + size_, .iov_len = bytes_.size() - size_};
    alignas(cmsghdr) std::array<Byte, CMSG_SPACE(8 * sizeof(int))> control{};
    msghdr message{};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.data();
    message.msg_controllen = control.size();
    const auto count = ::recvmsg(channel, &message, 0);
    if (count < 0) {
      if (socketWouldBlock(errno)) {
        return false;
      }
      throw SystemError{"Receive redirected sockets"};
    }
    bool invalid = (message.msg_flags & MSG_CTRUNC) != 0;
    for (auto *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
      if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) {
        invalid = true;
        continue;
      }
      const auto descriptors = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
      for (std::size_t index = 0; index < descriptors; ++index) {
        int raw;
        std::memcpy(&raw, CMSG_DATA(header) + index * sizeof(int), sizeof(raw));
        FileDescriptor received{raw};
        if (received_ == sockets_.size()) {
          invalid = true;
        } else {
          sockets_[received_++] = std::move(received);
        }
      }
    }
    if (invalid) {
      throw EncodingError{"Invalid redirected socket descriptors"};
    }
    for (std::size_t index = 0; index < received_; ++index) {
      setCloseOnExec(sockets_[index].get());
    }
    if (count > 0 && size_ + static_cast<std::size_t>(count) == bytes_.size()) {
      throw EncodingError{"Invalid redirect frame"};
    }
    if (count > 0) {
      size_ += static_cast<std::size_t>(count);
      if (size_ < Protocol::header_bytes) {
        return false;
      }
      auto length = std::span<const Byte>{bytes_}.first(size_).subspan(sizeof(std::uint32_t) + sizeof(Byte));
      const auto host_bytes = LittleEndian<std::uint32_t>::decode(length);
      const auto expected = Protocol::header_bytes + static_cast<std::size_t>(host_bytes) + Protocol::tail_bytes;
      if (expected > bytes_.size() || size_ > expected) {
        throw EncodingError{"Invalid redirect frame length"};
      }
      return size_ == expected;
    }
    throw EncodingError{"Truncated redirect frame"};
  }

  Kind kind() const {
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    if (reader.integer<std::uint32_t>() != Protocol::magic) {
      throw EncodingError{"Incompatible redirect protocol"};
    }
    const auto kind = reader.tag(Kind::connection);
    if (kind != Kind::monitor && kind != Kind::connection) {
      throw EncodingError{"Unknown redirect operation"};
    }
    return kind;
  }

  void validateMonitor() const {
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    reader.integer<std::uint32_t>();
    reader.integer<Byte>();
    if (!reader.text().empty() || reader.integer<std::uint16_t>() != 0 || received_ != 0) {
      throw EncodingError{"A redirect monitor cannot carry sockets or a target"};
    }
    reader.finish();
  }

  Connection take() {
    if (kind() != Kind::connection || received_ != Protocol::descriptor_count) {
      throw EncodingError{"A redirected connection requires two sockets"};
    }
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    reader.integer<std::uint32_t>();
    reader.integer<Byte>();
    const auto host = reader.text();
    const auto port = reader.integer<std::uint16_t>();
    reader.finish();
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
      throw EncodingError{"Invalid redirected host"};
    }
    std::array<char, Protocol::frame_bytes> address{};
    const auto count = std::snprintf(address.data(), address.size(), host.contains(':') ? "[%.*s]:%u" : "%.*s:%u", static_cast<int>(host.size()), host.data(), port);
    if (count < 0 || static_cast<std::size_t>(count) >= address.size()) {
      throw EncodingError{"Invalid redirect destination"};
    }
    auto target = Target::parse(address.data());
    for (const auto &socket : sockets_) {
      int type = 0;
      socklen_t length = sizeof(type);
      sockaddr_storage peer{};
      socklen_t peer_length = sizeof(peer);
      if (::getsockopt(socket.get(), SOL_SOCKET, SO_TYPE, &type, &length) != 0 || type != SOCK_STREAM || ::getpeername(socket.get(), reinterpret_cast<sockaddr *>(&peer), &peer_length) != 0 || peer.ss_family != target.endpoint.storage.ss_family) {
        throw EncodingError{"Redirect handoff requires connected TCP sockets"};
      }
      configureProxySocket(socket.get());
    }
    sockaddr_storage actual{};
    socklen_t size = sizeof(actual);
    if (::getpeername(sockets_[1].get(), reinterpret_cast<sockaddr *>(&actual), &size) != 0) {
      throw SystemError{"Inspect redirected origin"};
    }
    const bool matches = actual.ss_family == AF_INET
        ? reinterpret_cast<const sockaddr_in *>(&actual)->sin_port == htons(target.port) && reinterpret_cast<const sockaddr_in *>(&actual)->sin_addr.s_addr == reinterpret_cast<const sockaddr_in *>(&target.endpoint.storage)->sin_addr.s_addr
        : reinterpret_cast<const sockaddr_in6 *>(&actual)->sin6_port == htons(target.port) && std::memcmp(&reinterpret_cast<const sockaddr_in6 *>(&actual)->sin6_addr, &reinterpret_cast<const sockaddr_in6 *>(&target.endpoint.storage)->sin6_addr, sizeof(in6_addr)) == 0;
    if (!matches) {
      throw EncodingError{"Redirected origin does not match its original destination"};
    }
    return {.child = std::move(sockets_[0]), .origin = std::move(sockets_[1]), .target = target};
  }

private:
  std::array<Byte, Protocol::frame_bytes> bytes_{};
  std::array<FileDescriptor, Protocol::descriptor_count> sockets_;
  std::size_t size_ = 0;
  std::size_t received_ = 0;
};

}
