#pragma once

#include "../platform/private_tunnel.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <array>
#include <arpa/inet.h>
#include <memory>
#include <pcap/pcap.h>
#include <sys/ioctl.h>

namespace telar::runtime::redirect {

class Discovery {
public:
  Discovery() : injection_(nullptr, &pcap_close) {
    std::array<char, PCAP_ERRBUF_SIZE> error{};
    injection_.reset(pcap_open_live("lo0", 64, 0, 1, error.data()));
    if (!injection_) {
      throw std::runtime_error{error.data()};
    }
    if (pcap_datalink(injection_.get()) != DLT_NULL) {
      throw std::runtime_error{"Loopback injection requires DLT_NULL"};
    }
    const auto descriptor = pcap_fileno(injection_.get());
    setCloseOnExec(descriptor);
    unsigned complete = 1;
    constexpr unsigned long complete_headers = _IOW('B', 117, unsigned int); // Darwin BIOCSHDRCMPLT
    if (::ioctl(descriptor, complete_headers, &complete) != 0) {
      throw SystemError{"Configure complete loopback injection headers"};
    }
    bpf_insn reject = BPF_STMT(BPF_RET | BPF_K, 0);
    bpf_program filter{.bf_len = 1, .bf_insns = &reject};
    if (pcap_setfilter(injection_.get(), &filter) != 0) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

  int descriptor() const noexcept { return tunnel_.descriptor(); }
  std::string_view name() const noexcept { return tunnel_.name(); }

  std::span<Byte> receive(std::span<Byte> bytes) {
    const auto size = ::read(tunnel_.descriptor(), bytes.data(), bytes.size());
    if (size < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return {};
    }
    if (size <= 0) {
      throw SystemError{"Read discovery packet"};
    }
    return bytes.first(static_cast<std::size_t>(size));
  }

  void inject(std::span<Byte> frame) {
    if (frame.size() < sizeof(std::uint32_t)) {
      throw std::invalid_argument{"Truncated discovery frame"};
    }
    std::uint32_t family;
    std::memcpy(&family, frame.data(), sizeof(family));
    family = ntohl(family);
    std::memcpy(frame.data(), &family, sizeof(family));
    // utun uses network byte order; DLT_NULL requires the host-order family.
    const auto count = pcap_inject(injection_.get(), frame.data(), frame.size());
    if (count < 0 || static_cast<std::size_t>(count) != frame.size()) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

private:
  PrivateTunnel tunnel_;
  std::unique_ptr<pcap_t, decltype(&pcap_close)> injection_;
};

}
