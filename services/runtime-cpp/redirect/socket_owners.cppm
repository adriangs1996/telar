module;
#include <concepts>
#include <type_traits>
#include <cstdio>
#include <utility>
#include <cstdlib>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <variant>
#include <bit>
#include <stdlib.h>

#include <stdexcept>
#include <string_view>
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <optional>
#include <sys/socket.h>
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <cstddef>
#include <charconv>
#include <cerrno>
#include <exception>
#include <ifaddrs.h>
#include <memory>
#include <net/if.h>

#include <csignal>
#include <netinet/tcp.h>
#include <sys/types.h>
#include <limits.h>
#include <chrono>
#include <poll.h>

#include <span>
#include <net/if_dl.h>
#include <net/route.h>

#include <limits>
#include <unistd.h>

#if defined(__APPLE__)

#include <utility>
#include <netinet/in_pcb.h>
#include <netinet/tcp_fsm.h>
#include <netinet/tcp_var.h>
#include <sys/socketvar.h>
#include <sys/sysctl.h>

#endif

#if defined(__linux__)

#include <fcntl.h>

#endif

#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <fcntl.h>
#endif
#if (!(defined(__APPLE__)))
#include <dirent.h>
#endif
#if (!(defined(__APPLE__)))
#include <cstdio>
#endif

#if defined(__APPLE__)

#include <bit>
#include <sys/stat.h>
#include <sys/un.h>
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
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <fcntl.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/uio.h>
#endif
#include <pcap/pcap.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <cstdlib>
#include <sys/file.h>
#include <thread>
#include <sys/sockio.h>
#include <sys/uio.h>
#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <dirent.h>
#endif
#if (!(defined(__APPLE__)))
#include <cstdio>
#endif

#endif

export module telar.runtime.redirect.socket_owners;

export import telar.runtime.redirect.pf_rules;
export import telar.runtime.redirect.ingress;
export import telar.platform;


export import telar.runtime.proxy.relay_direction;


export import telar.runtime.platform.process_probe;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;


#if defined(__APPLE__)

export import telar.runtime.redirect.ingress;
export import telar.base.memory;
export import telar.platform;


#endif

#if defined(__linux__)

export import telar.runtime.redirect.pf_rules;
export import telar.platform;


#endif


#if (!(defined(__APPLE__)))

#endif
#if (!(defined(__APPLE__)))
export import telar.platform;
#endif


#if defined(__APPLE__)

export import telar.runtime.traffic.capture;

export import telar.runtime.redirect.record;
export import telar.runtime.redirect.pf_rules;


#endif

// Interface: redirect/local_addresses.cppm
export {
namespace telar::runtime::redirect {

class LocalAddresses {
public:
  inline LocalAddresses() : addresses_(nullptr, &freeifaddrs) {
    ifaddrs *addresses = nullptr;
    if (::getifaddrs(&addresses) != 0) { throw SystemError{"Read local redirect addresses"}; }
    addresses_.reset(addresses);
  }

  inline bool contains(const Target &target) const noexcept {
    for (auto *interface = addresses_.get(); interface; interface = interface->ifa_next) {
      if (!interface->ifa_addr || !(interface->ifa_flags & IFF_UP) || (interface->ifa_flags & IFF_LOOPBACK) || interface->ifa_addr->sa_family != target.endpoint.storage.ss_family) { continue; }
      if (interface->ifa_addr->sa_family == AF_INET) {
        const auto &local = reinterpret_cast<const sockaddr_in &>(*interface->ifa_addr).sin_addr;
        const auto &selected = reinterpret_cast<const sockaddr_in &>(target.endpoint.storage).sin_addr;
        if (local.s_addr == selected.s_addr) { return true; }
      } else if (interface->ifa_addr->sa_family == AF_INET6) {
        const auto &local = reinterpret_cast<const sockaddr_in6 &>(*interface->ifa_addr).sin6_addr;
        const auto &selected = reinterpret_cast<const sockaddr_in6 &>(target.endpoint.storage).sin6_addr;
        if (std::memcmp(&local, &selected, sizeof(local)) == 0) { return true; }
      }
    }
    return false;
  }

  inline static std::array<bool, Target::maximum_targets> selection(std::span<const Target> targets, Direction direction) {
    std::array<bool, Target::maximum_targets> selected{};
    if (targets.size() > selected.size() || (!allowsIncoming(direction) && !allowsOutgoing(direction))) { throw std::invalid_argument{"Invalid redirect address scope"}; }
    if (!allowsIncoming(direction)) { return selected; }
    const LocalAddresses local;
    bool incoming = false;
    for (std::size_t index = 0; index < targets.size(); ++index) {
      selected[index] = local.contains(targets[index]);
      if (direction == Direction::inbound && !selected[index]) { throw std::invalid_argument{"Incoming redirect targets must be assigned to an active non-loopback interface"}; }
      incoming |= selected[index];
    }
    if (!incoming) { throw std::invalid_argument{"Incoming redirection requires a local destination"}; }
    return selected;
  }

private:
  std::unique_ptr<ifaddrs, decltype(&freeifaddrs)> addresses_;
};

}
}

// Interface: redirect/pf_command.cppm
export {
namespace telar::runtime::redirect {

template <Allocator Memory>
class PfCommand {
public:
  inline explicit PfCommand(Memory &memory) noexcept : memory_(memory) {}

  inline String<Memory> run(std::span<const std::string_view> arguments, std::string_view input = {}) {
    constexpr std::size_t maximum_arguments = 12;
    if (arguments.size() >= maximum_arguments) {
      throw std::invalid_argument{"Too many PF command arguments"};
    }
    std::array<std::string_view, maximum_arguments> argv{};
    argv[0] = "/sbin/pfctl";
    std::ranges::copy(arguments, argv.begin() + 1);
    const std::array<EnvironmentEntry, 2> environment{{{"LC_ALL", "C"}, {"PATH", "/usr/bin:/bin:/usr/sbin:/sbin"}}};
    Command command{memory_, Launch{.cwd = "/", .arguments = std::span{argv}.first(arguments.size() + 1), .environment_mode = EnvironmentMode::replace, .environment = environment}, CommandPurpose::administration};
    PipeProcess process{command.specification({})};
    String<Memory> output{AllocatorRef<char, Memory>{memory_}};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    bool out_open = true;
    bool err_open = true;
    while (out_open || err_open || !process.reap()) {
      if (input.empty()) {
        process.closeInput();
      }
      std::array<pollfd, 3> descriptors{{{process.input(), POLLOUT, 0}, {out_open ? process.output() : -1, POLLIN, 0}, {err_open ? process.error() : -1, POLLIN, 0}}};
      constexpr int poll_ms = 20;
      if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
        throw SystemError{"Poll PF administration command"};
      }
      if (!input.empty() && (descriptors[0].revents & POLLOUT)) {
        const auto written = ::write(process.input(), input.data(), input.size());
        if (written > 0) {
          input.remove_prefix(static_cast<std::size_t>(written));
        } else if (written == 0 || !socketWouldBlock(errno)) {
          throw SystemError{"Write PF rules"};
        }
      }
      drain(process.output(), out_open, output);
      drain(process.error(), err_open, output);
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"PF administration command timed out", ETIMEDOUT};
      }
    }
    const auto status = *process.reap();
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw std::runtime_error{std::string{output.data(), output.size()}};
    }
    return output;
  }

