#pragma once

#include "clipboard_metadata.hpp"
#include "clipboard_write.hpp"
#include "reply.hpp"
#include "sequence.hpp"

namespace telar::runtime::control {

inline constexpr std::size_t clipboard_chunk_bytes = 4096;

struct ClipboardPacket {
  ClipboardOperation operation = ClipboardOperation::read;
  ClipboardStatus status = ClipboardStatus::ok;
  bool primary = false;
  std::string_view id{};
  std::optional<std::string_view> mime{};
  std::optional<std::string_view> password{};
  std::span<const std::uint8_t> payload{};
  Ending ending = Ending::escape;
};

template <Allocator Memory>
void clipboardBase64(Reply<Memory> &reply, std::span<const std::uint8_t> input) {
  constexpr std::size_t raw_chunk_bytes = 3072;
  std::array<char, raw_chunk_bytes / 3 * 4> encoded;
  while (!input.empty()) {
    const auto count = std::min(input.size(), raw_chunk_bytes);
    const auto size = base64::encode(input.first(count), encoded);
    if (!size) {
      throw std::logic_error{"Clipboard encoder capacity invariant failed"};
    }
    reply.append({encoded.data(), *size});
    input = input.subspan(count);
  }
}

template <Allocator Memory>
void clipboardBase64(Reply<Memory> &reply, std::string_view input) {
  clipboardBase64(reply, std::span{reinterpret_cast<const std::uint8_t *>(input.data()), input.size()});
}

template <Allocator Memory>
void clipboardPacket(Reply<Memory> &reply, const ClipboardPacket &packet) {
  reply.append(packet.operation == ClipboardOperation::read ? "\x1b]5522;type=read:status=" : "\x1b]5522;type=write:status=");
  reply.append(clipboardStatusName(packet.status));
  if (packet.primary) {
    reply.append(":loc=primary");
  }
  if (!packet.id.empty()) {
    reply.append(":id=");
    reply.append(packet.id);
  }
  if (packet.mime) {
    reply.append(":mime=");
    clipboardBase64(reply, *packet.mime);
  }
  if (packet.password) {
    reply.append(":pw=");
    clipboardBase64(reply, *packet.password);
  }
  if (!packet.payload.empty()) {
    reply.append(";");
    clipboardBase64(reply, packet.payload);
  }
  reply.append(packet.ending == Ending::bell ? "\a" : "\x1b\\");
}

template <Allocator Memory>
void clipboardReadSuccess(Reply<Memory> &reply, const ClipboardPacket &request, std::span<const ClipboardContentView> contents, std::span<const std::string_view> available, bool listing) {
  auto packet = request;
  packet.operation = ClipboardOperation::read;
  packet.status = ClipboardStatus::ok;
  clipboardPacket(reply, packet);
  packet.primary = false;
  if (listing) {
    std::array<std::uint8_t, clipboard_chunk_bytes> joined;
    std::size_t length = 0;
    for (const auto mime : available) {
      const auto separator = length == 0 ? 0u : 1u;
      if (mime.size() + separator + 1 > joined.size() - length) {
        break;
      }
      if (separator != 0) {
        joined[length++] = ' ';
      }
      std::copy(mime.begin(), mime.end(), joined.begin() + length);
      length += mime.size();
    }
    if (length != 0) {
      joined[length++] = '\n';
    }
    packet.status = ClipboardStatus::data;
    packet.mime = ".";
    packet.payload = std::span<const std::uint8_t>{joined}.first(length);
    clipboardPacket(reply, packet);
  }
  for (const auto &content : contents) {
    auto remaining = content.data;
    while (!remaining.empty()) {
      const auto count = std::min(remaining.size(), clipboard_chunk_bytes);
      packet.status = ClipboardStatus::data;
      packet.mime = content.mime;
      packet.payload = remaining.first(count);
      clipboardPacket(reply, packet);
      remaining = remaining.subspan(count);
    }
  }
  packet.status = ClipboardStatus::done;
  packet.mime.reset();
  packet.payload = {};
  clipboardPacket(reply, packet);
}

}
