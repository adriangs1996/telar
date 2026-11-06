module;

#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <cstdio>
#include <net/if.h>
#include <stdexcept>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>


#include <algorithm>
#include <array>
#include <cstddef>
#include <fcntl.h>
#include <span>
#include <string_view>


#include "telar_base/memory/allocator.hpp"
#include <limits.h>
#include <sys/stat.h>
#include "telar_platform/random_bytes.hpp"
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <cstdint>
#include <unistd.h>
#include <cstdlib>
#include <chrono>
#include <optional>
#include <sys/file.h>
#include <thread>


#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif


#include "telar_client/codecs/telar_wire.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <arpa/inet.h>
#include <memory>
#include <pcap/pcap.h>


#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <cstring>
#include <netinet/in.h>
#include <charconv>
#include <net/if_dl.h>
#include <net/route.h>
#include <poll.h>

export module telar.runtime.redirect.record;

export import telar.platform;


export import telar.runtime.redirect.pf_rules;

// Interface: redirect/log_interface.cppm
export {
namespace telar::runtime::redirect {

class LogInterface {
public:
  static constexpr unsigned maximum = 16;

  inline static unsigned create() {
    FileDescriptor control{::socket(AF_INET, SOCK_DGRAM, 0)};
    if (!control) { throw SystemError{"Open PF log interface control"}; }
    for (unsigned candidate = maximum; candidate != 0; --candidate) {
      ifreq request{};
      std::snprintf(request.ifr_name, sizeof(request.ifr_name), "pflog%u", candidate - 1);
      if (::ioctl(control.get(), SIOCIFCREATE, &request) == 0) { return candidate - 1; }
      if (errno != EEXIST) { throw SystemError{"Create private PF log interface"}; }
    }
    throw SystemError{"No private PF log interface available", ENOSPC};
  }

  inline static void remove(unsigned index) {
    if (index >= maximum) { throw std::invalid_argument{"Invalid private PF log interface"}; }
    FileDescriptor control{::socket(AF_INET, SOCK_DGRAM, 0)};
    if (!control) { throw SystemError{"Open PF log interface control"}; }
    ifreq request{};
    std::snprintf(request.ifr_name, sizeof(request.ifr_name), "pflog%u", index);
    if (::ioctl(control.get(), SIOCIFDESTROY, &request) != 0 && errno != ENXIO && errno != ENODEV) {
      throw SystemError{"Remove private PF log interface"};
    }
  }
};

}
}