private:
  inline static void drain(int descriptor, bool &open, String<Memory> &output) {
    if (!open) {
      return;
    }
    std::array<char, 4096> bytes{};
    const auto count = ::read(descriptor, bytes.data(), bytes.size());
    if (count == 0) {
      open = false;
    } else if (count > 0) {
      constexpr std::size_t output_limit = 256 * 1024;
      if (output.size() + static_cast<std::size_t>(count) > output_limit) {
        throw std::runtime_error{"PF command output exceeds its limit"};
      }
      output.append(bytes.data(), static_cast<std::size_t>(count));
    } else if (!socketWouldBlock(errno)) {
      throw SystemError{"Read PF command output"};
    }
  }

  Memory &memory_;
};

}
}

// Interface: redirect/pf_session.cppm
export {
namespace telar::runtime::redirect {

template <typename Command, typename State, typename Loopback, Allocator Memory>
class PfSession {
public:
  inline explicit PfSession(Command &command, State &state, const PfIdentity<Memory> &identity, Loopback &loopback) noexcept
      : command_(command), state_(state), identity_(identity), loopback_(loopback) {}

  inline ~PfSession() {
    try {
      stop();
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar redirect cleanup: %s; retry traffic redirect-cleanup\n", error.what());
    }
  }

  PfSession(const PfSession &) = delete;
  PfSession &operator=(const PfSession &) = delete;

  inline void recover() {
    token_ = state_.load();
    stop();
  }

  inline void start(std::string_view rules) {
    recover();
    const auto filters = run({"-sr"});
    const auto translations = run({"-sn"});
    if (!std::string_view{filters}.contains("anchor \"com.apple/*\"") || !std::string_view{translations}.contains("rdr-anchor \"com.apple/*\"")) {
      throw std::runtime_error{"PF must expose com.apple/* filter and rdr anchors; system rules were not changed"};
    }
    run({"-n", "-a", identity_.anchor, "-f", "-"}, rules);
    token_ = parseToken(run({"-E"}));
    state_.save(*token_);
    run({"-a", identity_.anchor, "-f", "-"}, rules);
    loopback_.acquire();
  }

  inline void stop() {
    if (!token_) {
      return;
    }
    // macOS only supports host/network state kills. Leave existing states to
    // expire rather than killing unrelated connections with a broader match.
    std::exception_ptr failure;
    for (const auto kind : {"rules", "nat"}) {
      try {
        run({"-a", identity_.anchor, "-F", kind});
      } catch (...) {
        if (!failure) {
          failure = std::current_exception();
        }
      }
    }
    if (failure) {
      // Keep the enable reference and recovery record until both rule sets
      // have been removed, including when another service already enabled PF.
      std::rethrow_exception(failure);
    }
    loopback_.release();
    std::array<char, 32> value{};
    const auto result = std::to_chars(value.data(), value.data() + value.size(), *token_);
    if (*token_ != 0) {
      run({"-X", std::string_view{value.data(), static_cast<std::size_t>(result.ptr - value.data())}});
      token_ = 0;
      state_.save(0);
    }
    state_.clear();
    token_.reset();
  }

  inline static std::uint64_t parseToken(std::string_view output) {
    while (!output.empty()) {
      const auto newline = output.find('\n');
      auto line = output.substr(0, newline);
      if (line.starts_with("Token")) {
        const auto colon = line.find(':');
        if (colon != std::string_view::npos) {
          line.remove_prefix(colon + 1);
          const auto first = line.find_first_not_of(" \t");
          if (first != std::string_view::npos) {
            line.remove_prefix(first);
            line = line.substr(0, line.find_last_not_of(" \t\r") + 1);
            std::uint64_t token = 0;
            const auto result = std::from_chars(line.data(), line.data() + line.size(), token);
            if (result.ec == std::errc{} && result.ptr == line.data() + line.size() && token != 0) {
              return token;
            }
          }
        }
      }
      if (newline == std::string_view::npos) {
        break;
      }
      output.remove_prefix(newline + 1);
    }
    throw std::runtime_error{"PF did not return an enable-reference token"};
  }

  inline void replace(std::string_view rules) {
    if (!token_) {
      throw std::runtime_error{"Redirect session is not enabled"};
    }
    run({"-a", identity_.anchor, "-f", "-"}, rules);
  }

private:
  inline auto run(std::initializer_list<std::string_view> arguments, std::string_view input = {}) {
    return command_.run(std::span{arguments.begin(), arguments.size()}, input);
  }

  Command &command_;
  State &state_;
  const PfIdentity<Memory> &identity_;
  Loopback &loopback_;
  std::optional<std::uint64_t> token_;
};

}
}

