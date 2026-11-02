#pragma once

#include "log_interface.hpp"
#include "direction.hpp"
#include "../memory/fixed_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <algorithm>
#include <array>
#include <arpa/inet.h>
#include <memory>
#include <pcap/pcap.h>

namespace telar::runtime::redirect {

class PacketLog {
  struct Header {
    Byte length;
    Byte family;
    Byte action;
    Byte reason;
    std::array<char, 16> interface;
    std::array<char, 16> ruleset;
    std::uint32_t rule;
    std::uint32_t subrule;
    uid_t uid;
    pid_t pid;
    uid_t rule_uid;
    pid_t rule_pid;
    Byte direction;
    std::array<Byte, 3> padding;
  };
  static_assert(sizeof(Header) == 64 && offsetof(Header, uid) == 44 && offsetof(Header, direction) == 60);
  enum class PfDirection : Byte { incoming = 1, outgoing = 2 };
  enum class Action : Byte { pass = 0 };

public:
  struct Metadata {
    pid_t pid = 0;
    FixedText<IFNAMSIZ> interface;
    unsigned interface_index = 0;
    bool incoming = false;
  };
  template <typename State>
  explicit PacketLog(State &state, uid_t uid, Direction direction = Direction::outbound) : uid_(uid), direction_(direction), capture_(nullptr, &pcap_close) {
    index_ = LogInterface::create();
    try {
      state.saveLog(index_);
    } catch (...) {
      LogInterface::remove(index_);
      throw;
    }
    std::array<char, 16> name{};
    std::snprintf(name.data(), name.size(), "pflog%u", index_);
    std::array<char, PCAP_ERRBUF_SIZE> error{};
    capture_.reset(pcap_create(name.data(), error.data()));
    if (!capture_) { throw std::runtime_error{error.data()}; }
    if (pcap_set_snaplen(capture_.get(), 65600) != 0 || pcap_set_timeout(capture_.get(), 1) != 0 || pcap_set_immediate_mode(capture_.get(), 1) != 0 || pcap_activate(capture_.get()) < 0 || pcap_datalink(capture_.get()) != DLT_PFLOG || pcap_setnonblock(capture_.get(), 1, error.data()) != 0) {
      throw std::runtime_error{"Cannot capture private PF discovery log"};
    }
    setCloseOnExec(pcap_fileno(capture_.get()));
    bpf_insn instructions[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(Header, uid)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, htonl(uid_), 0, 1),
      BPF_STMT(BPF_RET | BPF_K, 65600),
      BPF_STMT(BPF_RET | BPF_K, 0),
    };
    bpf_program filter{.bf_len = std::size(instructions), .bf_insns = instructions};
    if (pcap_setfilter(capture_.get(), &filter) != 0) { throw std::runtime_error{pcap_geterr(capture_.get())}; }
  }

  unsigned index() const noexcept { return index_; }
  int descriptor() const noexcept { return pcap_get_selectable_fd(capture_.get()); }
  const Metadata &metadata() const noexcept { return metadata_; }

  std::span<Byte> receive() {
    pcap_pkthdr *header;
    const u_char *packet;
    const auto result = pcap_next_ex(capture_.get(), &header, &packet);
    if (result == 0) { return {}; }
    if (result < 0) { throw std::runtime_error{pcap_geterr(capture_.get())}; }
    const auto frame = normalize({packet, header->caplen}, uid_, bytes_, &metadata_, direction_);
    return std::span{bytes_}.first(frame);
  }

  static std::size_t normalize(std::span<const Byte> packet, uid_t uid, std::span<Byte> output, Metadata *metadata = nullptr, Direction direction = Direction::outbound) {
    if (output.size() < sizeof(std::uint32_t) || packet.size() < sizeof(Header)) { return 0; }
    Header header;
    std::memcpy(&header, packet.data(), sizeof(header));
    const bool incoming = header.direction == static_cast<Byte>(PfDirection::incoming);
    const bool outgoing = header.direction == static_cast<Byte>(PfDirection::outgoing);
    if (header.length != offsetof(Header, padding) || !((incoming && allowsIncoming(direction)) || (outgoing && allowsOutgoing(direction))) || header.action != static_cast<Byte>(Action::pass) || header.uid != uid || (header.family != AF_INET && header.family != AF_INET6) || packet.size() - sizeof(Header) > output.size() - sizeof(std::uint32_t)) { return 0; }
    if (metadata) {
      const auto end = std::ranges::find(header.interface, '\0');
      if (end == header.interface.end()) { return 0; }
      metadata->pid = header.pid;
      metadata->incoming = incoming;
      metadata->interface.assign({header.interface.data(), end});
      std::array<char, IFNAMSIZ> name{};
      std::copy(header.interface.begin(), end, name.begin());
      metadata->interface_index = ::if_nametoindex(name.data());
    }
    const auto family = htonl(static_cast<std::uint32_t>(header.family));
    std::memcpy(output.data(), &family, sizeof(family));
    std::copy(packet.begin() + sizeof(Header), packet.end(), output.begin() + sizeof(family));
    return sizeof(family) + packet.size() - sizeof(Header);
  }

private:
  uid_t uid_;
  Direction direction_;
  unsigned index_ = 0;
  std::unique_ptr<pcap_t, decltype(&pcap_close)> capture_;
  std::array<Byte, 65540> bytes_{};
  Metadata metadata_;
};

}
