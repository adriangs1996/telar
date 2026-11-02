#pragma once

#include "datagram.hpp"
#include "ip_fragments.hpp"
#include "tcp_flows.hpp"

namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory>
class CaptureAnalysis {
public:
  explicit CaptureAnalysis(Memory &memory) : memory_(memory), fragments_(memory), tcp_(memory) {}

  template <typename Emit>
  void packet(const Event &event, Selection selection, Emit emit) {
    fragments_.packet(event, [&](std::span<const Byte> bytes) {
      const auto ip = IpPayload::decode(bytes);
      if (!ip) { return; }
      if (ip->protocol == IPPROTO_TCP && selects(selection, Selection::flows)) { tcp_.payload(event, *ip, emit); }
      if (!selects(selection, Selection::datagrams)) { return; }
      const auto datagram = DatagramCodec::parse(*ip);
      if (!datagram) { return; }
      SensitiveAllocation storage{memory_, datagram->bytes.size() + Limits::metadata_bytes};
      auto publication = event;
      publication.kind = Kind::datagram;
      publication.bytes = DatagramCodec::encode(storage.bytes(), *datagram);
      emit(publication);
    }, [&](const Event &source, std::string_view reason) { fragmentError(source, reason, emit); });
  }

  template <typename Emit>
  void expire(Emit emit, bool stop = false) {
    fragments_.expire([&](const Event &source, std::string_view reason) { fragmentError(source, reason, emit); }, stop);
    tcp_.expire(emit, stop);
  }

private:
  template <typename Emit>
  static void fragmentError(Event event, std::string_view reason, Emit emit) {
    event.kind = Kind::error;
    event.bytes = {reinterpret_cast<const Byte *>(reason.data()), reason.size()};
    emit(event);
  }

  Memory &memory_;
  IpFragments<Memory> fragments_;
  TcpFlows<Memory> tcp_;
};

}
