module;

#include <array>
#include <optional>
#include <string_view>


#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>
#include "telar_client/serializers/telar_protocol.hpp"
#include <exception>
#include <cstddef>
#include "telar_base/program_identity.hpp"
#include <cerrno>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <sys/types.h>
#include <limits.h>
#include <atomic>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>
#include <charconv>


#include "telar_base/memory/fixed_text.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>


#if defined(__linux__)


#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/uio.h>


#endif

#if defined(__APPLE__)


#include <net/if.h>
#include <net/if_utun.h>
#include <netinet6/in6_var.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>


#endif


#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <net/if.h>
#endif
#if (defined(__APPLE__))
#include <net/if_utun.h>
#endif
#if (defined(__APPLE__))
#include <netinet6/in6_var.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__))
#include <sys/kern_control.h>
#endif
#if (defined(__APPLE__))
#include <sys/socket.h>
#endif
#if (defined(__APPLE__))
#include <sys/sys_domain.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <arpa/inet.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (!(defined(__APPLE__)))
#include <net/if.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/uio.h>
#endif

export module telar.runtime.platform.git_status;

export import telar.platform;


#if defined(__linux__)

export import telar.platform;


#endif

#if defined(__APPLE__)

export import telar.platform;


#endif


#if (defined(__APPLE__))

#endif
#if (!(defined(__APPLE__)))

#endif

// Interface: platform/git_observation_policy.cppm
export {

}

// Interface: platform/git_repository.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class GitRepository {
public:
  using Clock = std::chrono::steady_clock;

  inline explicit GitRepository(Memory &memory, std::string_view root, Clock::time_point deadline, const std::atomic<bool> &cancelled)
      : memory_(memory),
        root_(root),
        deadline_(deadline),
        output_(memory, maximum_output, &cancelled),
        overrides_(AllocatorRef<String<Memory>, Memory>{memory}) {
    if (execute({"config", "--show-scope", "-z", "--get-regexp", "^(filter\\.|extensions\\.partialclone$|remote\\..*\\.(promisor|partialclonefilter|uploadpack)$)"}) > 1) {
      reject();
    }
    const auto facts = GitRepositoryFacts::parse(output_.text());
    if (!facts) {
      reject();
    }

    for (std::size_t index = 0; index < facts->driver_count; ++index) {
      for (const auto suffix : {".clean=", ".smudge=", ".process="}) {
        overrides_.emplace_back("filter.", AllocatorRef<char, Memory>{memory});
        overrides_.back() += facts->drivers[index];
        overrides_.back() += suffix;
      }
    }
    if (facts->may_fetch) {
      verifyLazyFetchControl();
    }
  }

  inline std::string_view run(std::initializer_list<std::string_view> arguments, bool retain_prefix = false, std::size_t maximum_bytes = maximum_output) {
    if (execute(arguments, retain_prefix) != 0) {
      reject();
    }
    auto text = output_.text();
    if (text.size() > maximum_bytes) {
      reject();
    }
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
      text.remove_suffix(1);
    }
    return text;
  }

  inline int execute(std::initializer_list<std::string_view> arguments, bool retain_prefix = false) {
    return withCommand(arguments, [&](auto &command) { return output_.run(command, deadline_, retain_prefix); });
  }

  template <typename Consumer>
  inline int stream(std::initializer_list<std::string_view> arguments, Consumer &&consume, Clock::time_point deadline = Clock::time_point::max()) {
    return withCommand(arguments, [&](auto &command) { return output_.stream(command, deadline, consume); });
  }