// Interface: redirect/process_token.cppm
export {
namespace telar::runtime::redirect {

class ProcessToken {
public:
  static constexpr std::size_t maximum_bytes = 64;

  inline static ProcessIdentity parse(std::string_view value) {
    const auto separator = value.find('@');
    const auto pid = number(value.substr(0, separator));
    if (pid == 0 || pid > INT32_MAX) { throw std::invalid_argument{"Invalid selected process PID"}; }
    ProcessIdentity process{.pid = static_cast<pid_t>(pid)};
    if (separator == std::string_view::npos) { return process; }
    value.remove_prefix(separator + 1);
    const auto dot = value.find('.');
    if (dot == std::string_view::npos) { throw std::invalid_argument{"Process identity requires creation seconds and microseconds"}; }
    process.started_seconds = number(value.substr(0, dot));
    process.started_microseconds = number(value.substr(dot + 1));
    if (process.started_seconds == 0 || process.started_microseconds >= 1000000) { throw std::invalid_argument{"Invalid process creation time"}; }
    return process;
  }

  inline static FixedText<maximum_bytes> format(const ProcessIdentity &process) {
    if (process.pid <= 0 || process.started_seconds == 0 || process.started_microseconds >= 1000000) { throw std::invalid_argument{"Process identity is not pinned"}; }
    std::array<char, maximum_bytes> text;
    const auto count = std::snprintf(text.data(), text.size(), "%d@%llu.%06llu", process.pid, static_cast<unsigned long long>(process.started_seconds), static_cast<unsigned long long>(process.started_microseconds));
    if (count <= 0 || static_cast<std::size_t>(count) >= text.size()) { throw std::invalid_argument{"Process identity is too long"}; }
    FixedText<maximum_bytes> result;
    result.assign({text.data(), static_cast<std::size_t>(count)});
    return result;
  }

private:
  inline static std::uint64_t number(std::string_view value) {
    std::uint64_t result;
    const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
    if (value.empty() || parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size()) { throw std::invalid_argument{"Invalid selected process identity"}; }
    return result;
  }
};

}
}

#if defined(__APPLE__)
// Interface: redirect/socket_accounts.cppm
export {
namespace telar::runtime::redirect {

template <Allocator Memory>
class SocketAccounts {
public:
  inline explicit SocketAccounts(Memory &memory) noexcept : memory_(memory) {}

  inline void validate() {
    refresh();
    decode(snapshot_->bytes().first(size_), {}, {});
  }

  inline std::optional<uid_t> peer(int descriptor) {
    sockaddr_storage local{}, remote{};
    socklen_t length = sizeof(local);
    if (::getsockname(descriptor, reinterpret_cast<sockaddr *>(&local), &length) != 0) { throw SystemError{"Read origin socket identity"}; }
    length = sizeof(remote);
    if (::getpeername(descriptor, reinterpret_cast<sockaddr *>(&remote), &length) != 0) { throw SystemError{"Read origin peer identity"}; }
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
      refresh();
      if (const auto account = decode(snapshot_->bytes().first(size_), local, remote)) { return account; }
      if (attempt != 2) { ::poll(nullptr, 0, 1); }
    }
    return {};
  }

  inline static std::optional<uid_t> decode(std::span<const Byte> bytes, const sockaddr_storage &local, const sockaddr_storage &peer) {
    if (bytes.size() < sizeof(xinpgen)) { throw EncodingError{"Incomplete TCP account snapshot"}; }
    xinpgen header;
    std::memcpy(&header, bytes.data(), sizeof(header));
    if (header.xig_len != sizeof(header)) { throw EncodingError{"Unsupported TCP account snapshot header"}; }
    if (bytes.size() == sizeof(header) && header.xig_count == 0) { return {}; }
    if (bytes.size() < 2 * sizeof(header)) { throw EncodingError{"Incomplete TCP account snapshot"}; }
    bytes = bytes.subspan(sizeof(header));
    std::optional<uid_t> account;
    while (bytes.size() > sizeof(xinpgen)) {
      std::uint32_t length;
      std::memcpy(&length, bytes.data(), sizeof(length));
      if (length != sizeof(xtcpcb64) || length > bytes.size() - sizeof(xinpgen)) { throw EncodingError{"Unsupported TCP account record"}; }
      xtcpcb64 entry;
      std::memcpy(&entry, bytes.data(), sizeof(entry));
      const auto &socket = entry.xt_inpcb.xi_socket;
      // Darwin's conversion leaves xi_len zero; the outer TCP record bounds
      // and the socket's own length still identify the supported SDK layout.
      if ((entry.xt_inpcb.xi_len != 0 && entry.xt_inpcb.xi_len != sizeof(xinpcb64)) || (socket.xso_protocol == IPPROTO_TCP && socket.xso_len != sizeof(xsocket64))) { throw EncodingError{"Unsupported TCP socket account layout"}; }
      if (entry.t_state >= TCPS_SYN_RECEIVED && socket.so_type == SOCK_STREAM && socket.xso_protocol == IPPROTO_TCP && matches(entry.xt_inpcb, local, peer)) {
        if (account && *account != socket.so_uid) { throw EncodingError{"Ambiguous TCP peer account"}; }
        account = socket.so_uid;
      }
      bytes = bytes.subspan(length);
    }
    if (bytes.size() != sizeof(xinpgen)) { throw EncodingError{"Incomplete TCP account snapshot footer"}; }
    std::memcpy(&header, bytes.data(), sizeof(header));
    if (header.xig_len != sizeof(header)) { throw EncodingError{"Unsupported TCP account snapshot footer"}; }
    return account;
  }

private:
  inline void refresh() {
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
      std::size_t needed = 0;
      if (::sysctlbyname("net.inet.tcp.pcblist64", nullptr, &needed, nullptr, 0) != 0) { throw SystemError{"Query TCP account snapshot"}; }
      if (needed < 2 * sizeof(xinpgen) || needed > maximum_bytes) { throw SystemError{"TCP account snapshot exceeds its bound", ENOSPC}; }
      if (!snapshot_ || snapshot_->bytes().size() < needed) { snapshot_.emplace(memory_, std::min(maximum_bytes, needed + needed / 4 + sizeof(xtcpcb64))); }
      size_ = snapshot_->bytes().size();
      if (::sysctlbyname("net.inet.tcp.pcblist64", snapshot_->bytes().data(), &size_, nullptr, 0) == 0) { return; }
      if (errno != ENOMEM && errno != EINTR) { throw SystemError{"Read TCP account snapshot"}; }
    }
    throw SystemError{"TCP account snapshot changed repeatedly", EAGAIN};
  }

  inline static bool matches(const xinpcb64 &pcb, const sockaddr_storage &local, const sockaddr_storage &peer) noexcept {
    if (local.ss_family != peer.ss_family) { return false; }
    if (local.ss_family == AF_INET && (pcb.inp_vflag & INP_IPV4)) {
      const auto &origin = reinterpret_cast<const sockaddr_in &>(local);
      const auto &server = reinterpret_cast<const sockaddr_in &>(peer);
      return pcb.inp_lport == server.sin_port && pcb.inp_fport == origin.sin_port && pcb.inp_laddr.s_addr == server.sin_addr.s_addr && pcb.inp_faddr.s_addr == origin.sin_addr.s_addr;
    }
    if (local.ss_family == AF_INET6 && (pcb.inp_vflag & INP_IPV6)) {
      const auto &origin = reinterpret_cast<const sockaddr_in6 &>(local);
      const auto &server = reinterpret_cast<const sockaddr_in6 &>(peer);
      return pcb.inp_lport == server.sin6_port && pcb.inp_fport == origin.sin6_port && std::memcmp(&pcb.inp_dependladdr.inp6_local, &server.sin6_addr, sizeof(in6_addr)) == 0 && std::memcmp(&pcb.inp_dependfaddr.inp6_foreign, &origin.sin6_addr, sizeof(in6_addr)) == 0;
    }
    return false;
  }

  static constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;
  Memory &memory_;
  std::optional<SensitiveAllocation<Memory>> snapshot_;
  std::size_t size_ = 0;
};

}
}

