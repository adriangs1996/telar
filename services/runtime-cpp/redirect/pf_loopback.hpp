#pragma once

#include "../platform/file_descriptor.hpp"
#include "../platform/error.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <fcntl.h>
#include <net/if.h>
#include <span>
#include <stdexcept>
#include <string_view>
#include <sys/ioctl.h>

namespace telar::runtime::redirect {

class LoopbackFlags {
  // Darwin's pfioc_iface layout is absent from the public SDK. Keep this ABI
  // limited to DIOCSETIFFLAG/DIOCCLRIFFLAG and the PFI_IFLAG_SKIP bit on lo0.
  // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pfvar.h
  struct InterfaceRequest {
    char name[IFNAMSIZ]{};
    alignas(8) void *buffer = nullptr;
    alignas(8) int element_size = 0;
    int size = 0;
    int zero = 0;
    int flags = 0;
  };

  static_assert(sizeof(InterfaceRequest) == 40 && offsetof(InterfaceRequest, flags) == 36);
  enum class Operation : unsigned long {
    set_flags = _IOWR('D', 89, InterfaceRequest),
    clear_flags = _IOWR('D', 90, InterfaceRequest),
  };
  static constexpr int skip_flag = 0x0100;

public:
  static void setSkipped(bool skipped) {
    FileDescriptor device{::open("/dev/pf", O_RDWR | O_CLOEXEC | O_NOFOLLOW)};
    if (!device) {
      throw SystemError{"Open PF loopback control"};
    }
    InterfaceRequest request{};
    constexpr std::string_view loopback = "lo0";
    std::copy(loopback.begin(), loopback.end(), request.name);
    request.flags = skip_flag;
    const auto operation = skipped ? Operation::set_flags : Operation::clear_flags;
    if (::ioctl(device.get(), static_cast<unsigned long>(operation), &request) != 0) {
      throw SystemError{"Change PF loopback skip flag"};
    }
  }
};

template <typename Command, typename Flags = LoopbackFlags>
class PfLoopback {
public:
  explicit PfLoopback(Command &command) noexcept : command_(command) {}

  bool skipped() {
    constexpr std::array<std::string_view, 5> arguments{"-v", "-s", "Interfaces", "-i", "lo0"};
    return parse(command_.run(arguments));
  }

  void setSkipped(bool value) {
    Flags::setSkipped(value);
    if (skipped() != value) {
      throw std::runtime_error{"PF loopback skip flag did not change"};
    }
  }

  static bool parse(std::string_view output) {
    while (!output.empty()) {
      const auto newline = output.find('\n');
      auto line = output.substr(0, newline);
      if (line == "lo0" || line.starts_with("lo0 ") || line.starts_with("lo0\t")) {
        line.remove_prefix(3);
        const auto first = line.find_first_not_of(" \t\r");
        if (first == std::string_view::npos) {
          return false;
        }
        line.remove_prefix(first);
        line = line.substr(0, line.find_last_not_of(" \t\r") + 1);
        if (line == "(skip)") {
          return true;
        }
        break;
      }
      if (newline == std::string_view::npos) {
        break;
      }
      output.remove_prefix(newline + 1);
    }
    throw std::runtime_error{"Cannot read PF loopback skip status"};
  }

private:
  Command &command_;
};

}