private:
  inline void verifyLazyFetchControl() {
    const auto version = run({"version"});
    constexpr std::string_view prefix = "git version ";
    if (!version.starts_with(prefix)) {
      reject();
    }

    const auto number = version.substr(prefix.size());
    unsigned major = 0;
    const auto parsed = std::from_chars(number.data(), number.data() + number.size(), major);
    if (parsed.ec != std::errc{} || parsed.ptr == number.data() + number.size() || *parsed.ptr != '.') {
      reject();
    }

    unsigned minor = 0;
    const auto subversion = std::from_chars(parsed.ptr + 1, number.data() + number.size(), minor);
    constexpr unsigned lazy_fetch_major = 2;
    constexpr unsigned lazy_fetch_minor = 45;
    if (subversion.ec != std::errc{} || major < lazy_fetch_major || (major == lazy_fetch_major && minor < lazy_fetch_minor)) {
      reject();
    }
  }

  template <typename Operation>
  inline int withCommand(std::initializer_list<std::string_view> arguments, Operation &&operation) {
    std::array<std::string_view, 128> complete;
    std::size_t count = 0;
    for (const auto argument : git_observation_options) {
      complete[count++] = argument;
    }
    for (const auto &override : overrides_) {
      complete[count++] = "-c";
      complete[count++] = override;
    }
    if (arguments.size() > complete.size() - count) {
      reject();
    }
    for (const auto argument : arguments) {
      complete[count++] = argument;
    }
    Command command{memory_, Launch{.cwd = root_, .arguments = std::span{complete}.first(count)}, CommandPurpose::administration};
    command.removeEnvironmentPrefix("GIT_");
    command.setEnvironment("GIT_OPTIONAL_LOCKS", "0");
    command.setEnvironment("GIT_NO_LAZY_FETCH", "1");
    command.setEnvironment("GIT_TERMINAL_PROMPT", "0");
    command.setEnvironment("LC_ALL", "C");
    return operation(command);
  }

  [[noreturn]] inline static void reject() {
    throw RequestError{FailureCode::invalid_request, "Git observation unavailable"};
  }

  static constexpr std::size_t maximum_output = 64 * 1024;
  Memory &memory_;
  std::string_view root_;
  Clock::time_point deadline_;
  CommandOutput<Memory> output_;
  Vector<String<Memory>, Memory> overrides_;
};

template <Allocator Memory>
GitRepository(Memory &memory, std::string_view root, typename GitRepository<Memory>::Clock::time_point deadline, const std::atomic<bool> &cancelled) -> GitRepository<Memory>;

}
}

// Interface: platform/git_status.cppm
export {
namespace telar::runtime {

inline constexpr auto git_status_timeout = std::chrono::seconds{10};

struct GitStatus {
  FixedText<4096> branch;
  std::optional<bool> dirty;
  bool present = false;
  bool timed_out = false;
};

template <ConcurrentAllocator Memory>
class GitStatusReader {
public:
  using Clock = std::chrono::steady_clock;

  inline explicit GitStatusReader(Memory &memory) noexcept
      : memory_(memory) {}

  inline GitStatus read(std::string_view root) noexcept {
    GitStatus result;
    GitHead head;
    const auto branch = head.read(root);
    if (!branch) {
      return result;
    }

    result.present = true;
    result.branch.assign(*branch);
    const auto deadline = Clock::now() + git_status_timeout;
    try {
      GitRepository git{memory_, root, deadline, cancelled_};
      bool printed = false;
      const auto status = git.stream({"status", "--porcelain", "--no-renames", "--ignore-submodules=all"}, [&](std::span<const Byte> bytes) {
        printed |= !bytes.empty();
        return true; }, deadline);
      if (status == 0) {
        result.dirty = printed;
      }
    } catch (const RequestError &error) {
      result.timed_out = error.code() == FailureCode::resource_limit && Clock::now() >= deadline;
    } catch (...) {
    }

    return result;
  }

  inline void stop() noexcept {
    cancelled_ = true;
  }

private:
  Memory &memory_;
  std::atomic<bool> cancelled_{false};
};

}
}

#if defined(__linux__)
// Interface: platform/linux/private_tunnel.cppm
export {
namespace telar::runtime {

class PrivateTunnel {
public:
  inline PrivateTunnel() : tunnel_(::open("/dev/net/tun", O_RDWR | O_CLOEXEC | O_NONBLOCK)) {
    if (!tunnel_) {
      throw SystemError{"Open private tunnel"};
    }

    ifreq request{};
    constexpr std::string_view pattern = "telar%d";
    std::ranges::copy(pattern, request.ifr_name);
    request.ifr_flags = IFF_TUN;
    if (::ioctl(tunnel_.get(), TUNSETIFF, &request) != 0) {
      throw SystemError{"Create private tunnel"};
    }
    name_.assign(request.ifr_name);
    index_ = ::if_nametoindex(request.ifr_name);
    if (index_ == 0) {
      throw SystemError{"Read private tunnel index"};
    }

    const FileDescriptor configuration{::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &request) != 0) {
      throw SystemError{"Read private tunnel flags"};
    }
    request.ifr_flags |= IFF_UP;
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &request) != 0) {
      throw SystemError{"Enable private tunnel"};
    }
  }

  inline ssize_t write(std::span<const std::uint8_t> bytes) const noexcept {
    constexpr std::size_t family_bytes = sizeof(std::uint32_t);
    if (bytes.size() < family_bytes) {
      errno = EINVAL;
      return -1;
    }

    std::uint32_t family;
    std::memcpy(&family, bytes.data(), sizeof(family));
    family = ntohl(family);
    if (family != AF_INET && family != AF_INET6) {
      errno = EAFNOSUPPORT;
      return -1;
    }

    tun_pi header{};
    header.proto = htons(family == AF_INET ? ETH_P_IP : ETH_P_IPV6);
    const auto payload = bytes.subspan(family_bytes);
    const std::array buffers{iovec{&header, sizeof(header)}, iovec{const_cast<std::uint8_t *>(payload.data()), payload.size()}};
    return ::writev(tunnel_.get(), buffers.data(), buffers.size());
  }

  inline int descriptor() const noexcept { return tunnel_.get(); }
  inline unsigned index() const noexcept { return index_; }
  inline std::string_view name() const noexcept { return name_.view(); }