#endif

#if defined(__linux__)
// Interface: redirect/linux/tcp_table.cppm
export {
namespace telar::runtime::redirect {

struct LinuxTcpSocket {
  sockaddr_storage local{};
  sockaddr_storage remote{};
  uid_t user = 0;
  std::uint64_t inode = 0;
  unsigned state = 0;

  inline bool matches(const Target &source, const Target &destination) const noexcept {
    return endpointMatches(local, source.endpoint.storage) && endpointMatches(remote, destination.endpoint.storage);
  }

  inline static std::optional<LinuxTcpSocket> parse(std::string_view line, int family) noexcept {
    constexpr std::size_t required_fields = 10;
    std::array<std::string_view, required_fields> fields;
    for (auto &field : fields) {
      const auto first = line.find_first_not_of(" \t");
      if (first == std::string_view::npos) {
        return std::nullopt;
      }
      line.remove_prefix(first);
      const auto separator = line.find_first_of(" \t");
      field = line.substr(0, separator);
      line = separator == std::string_view::npos ? std::string_view{} : line.substr(separator);
    }

    LinuxTcpSocket socket;
    if (!endpoint(fields[1], family, socket.local) || !endpoint(fields[2], family, socket.remote) || !number(fields[3], socket.state, 16) || !number(fields[7], socket.user, 10) || !number(fields[9], socket.inode, 10)) {
      return std::nullopt;
    }
    return socket;
  }

private:
  template <typename Integer>
  inline static bool number(std::string_view input, Integer &output, int base) noexcept {
    const auto parsed = std::from_chars(input.data(), input.data() + input.size(), output, base);
    return parsed.ec == std::errc{} && parsed.ptr == input.data() + input.size();
  }

  inline static bool endpoint(std::string_view input, int family, sockaddr_storage &output) noexcept {
    constexpr std::size_t word_digits = sizeof(std::uint32_t) * 2;
    const auto address_digits = family == AF_INET ? word_digits : word_digits * 4;
    if (input.size() != address_digits + 1 + sizeof(std::uint16_t) * 2 || input[address_digits] != ':') {
      return false;
    }

    std::uint16_t port = 0;
    if (!number(input.substr(address_digits + 1), port, 16)) {
      return false;
    }
    std::array<std::uint32_t, 4> words{};
    for (std::size_t index = 0; index < address_digits / word_digits; ++index) {
      if (!number(input.substr(index * word_digits, word_digits), words[index], 16)) {
        return false;
      }
    }

    if (family == AF_INET) {
      auto &address = reinterpret_cast<sockaddr_in &>(output);
      address.sin_family = AF_INET;
      address.sin_port = htons(port);
      std::memcpy(&address.sin_addr, words.data(), sizeof(address.sin_addr));
    } else {
      auto &address = reinterpret_cast<sockaddr_in6 &>(output);
      address.sin6_family = AF_INET6;
      address.sin6_port = htons(port);
      std::memcpy(&address.sin6_addr, words.data(), sizeof(address.sin6_addr));
    }
    return true;
  }

  inline static bool endpointMatches(const sockaddr_storage &left, const sockaddr_storage &right) noexcept {
    if (left.ss_family != right.ss_family) {
      return false;
    }
    if (left.ss_family == AF_INET) {
      const auto &actual = reinterpret_cast<const sockaddr_in &>(left);
      const auto &expected = reinterpret_cast<const sockaddr_in &>(right);
      return actual.sin_port == expected.sin_port && actual.sin_addr.s_addr == expected.sin_addr.s_addr;
    }
    const auto &actual = reinterpret_cast<const sockaddr_in6 &>(left);
    const auto &expected = reinterpret_cast<const sockaddr_in6 &>(right);
    return actual.sin6_port == expected.sin6_port && std::memcmp(&actual.sin6_addr, &expected.sin6_addr, sizeof(in6_addr)) == 0;
  }
};

template <typename Visitor>
void visitLinuxTcpSockets(Visitor &&visit) {
  constexpr std::array families{AF_INET, AF_INET6};
  constexpr std::size_t read_capacity = 4096;
  constexpr std::size_t maximum_line_bytes = 1024;
  constexpr std::size_t maximum_entries = 65536;
  for (const auto family : families) {
    FileDescriptor file{::open(family == AF_INET ? "/proc/net/tcp" : "/proc/net/tcp6", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
    if (!file) {
      if (family == AF_INET6 && errno == ENOENT) {
        continue;
      }
      throw SystemError{"Open TCP socket table"};
    }

    std::array<char, read_capacity> buffer;
    std::array<char, maximum_line_bytes> line;
    std::size_t length = 0;
    std::size_t entries = 0;
    bool header = true;
    for (;;) {
      const auto count = ::read(file.get(), buffer.data(), buffer.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        throw SystemError{"Read TCP socket table"};
      }
      if (count == 0) {
        if (length != 0) {
          throw SystemError{"Truncated TCP socket table", EINVAL};
        }
        break;
      }

      for (const auto byte : std::span{buffer}.first(static_cast<std::size_t>(count))) {
        if (byte != '\n') {
          if (length == line.size()) {
            throw SystemError{"TCP socket record exceeds its limit", EOVERFLOW};
          }
          line[length++] = byte;
          continue;
        }
        if (header) {
          header = false;
        } else {
          if (++entries > maximum_entries) {
            throw SystemError{"TCP socket table exceeds its limit", EOVERFLOW};
          }
          const auto socket = LinuxTcpSocket::parse({line.data(), length}, family);
          if (!socket) {
            throw SystemError{"Invalid TCP socket record", EINVAL};
          }
          if (!visit(*socket)) {
            return;
          }
        }
        length = 0;
      }
    }
  }
}

}
}

#endif

// Interface: redirect/socket_owners.cppm
export {
#if defined(__APPLE__)
#endif

namespace telar::runtime::redirect {

class SocketOwners {
public:
  static constexpr std::size_t maximum_processes = 16;
  static constexpr std::size_t maximum_descriptors = 4096;

  struct Result {
    std::optional<ProcessIdentity> process;
    bool complete = true;
  };

  inline explicit SocketOwners(uid_t uid, std::span<const ProcessIdentity> selected) : inspector_(builtin_manifests, uid) {
    if (selected.size() > maximum_processes) { throw std::invalid_argument{"Too many selected processes"}; }
    for (const auto &requested : selected) {
      const auto current = inspector_.identity(requested.pid);
      if (!current || (requested.started_seconds != 0 && !current->sameInstance(requested))) { throw std::invalid_argument{"Selected process is unavailable, replaced or belongs to another account"}; }
      if (std::ranges::any_of(std::span{processes_}.first(count_), [&](const auto &other) { return other.pid == current->pid; })) { throw std::invalid_argument{"Duplicate selected process"}; }
      processes_[count_++] = *current;
    }
  }

  inline bool enabled() const noexcept { return count_ != 0; }
  inline std::span<const ProcessIdentity> processes() const noexcept { return std::span{processes_}.first(count_); }

  Result find(const FlowKey &flow) noexcept;

private:


  ProcessInspector inspector_;
  std::array<ProcessIdentity, maximum_processes> processes_;
  std::size_t count_ = 0;
#if defined(__APPLE__)
  std::array<proc_fdinfo, maximum_descriptors> descriptors_;
#endif
};

}

#if defined(__APPLE__)
namespace telar::runtime::redirect {

inline bool matchesMacosSocket(const in_sockinfo &socket, const FlowKey &flow) noexcept {
  if (ntohs(static_cast<std::uint16_t>(socket.insi_lport)) != flow.source.port || ntohs(static_cast<std::uint16_t>(socket.insi_fport)) != flow.destination.port) { return false; }
  const auto family = flow.source.endpoint.storage.ss_family;
  if (family != flow.destination.endpoint.storage.ss_family) { return false; }
  if (family == AF_INET && (socket.insi_vflag & INI_IPV4)) {
    const auto &local = reinterpret_cast<const sockaddr_in &>(flow.source.endpoint.storage).sin_addr;
    const auto &remote = reinterpret_cast<const sockaddr_in &>(flow.destination.endpoint.storage).sin_addr;
    return socket.insi_laddr.ina_46.i46a_addr4.s_addr == local.s_addr && socket.insi_faddr.ina_46.i46a_addr4.s_addr == remote.s_addr;
  }
  if (family == AF_INET6 && (socket.insi_vflag & INI_IPV6)) {
    const auto &local = reinterpret_cast<const sockaddr_in6 &>(flow.source.endpoint.storage).sin6_addr;
    const auto &remote = reinterpret_cast<const sockaddr_in6 &>(flow.destination.endpoint.storage).sin6_addr;
    return std::memcmp(&socket.insi_laddr.ina_6, &local, sizeof(local)) == 0 && std::memcmp(&socket.insi_faddr.ina_6, &remote, sizeof(remote)) == 0;
  }
  return false;
}

inline SocketOwners::Result SocketOwners::find(const FlowKey &flow) noexcept {
  Result result;
  for (const auto &selected : processes()) {
    const auto current = inspector_.identity(selected.pid);
    if (!current || !current->sameInstance(selected)) { continue; }
    const auto bytes = ::proc_pidinfo(selected.pid, PROC_PIDLISTFDS, 0, descriptors_.data(), sizeof(descriptors_));
    if (bytes <= 0 || bytes >= static_cast<int>(sizeof(descriptors_)) || bytes % sizeof(proc_fdinfo) != 0) { result.complete = false; continue; }
    const auto count = static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo);
    for (const auto &descriptor : std::span{descriptors_}.first(count)) {
      if (descriptor.proc_fdtype != PROX_FDTYPE_SOCKET) { continue; }
      socket_fdinfo information{};
      if (::proc_pidfdinfo(selected.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, sizeof(information)) != sizeof(information)) { if (errno != EBADF && errno != ESRCH) { result.complete = false; } continue; }
      const auto &socket = information.psi;
      if (socket.soi_kind != SOCKINFO_TCP || socket.soi_type != SOCK_STREAM || socket.soi_protocol != IPPROTO_TCP) { continue; }
      const auto &tcp = socket.soi_proto.pri_tcp;
      if (tcp.tcpsi_state == TSI_S_CLOSED || tcp.tcpsi_state == TSI_S_LISTEN || !matchesMacosSocket(tcp.tcpsi_ini, flow)) { continue; }
      const auto verified = inspector_.identity(selected.pid);
      if (verified && verified->sameInstance(selected)) { result.process = *verified; result.complete = true; return result; }
    }
  }
  return result;
}

}
#else
namespace telar::runtime::redirect {

inline SocketOwners::Result SocketOwners::find(const FlowKey &flow) noexcept {
  Result result;
  try {
    std::optional<std::uint64_t> inode;
    visitLinuxTcpSockets([&](const LinuxTcpSocket &socket) {
      if (socket.inode != 0 && socket.matches(flow.source, flow.destination)) {
        inode = socket.inode;
        return false;
      }
      return true;
    });
    if (!inode) {
      return result;
    }

    for (const auto &selected : processes()) {
      const auto current = inspector_.identity(selected.pid);
      if (!current || !current->sameInstance(selected)) {
        continue;
      }

      std::array<char, PATH_MAX> path;
      std::snprintf(path.data(), path.size(), "/proc/%d/fd", selected.pid);
      DirectoryStream directory{FileDescriptor{::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)}};
      std::size_t count = 0;
      while (const auto *entry = directory.next()) {
        if (++count > maximum_descriptors) {
          result.complete = false;
          break;
        }
        std::array<char, 64> target;
        const auto length = ::readlinkat(directory.descriptor(), entry->d_name, target.data(), target.size());
        if (length < 0 && errno == ENOENT) {
          continue;
        }
        if (length <= 0 || static_cast<std::size_t>(length) >= target.size()) {
          result.complete = false;
          continue;
        }

        std::string_view name{target.data(), static_cast<std::size_t>(length)};
        if (!name.starts_with("socket:[") || !name.ends_with(']')) {
          continue;
        }
        name = name.substr(sizeof("socket:[") - 1, name.size() - sizeof("socket:["));
        std::uint64_t descriptor_inode = 0;
        const auto parsed = std::from_chars(name.data(), name.data() + name.size(), descriptor_inode);
        if (parsed.ec != std::errc{} || parsed.ptr != name.data() + name.size() || descriptor_inode != *inode) {
          continue;
        }
        const auto verified = inspector_.identity(selected.pid);
        if (verified && verified->sameInstance(selected)) {
          result.process = *verified;
          result.complete = true;
          return result;
        }
      }
    }
  } catch (...) {
    result.complete = false;
  }
  return result;
}

}
#endif
}