// Interface: redirect/pf_loopback.cppm
export {
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
  inline static void setSkipped(bool skipped) {
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
  inline explicit PfLoopback(Command &command) noexcept : command_(command) {}

  inline bool skipped() {
    constexpr std::array<std::string_view, 5> arguments{"-v", "-s", "Interfaces", "-i", "lo0"};
    return parse(command_.run(arguments));
  }

  inline void setSkipped(bool value) {
    Flags::setSkipped(value);
    if (skipped() != value) {
      throw std::runtime_error{"PF loopback skip flag did not change"};
    }
  }

  inline static bool parse(std::string_view output) {
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
}

// Interface: redirect/record_file.cppm
export {
namespace telar::runtime::redirect {

enum class RecordLock { owner, update };

template <Allocator Memory>
class RecordFile {
public:
  inline explicit RecordFile(Memory &memory, std::string_view name, RecordLock mode = RecordLock::owner)
      : memory_(memory), name_(name, AllocatorRef<char, Memory>{memory}) {
    if (name.empty() || name.size() > 64 || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != std::string_view::npos) {
      throw std::invalid_argument{"Invalid redirect record name"};
    }
    constexpr std::string_view directory = "/var/run/telar-redirect";
    createPrivateDirectory(directory);
    directory_.reset(::open(directory.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    String<Memory> lock_name{name_, AllocatorRef<char, Memory>{memory}};
    lock_name += ".lock";
    lock_.reset(::openat(directory_.get(), lock_name.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (!directory_ || !lock_) {
      throw SystemError{"Open redirect recovery lock"};
    }
    validate(lock_.get());
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{6};
    while (::flock(lock_.get(), LOCK_EX | LOCK_NB) != 0) {
      if (mode == RecordLock::owner || errno != EWOULDBLOCK || std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Redirect helper already active or recovery update busy"};
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
  }

  inline std::optional<String<Memory>> load() {
    FileDescriptor file{::openat(directory_.get(), name_.c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)};
    if (!file && errno == ENOENT) {
      return std::nullopt;
    }
    if (!file) {
      throw SystemError{"Read redirect recovery record"};
    }
    validate(file.get());
    return readFileContents(memory_, file.get(), 4096);
  }

  inline void save(std::string_view content) {
    const auto error = writePrivateFile(directory_.get(), name_, {reinterpret_cast<const std::uint8_t *>(content.data()), content.size()}, PrivateFileMode::replace);
    if (error != 0) {
      throw SystemError{"Save redirect recovery record", error};
    }
  }

  inline void clear() {
    if (::unlinkat(directory_.get(), name_.c_str(), 0) != 0 && errno != ENOENT) {
      throw SystemError{"Remove redirect recovery record"};
    }
  }

private:
  inline static void validate(int descriptor) {
    struct stat metadata{};
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || metadata.st_nlink != 1 || (metadata.st_mode & 0077) != 0) {
      throw SystemError{"Unsafe redirect recovery file", EACCES};
    }
  }

  Memory &memory_;
  String<Memory> name_;
  FileDescriptor directory_;
  FileDescriptor lock_;
};

}
}

// Interface: redirect/loopback_lease.cppm
export {
namespace telar::runtime::redirect {

template <Allocator Memory>
class LoopbackLeases {
public:
  inline explicit LoopbackLeases(Memory &memory) : memory_(memory), owners_(AllocatorRef<char, Memory>{memory}) {}

  template <typename Store, typename Interface>
  inline void acquire(Store &store, Interface &interface, std::string_view owner) {
    validateOwner(owner);
    load(store);
    const auto marker = ownerMarker(owner);
    const bool present = std::string_view{owners_}.contains(marker);
    if (!present && owners_.size() / owner_bytes >= maximum_owners) {
      throw std::runtime_error{"Too many transparent redirect loopback owners"};
    }
    const bool skipped = interface.skipped();
    restore_skip_ = restore_skip_ || skipped;
    if (!present) {
      owners_.append(marker);
    }
    // Persist before the ioctl so a failed change or a crash can be recovered.
    save(store);
    if (skipped) {
      interface.setSkipped(false);
    }
  }

  template <typename Store, typename Interface>
  inline void release(Store &store, Interface &interface, std::string_view owner) {
    validateOwner(owner);
    load(store);
    const auto marker = ownerMarker(owner);
    const auto position = owners_.find(marker);
    if (position == String<Memory>::npos) {
      return;
    }
    owners_.erase(position, marker.size());
    if (owners_.empty()) {
      if (restore_skip_) {
        interface.setSkipped(true);
      }
      store.clear();
    } else {
      save(store);
    }
  }

private:
  static constexpr std::size_t owner_bytes = 21;
  static constexpr std::size_t maximum_owners = 64;

  inline static void validateOwner(std::string_view owner) {
    if (owner.size() != owner_bytes - 1 || !owner.starts_with("tlr_") || owner.substr(4).find_first_not_of("0123456789abcdef") != std::string_view::npos) {
      throw std::invalid_argument{"Invalid PF loopback owner"};
    }
  }

  inline String<Memory> ownerMarker(std::string_view owner) {
    String<Memory> marker{owner, AllocatorRef<char, Memory>{memory_}};
    marker += '\n';
    return marker;
  }

  template <typename Store>
  inline void load(Store &store) {
    owners_.clear();
    restore_skip_ = false;
    const auto saved = store.load();
    if (!saved) {
      return;
    }
    auto content = std::string_view{*saved};
    if (!content.starts_with("skip\n") && !content.starts_with("filter\n")) {
      throw std::runtime_error{"Invalid PF loopback recovery record"};
    }
    restore_skip_ = content.starts_with("skip\n");
    content.remove_prefix(restore_skip_ ? 5 : 7);
    if (content.empty() || content.size() % owner_bytes != 0 || content.size() > maximum_owners * owner_bytes) {
      throw std::runtime_error{"Invalid PF loopback owner list"};
    }
    while (!content.empty()) {
      const auto owner = content.substr(0, owner_bytes - 1);
      validateOwner(owner);
      const auto marker = content.substr(0, owner_bytes);
      if (marker.back() != '\n' || std::string_view{owners_}.contains(marker)) {
        throw std::runtime_error{"Invalid or duplicate PF loopback owner"};
      }
      owners_.append(marker);
      content.remove_prefix(owner_bytes);
    }
  }

  template <typename Store>
  inline void save(Store &store) {
    String<Memory> content{restore_skip_ ? "skip\n" : "filter\n", AllocatorRef<char, Memory>{memory_}};
    content.append(owners_);
    store.save(content);
  }

  Memory &memory_;
  String<Memory> owners_;
  bool restore_skip_ = false;
};

template <Allocator Memory, typename Interface>
class SharedLoopback {
public:
  inline explicit SharedLoopback(Memory &memory, Interface &interface, std::string_view owner) noexcept
      : memory_(memory), interface_(interface), owner_(owner) {}

  inline void acquire() {
    RecordFile file{memory_, "loopback", RecordLock::update};
    LoopbackLeases leases{memory_};
    leases.acquire(file, interface_, owner_);
  }

  inline void release() {
    RecordFile file{memory_, "loopback", RecordLock::update};
    LoopbackLeases leases{memory_};
    leases.release(file, interface_, owner_);
  }

private:
  Memory &memory_;
  Interface &interface_;
  std::string_view owner_;
};

}
}

// Interface: redirect/packet_log.cppm
export {
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
  inline explicit PacketLog(State &state, uid_t uid, Direction direction = Direction::outbound) : uid_(uid), direction_(direction), capture_(nullptr, &pcap_close) {
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

  inline unsigned index() const noexcept { return index_; }
  inline int descriptor() const noexcept { return pcap_get_selectable_fd(capture_.get()); }
  inline const Metadata &metadata() const noexcept { return metadata_; }

  inline std::span<Byte> receive() {
    pcap_pkthdr *header;
    const u_char *packet;
    const auto result = pcap_next_ex(capture_.get(), &header, &packet);
    if (result == 0) { return {}; }
    if (result < 0) { throw std::runtime_error{pcap_geterr(capture_.get())}; }
    const auto frame = normalize({packet, header->caplen}, uid_, bytes_, &metadata_, direction_);
    return std::span{bytes_}.first(frame);
  }

  inline static std::size_t normalize(std::span<const Byte> packet, uid_t uid, std::span<Byte> output, Metadata *metadata = nullptr, Direction direction = Direction::outbound) {
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
}

// Interface: redirect/record.cppm
export {
namespace telar::runtime::redirect {

template <Allocator Memory>
class Record {
public:
  inline explicit Record(Memory &memory, const PfIdentity<Memory> &identity, std::string_view endpoint)
      : memory_(memory), endpoint_(endpoint, AllocatorRef<char, Memory>{memory}), file_(memory, identity.label) {}

  inline std::optional<std::uint64_t> load() {
    const auto content = file_.load();
    if (!content) {
      return std::nullopt;
    }
    const auto newline = content->find('\n');
    if (newline == String<Memory>::npos || std::string_view{*content}.substr(0, newline) != endpoint_) {
      throw std::runtime_error{"Redirect recovery record belongs to another endpoint"};
    }
    auto value = std::string_view{*content}.substr(newline + 1);
    const auto log = value.find('\n');
    if (log != std::string_view::npos) {
      const auto name = value.substr(log + 1);
      unsigned index = LogInterface::maximum;
      const auto parsed = std::from_chars(name.data(), name.data() + name.size(), index);
      if (parsed.ec != std::errc{} || parsed.ptr != name.data() + name.size() || index >= LogInterface::maximum) {
        throw std::runtime_error{"Invalid redirect log recovery record"};
      }
      log_index_ = index;
      value = value.substr(0, log);
    }
    std::uint64_t token = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), token);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()) {
      throw std::runtime_error{"Invalid redirect recovery token"};
    }
    last_token_ = token;
    return token;
  }

  inline void save(std::uint64_t token) {
    String<Memory> content{endpoint_, AllocatorRef<char, Memory>{memory_}};
    content += '\n';
    std::array<char, 32> value{};
    const auto result = std::to_chars(value.data(), value.data() + value.size(), token);
    content.append(value.data(), static_cast<std::size_t>(result.ptr - value.data()));
    if (log_index_) {
      content += '\n';
      const auto log = std::to_chars(value.data(), value.data() + value.size(), *log_index_);
      content.append(value.data(), static_cast<std::size_t>(log.ptr - value.data()));
    }
    file_.save(content);
    last_token_ = token;
  }

  inline void saveLog(unsigned index) {
    if (!last_token_ || index >= LogInterface::maximum) { throw std::runtime_error{"Redirect session must exist before reserving a log interface"}; }
    const auto previous = log_index_;
    log_index_ = index;
    try {
      save(*last_token_);
    } catch (...) {
      log_index_ = previous;
      throw;
    }
  }

  inline void clear() {
    if (log_index_) {
      LogInterface::remove(*log_index_);
      log_index_.reset();
      save(last_token_.value_or(0));
    }
    file_.clear();
    log_index_.reset();
    last_token_.reset();
  }

private:
  Memory &memory_;
  String<Memory> endpoint_;
  RecordFile<Memory> file_;
  std::optional<unsigned> log_index_;
  std::optional<std::uint64_t> last_token_;
};

}
}
