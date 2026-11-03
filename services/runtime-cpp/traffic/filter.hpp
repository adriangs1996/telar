#pragma once

#include "protocol.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <memory>
#include <optional>
#include <pcap/pcap.h>

namespace telar::runtime::traffic {

class Filter {
public:
  Filter(const Filter &) = delete;
  Filter &operator=(const Filter &) = delete;

  explicit Filter(std::string_view expression) {
    if (expression.contains('\0')) {
      throw std::invalid_argument{"Traffic filter contains NUL"};
    }
    expression_.assign(expression);

    // Validate syntax before accepting a subscription, including before capture starts.
    if (!expression.empty()) {
      compile(DLT_EN10MB, validation_);
    }
  }

  bool matches(const Event &event) {
    if (event.kind != Kind::packet || expression_.view().empty()) {
      return true;
    }

    for (auto &entry : programs_) {
      if (entry && entry->link_type == event.link_type) {
        return apply(entry->program, event);
      }
    }
    for (auto &entry : programs_) {
      if (!entry) {
        entry.emplace();
        entry->link_type = event.link_type;
        compile(static_cast<int>(event.link_type), entry->program);
        return apply(entry->program, event);
      }
    }
    throw std::runtime_error{"Traffic filter link-type limit reached"};
  }

private:
  struct Program {
    bpf_program value{};
    ~Program() { pcap_freecode(&value); }
  };

  struct Entry {
    std::uint32_t link_type = 0;
    Program program;
  };

  void compile(int link_type, Program &program) {
    const std::unique_ptr<pcap_t, decltype(&pcap_close)> dead{pcap_open_dead(link_type, Limits::packet_bytes), &pcap_close};
    if (!dead) {
      throw std::runtime_error{"Unable to compile traffic filter for link type"};
    }

    std::array<char, Limits::filter_bytes + 1> expression{};
    std::ranges::copy(expression_.view(), expression.begin());
    if (pcap_compile(dead.get(), &program.value, expression.data(), 1, PCAP_NETMASK_UNKNOWN) < 0) {
      throw std::invalid_argument{pcap_geterr(dead.get())};
    }
  }

  static bool apply(const Program &program, const Event &event) noexcept {
    pcap_pkthdr header{};
    header.caplen = static_cast<bpf_u_int32>(event.bytes.size());
    header.len = event.original_bytes;
    return pcap_offline_filter(&program.value, &header, event.bytes.data()) != 0;
  }

  FixedText<Limits::filter_bytes> expression_;
  Program validation_;
  std::array<std::optional<Entry>, Limits::filter_link_types> programs_;
};

}