#if defined(__APPLE__)
// Interface: redirect/helper.cppm
export {
namespace telar::runtime::redirect {

class Listener {
public:
  inline explicit Listener(const Target &target, bool incoming = false) : target_(target), socket_(openOriginSocket(target.endpoint.storage.ss_family)), incoming_(incoming) {
    NetworkAddress local = target.endpoint;
    local.setPort(0);
    if (!incoming) {
      if (local.storage.ss_family == AF_INET) { reinterpret_cast<sockaddr_in *>(&local.storage)->sin_addr.s_addr = htonl(INADDR_LOOPBACK); }
      else { reinterpret_cast<sockaddr_in6 *>(&local.storage)->sin6_addr = in6addr_loopback; }
    }
    if (local.storage.ss_family == AF_INET6) {
      const int enabled = 1;
      if (::setsockopt(socket_.get(), IPPROTO_IPV6, IPV6_V6ONLY, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Configure IPv6 redirect listener"};
      }
    }
    if (::bind(socket_.get(), local.address(), local.length) != 0 || ::listen(socket_.get(), 128) != 0) {
      throw SystemError{"Bind transparent redirect listener"};
    }
    socklen_t length = local.length;
    if (::getsockname(socket_.get(), reinterpret_cast<sockaddr *>(&local.storage), &length) != 0) {
      throw SystemError{"Read redirect listener port"};
    }
    port_ = ntohs(local.storage.ss_family == AF_INET ? reinterpret_cast<sockaddr_in *>(&local.storage)->sin_port : reinterpret_cast<sockaddr_in6 *>(&local.storage)->sin6_port);
  }

  inline int descriptor() const noexcept { return socket_.get(); }
  inline Mapping mapping() const noexcept { return {.target = target_, .listener_port = port_, .incoming = incoming_}; }

  inline FileDescriptor accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (child) {
      configureProxySocket(child.get());
    } else if (!socketWouldBlock(errno)) {
      throw SystemError{"Accept redirected TCP connection"};
    }
    return child;
  }

private:
  Target target_;
  FileDescriptor socket_;
  std::uint16_t port_ = 0;
  bool incoming_ = false;
};

class ShutdownSignals {
public:
  inline ShutdownSignals() {
    sigemptyset(&selected_);
    sigaddset(&selected_, SIGINT);
    sigaddset(&selected_, SIGTERM);
    const auto result = ::pthread_sigmask(SIG_BLOCK, &selected_, &previous_);
    if (result != 0) {
      throw SystemError{"Block redirect shutdown signals", result};
    }
  }

  inline ~ShutdownSignals() {
    // Consume the handled shutdown signal before restoring the old mask.
    sigset_t pending;
    if (::sigpending(&pending) == 0 && (sigismember(&pending, SIGINT) || sigismember(&pending, SIGTERM))) {
      int received;
      ::sigwait(&selected_, &received);
    }
    ::pthread_sigmask(SIG_SETMASK, &previous_, nullptr);
  }

  inline bool stopping() const noexcept {
    sigset_t pending;
    return ::sigpending(&pending) == 0 && (sigismember(&pending, SIGINT) || sigismember(&pending, SIGTERM));
  }

private:
  sigset_t selected_{};
  sigset_t previous_{};
};

template <Allocator Memory>
class Helper {
  struct Pending {
    Connection connection;
    std::chrono::steady_clock::time_point deadline;
    std::size_t flow;
  };

  struct Flow {
    FlowKey key;
    FileDescriptor lifetime{};
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
    bool accepted = false;
    bool incoming = false;
    std::optional<RoutePath> bypass;
  };

public:
  inline explicit Helper(Memory &memory, std::string_view endpoint, std::span<const Target> targets, std::span<const ProcessIdentity> processes = {}, Direction direction = Direction::outbound)
      : memory_(memory), endpoint_(endpoint, AllocatorRef<char, Memory>{memory}), direction_(direction) {
    if (processes.size() > selected_processes_.size()) { throw std::invalid_argument{"Too many selected processes"}; }
    if (targets.empty() || (allowsIncoming(direction) && !processes.empty())) { throw std::invalid_argument{"Incoming redirect selects local services by account; process selection is outbound only"}; }
    const auto incoming = LocalAddresses::selection(targets, direction);
    std::ranges::copy(processes, selected_processes_.begin());
    process_count_ = processes.size();
    endpoint_ += socket_suffix;
    for (const auto &target : targets) {
      listeners_[count_].emplace(target, incoming[count_]);
      mappings_[count_] = listeners_[count_]->mapping();
      ++count_;
    }
  }

  inline String<Memory> plan(uid_t uid, const PfIdentity<Memory> &identity, bool dry_run = false) {
    std::array<FlowKey, maximum_flows> keys;
    std::array<FlowKey, maximum_flows> incoming;
    std::array<Bypass, maximum_flows> bypasses;
    std::size_t size = 0;
    std::size_t bypass_size = 0;
    std::size_t incoming_size = 0;
    for (const auto &flow : flows_) {
      if (flow && flow->bypass) { bypasses[bypass_size++] = {.key = flow->key, .route = *flow->bypass}; }
      else if (flow && flow->incoming) { incoming[incoming_size++] = flow->key; }
      else if (flow) { keys[size++] = flow->key; }
    }
    const PfScope scope{.uid = uid, .label = identity.label, .discovery_interface = discovery_ ? discovery_->name() : "utun0", .flows = std::span{keys}.first(size), .log_interface = packet_log_ ? std::optional{packet_log_->index()} : dry_run && allowsIncoming(direction_) ? std::optional{0u} : std::nullopt, .bypasses = std::span{bypasses}.first(bypass_size), .log_all = process_count_ != 0 || allowsIncoming(direction_), .direction = direction_, .incoming_flows = std::span{incoming}.first(incoming_size)};
    return pfRules(memory_, std::span{mappings_}.first(count_), scope);
  }

  inline void run(const PfIdentity<Memory> &identity) {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Transparent redirection requires the privileged helper"};
    }
    ShutdownSignals signals;
    auto monitor = traffic::connect(endpoint_);
    uid_t uid;
    const auto credentials = peerCredentials(monitor.get());
    if (!credentials || (uid = credentials->user) == 0) { throw SystemError{"Redirect runtime must belong to an unprivileged account", EACCES}; }
    if (process_count_ != 0) { owners_.emplace(uid, std::span{selected_processes_}.first(process_count_)); }
    if (allowsIncoming(direction_)) { accounts_.emplace(memory_); accounts_->validate(); }
    std::array<Byte, Protocol::frame_bytes> hello;
    traffic::sendAll(monitor.get(), Protocol::encode(hello, Kind::monitor, {}));
    std::array<Byte, sizeof(std::uint32_t)> reply;
    readAll(monitor.get(), reply);
    plugins::FrameReader reader{reply};
    if (reader.integer<std::uint32_t>() != uid) { throw EncodingError{"Redirect runtime account does not match its socket credentials"}; }
    discovery_.emplace();
    nat_.emplace();
    Record state{memory_, identity, endpoint_};
    PfCommand command{memory_};
    PfLoopback interface{command};
    SharedLoopback loopback{memory_, interface, identity.label};
    PfSession session{command, state, identity, loopback};
    session.start(plan(uid, identity));
    if (owners_ || allowsIncoming(direction_) || std::ranges::any_of(std::span{mappings_}.first(count_), [](const auto &mapping) { return mapping.target.host.view() == "::1"; })) {
      packet_log_.emplace(state, uid, direction_);
      session.replace(plan(uid, identity));
      std::fprintf(stderr, "telar redirect: TCP discovery on pflog%u\n", packet_log_->index());
    }
    std::fprintf(stderr, "telar redirect: active for uid %u, %zu TCP destinations, anchor %s, discovery %.*s\n", uid, count_, identity.anchor.c_str(), static_cast<int>(discovery_->name().size()), discovery_->name().data());
    const auto active = static_cast<Byte>(MonitorUpdate::active);
    traffic::sendAll(monitor.get(), {&active, 1});
    while (!signals.stopping()) {
      std::array<pollfd, pending_offset + maximum_pending + maximum_flows> descriptors{};
      descriptors[0] = {.fd = monitor.get(), .events = POLLIN, .revents = 0};
      descriptors[1] = {.fd = discovery_->descriptor(), .events = POLLIN, .revents = 0};
      descriptors[2] = {.fd = packet_log_ ? packet_log_->descriptor() : -1, .events = POLLIN, .revents = 0};
      for (std::size_t index = 0; index < Target::maximum_targets; ++index) {
        descriptors[index + 3] = {.fd = listeners_[index] ? listeners_[index]->descriptor() : -1, .events = POLLIN, .revents = 0};
      }
      for (std::size_t index = 0; index < pending_.size(); ++index) {
        descriptors[pending_offset + index] = {.fd = pending_[index] ? pending_[index]->connection.origin.get() : -1, .events = POLLOUT, .revents = 0};
      }
      for (std::size_t index = 0; index < flows_.size(); ++index) {
        descriptors[pending_offset + maximum_pending + index] = {.fd = flows_[index] ? flows_[index]->lifetime.get() : -1, .events = POLLIN, .revents = 0};
      }
      constexpr int poll_ms = 100;
      if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
        throw SystemError{"Poll transparent TCP helper"};
      }
      if (descriptors[0].revents & POLLIN) {
        Byte command;
        const auto received = ::recv(monitor.get(), &command, 1, 0);
        if (received == 1 && command != stop_request) { throw EncodingError{"Invalid redirect stop request"}; }
        break;
      }
      if (descriptors[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
        break;
      }
      bool changed = false;
      for (std::size_t index = 0; index < flows_.size(); ++index) {
        if (flows_[index] && ((descriptors[pending_offset + maximum_pending + index].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) || std::chrono::steady_clock::now() >= flows_[index]->deadline)) {
          flows_[index].reset();
          changed = true;
        }
      }
      if (changed) { session.replace(plan(uid, identity)); }
      for (std::size_t index = 0; index < count_; ++index) {
        if (descriptors[index + 3].revents & POLLIN) {
          accept(*listeners_[index], uid);
        }
      }
      for (std::size_t index = 0; index < pending_.size(); ++index) {
        auto &pending = pending_[index];
        if (!pending) {
          continue;
        }
        if (!flows_[pending->flow]) {
          pending.reset();
          continue;
        }
        if (descriptors[pending_offset + index].revents & (POLLOUT | POLLERR | POLLHUP)) {
          int failure = 0;
          socklen_t length = sizeof(failure);
          if (::getsockopt(pending->connection.origin.get(), SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0) {
            handoff(pending->connection, pending->flow, uid);
          } else if (flows_[pending->flow]->incoming) {
            std::fprintf(stderr, "telar redirect: incoming origin connection failed: %s\n", std::strerror(failure ? failure : errno));
          }
          pending.reset();
        } else if (std::chrono::steady_clock::now() >= pending->deadline) {
          if (flows_[pending->flow]->incoming) { std::fprintf(stderr, "telar redirect: incoming origin connection timed out\n"); }
          pending.reset();
        }
      }
      if (descriptors[1].revents & POLLIN) {
        discover(session, uid, identity);
      }
      if (packet_log_) {
        for (std::size_t count = 0; count < maximum_accept_batch; ++count) {
          auto packet = packet_log_->receive();
          if (packet.empty()) { break; }
          discovered(session, uid, identity, packet, &packet_log_->metadata());
        }
      }
    }
    packet_log_.reset();
    session.stop();
    const auto stopped = static_cast<Byte>(MonitorUpdate::stopped);
    ::send(monitor.get(), &stopped, 1, 0);
  }

private:
  template <typename Session>
  inline void discover(Session &session, uid_t uid, const PfIdentity<Memory> &identity) {
    std::array<Byte, 65540> bytes;
    auto packet = discovery_->receive(bytes);
    if (packet.empty()) { return; }
    if (owners_ || allowsIncoming(direction_)) { return; }
    discovered(session, uid, identity, packet);
  }

  template <typename Session>
  inline void discovered(Session &session, uid_t uid, const PfIdentity<Memory> &identity, std::span<Byte> packet, const PacketLog::Metadata *metadata = nullptr) {
    const auto key = FlowKey::syn(packet);
    const bool incoming = metadata && metadata->incoming;
    if (!key || (incoming ? !allowsIncoming(direction_) : !allowsOutgoing(direction_)) || !std::ranges::any_of(std::span{mappings_}.first(count_), [&](const auto &mapping) { return (!incoming || mapping.incoming) && FlowKey::same(mapping.target, key->destination); })) {
      std::fprintf(stderr, "telar redirect: rejected unsupported discovery packet\n");
      return;
    }
    if (incoming && (metadata->interface_index == 0 || metadata->interface.view() == "lo0" || metadata->interface.view() == discovery_->name() || !LocalAddresses{}.contains(key->destination))) { throw SystemError{"Incoming redirect destination/interface is no longer local", EADDRNOTAVAIL}; }
    const auto found = std::ranges::find_if(flows_, [&](const auto &flow) { return flow && flow->incoming == incoming && flow->key.matches(*key); });
    if (found == flows_.end()) {
      const auto empty = std::ranges::find_if(flows_, [](const auto &flow) { return !flow; });
      if (empty == flows_.end()) { return; }
      Flow flow{.key = *key, .incoming = incoming};
      if (owners_) {
        const auto owner = owners_->find(*key);
        if (!owner.process) {
          if (!metadata || metadata->interface_index == 0) { throw SystemError{"Original process route is unavailable", ENXIO}; }
          flow.bypass = RoutePath::lookup(key->destination, metadata->interface_index);
          flow.deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
          if (!owner.complete) { std::fprintf(stderr, "telar redirect: incomplete process ownership lookup; retaining the direct route\n"); }
        }
      }
      empty->emplace(std::move(flow));
      session.replace(plan(uid, identity));
      std::fprintf(stderr, "telar redirect: discovered TCP flow for destination port %u\n", key->destination.port);
    }
    discovery_->inject(packet);
  }

  inline static void readAll(int socket, std::span<Byte> bytes) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    while (!bytes.empty()) {
      pollfd descriptor{.fd = socket, .events = POLLIN, .revents = 0};
      constexpr int poll_ms = 50;
      if (::poll(&descriptor, 1, poll_ms) > 0) {
        const auto count = ::recv(socket, bytes.data(), bytes.size(), MSG_DONTWAIT);
        if (count > 0) {
          bytes = bytes.subspan(static_cast<std::size_t>(count));
        } else if (count == 0 || !socketWouldBlock(errno)) {
          throw SystemError{"Redirect runtime disconnected", ECONNRESET};
        }
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Redirect runtime reply timed out", ETIMEDOUT};
      }
    }
  }

  inline void accept(const Listener &listener, uid_t uid) {
    for (std::size_t round = 0; round < maximum_accept_batch; ++round) {
      auto child = listener.accept();
      if (!child) {
        return;
      }
      auto slot = std::ranges::find_if(pending_, [](const auto &value) { return !value; });
      if (slot == pending_.end()) {
        continue;
      }
      const auto target = listener.mapping().target;
      const auto flow = std::ranges::find_if(flows_, [&](const auto &value) { return value && !value->bypass && !value->accepted && FlowKey::same(value->key.destination, target) && NatLookup::peerMatches(child.get(), value->key); });
      if (flow == flows_.end() || !nat_->matches(child.get(), (*flow)->key)) {
        std::fprintf(stderr, "telar redirect: rejected connection without selected NAT state\n");
        continue;
      }
      const auto index = static_cast<std::size_t>(flow - flows_.begin());
      if (owners_ && !owners_->find((*flow)->key).process) { std::fprintf(stderr, "telar redirect: selected process no longer owns the accepted socket\n"); continue; }
      (*flow)->accepted = true;
      if ((*flow)->incoming) { std::fprintf(stderr, "telar redirect: accepted incoming TCP for destination port %u\n", target.port); }
      Connection connection{.child = std::move(child), .origin = openOriginSocket(target.endpoint.storage.ss_family), .target = target};
      if (::connect(connection.origin.get(), target.endpoint.address(), target.endpoint.length) == 0) {
        handoff(connection, index, uid);
      } else if (errno == EINPROGRESS || errno == EINTR) {
        slot->emplace(Pending{.connection = std::move(connection), .deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10}, .flow = index});
      } else if ((*flow)->incoming) {
        std::fprintf(stderr, "telar redirect: incoming origin connection failed: %s\n", std::strerror(errno));
      }
    }
  }

  inline void handoff(const Connection &connection, std::size_t flow, uid_t uid) {
    if (flows_[flow]->incoming && (!accounts_ || accounts_->peer(connection.origin.get()) != uid)) {
      std::fprintf(stderr, "telar redirect: rejected incoming origin without the runtime account\n");
      flows_[flow]->deadline = std::chrono::steady_clock::now();
      return;
    }
    auto channel = traffic::connect(endpoint_);
    Protocol::send(channel.get(), connection);
    std::array<Byte, 1> admitted{};
    readAll(channel.get(), admitted);
    if (admitted[0] != 1) {
      std::fprintf(stderr, "telar redirect: runtime connection capacity reached\n");
      return;
    }
    flows_[flow]->lifetime = std::move(channel);
    flows_[flow]->deadline = std::chrono::steady_clock::time_point::max();
    if (flows_[flow]->incoming) { std::fprintf(stderr, "telar redirect: handed incoming TCP to runtime for destination port %u\n", connection.target.port); }
  }

  static constexpr std::size_t maximum_pending = 32;
  static constexpr std::size_t maximum_accept_batch = 16;
  static constexpr std::size_t maximum_flows = 256;
  static constexpr std::size_t pending_offset = 3 + Target::maximum_targets;
  Memory &memory_;
  String<Memory> endpoint_;
  std::array<std::optional<Listener>, Target::maximum_targets> listeners_;
  std::array<Mapping, Target::maximum_targets> mappings_;
  std::array<std::optional<Pending>, maximum_pending> pending_;
  std::array<std::optional<Flow>, maximum_flows> flows_;
  std::optional<Discovery> discovery_;
  std::optional<NatLookup> nat_;
  std::optional<PacketLog> packet_log_;
  std::optional<SocketOwners> owners_;
  std::optional<SocketAccounts<Memory>> accounts_;
  std::array<ProcessIdentity, SocketOwners::maximum_processes> selected_processes_;
  std::size_t process_count_ = 0;
  std::size_t count_ = 0;
  Direction direction_ = Direction::outbound;
};

}
}

#endif