private:
  FileDescriptor tunnel_;
  FixedText<IFNAMSIZ> name_;
  unsigned index_ = 0;
};

}
}

#endif

#if defined(__APPLE__)
// Interface: platform/macos/private_tunnel.cppm
export {
namespace telar::runtime {

class PrivateTunnel {
public:
  inline PrivateTunnel() : tunnel_(::socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)) {
    if (!tunnel_) {
      throw SystemError{"Open redirect discovery tunnel"};
    }
    setCloseOnExec(tunnel_.get());
    ctl_info control{};
    constexpr std::string_view name = UTUN_CONTROL_NAME;
    std::copy(name.begin(), name.end(), control.ctl_name);
    if (::ioctl(tunnel_.get(), CTLIOCGINFO, &control) != 0) {
      throw SystemError{"Find redirect discovery control"};
    }
    sockaddr_ctl address{};
    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = control.ctl_id;
    if (::connect(tunnel_.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
      throw SystemError{"Create redirect discovery interface"};
    }
    std::array<char, IFNAMSIZ> interface{};
    socklen_t length = interface.size();
    if (::getsockopt(tunnel_.get(), SYSPROTO_CONTROL, UTUN_OPT_IFNAME, interface.data(), &length) != 0 || interface.back() != '\0') {
      throw SystemError{"Read redirect discovery interface"};
    }
    name_.assign(interface.data());
    index_ = ::if_nametoindex(interface.data());
    if (index_ == 0) {
      throw SystemError{"Read redirect discovery interface index"};
    }
    FileDescriptor configuration{::socket(AF_INET, SOCK_DGRAM, 0)};
    ifreq flags{};
    std::copy(name_.view().begin(), name_.view().end(), flags.ifr_name);
    if (!configuration || ::ioctl(configuration.get(), SIOCGIFFLAGS, &flags) != 0) {
      throw SystemError{"Read discovery interface flags"};
    }
    flags.ifr_flags |= IFF_UP;
    if (::ioctl(configuration.get(), SIOCSIFFLAGS, &flags) != 0) {
      throw SystemError{"Enable redirect discovery interface"};
    }
    // utun creation does not attach IP protocol handlers. PF's ifnet_output
    // needs them even though this interface has no configured IP addresses.
    constexpr unsigned long attach_ipv4 = _IOWR('i', 80, ifreq); // SIOCPROTOATTACH
    if (::ioctl(configuration.get(), attach_ipv4, &flags) != 0 && errno != EEXIST) {
      throw SystemError{"Attach discovery IPv4 protocol"};
    }
    FileDescriptor ipv6{::socket(AF_INET6, SOCK_DGRAM, 0)};
    in6_aliasreq request{};
    std::copy(name_.view().begin(), name_.view().end(), request.ifra_name);
    constexpr unsigned long attach_ipv6 = _IOWR('i', 110, in6_aliasreq); // SIOCPROTOATTACH_IN6
    if (!ipv6 || (::ioctl(ipv6.get(), attach_ipv6, &request) != 0 && errno != EEXIST)) {
      throw SystemError{"Attach discovery IPv6 protocol"};
    }
    setNonblocking(tunnel_.get());
  }

  inline ssize_t write(std::span<const std::uint8_t> bytes) const noexcept { return ::write(tunnel_.get(), bytes.data(), bytes.size()); }

  inline int descriptor() const noexcept { return tunnel_.get(); }
  inline unsigned index() const noexcept { return index_; }
  inline std::string_view name() const noexcept { return name_.view(); }

private:
  FileDescriptor tunnel_;
  FixedText<IFNAMSIZ> name_;
  unsigned index_ = 0;
};

}
}

#endif

// Interface: platform/private_tunnel.cppm
export {
#if defined(__APPLE__)
#else
#endif
}
