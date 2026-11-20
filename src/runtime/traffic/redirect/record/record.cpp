module telar.runtime.traffic.redirect.record;

import telar.native.pcap;
import telar.sys.socket;
import telar.platform.error;
import telar.platform.fs;
import telar.base.ds;
import telar.base.text;
import telar.wire.vocabulary;
import telar.runtime.traffic.redirect.ingress;
#ifdef __APPLE__
import telar.sys.apple;
#endif

namespace telar::runtime::redirect {

  namespace {

    // Names the request's interface after the private log interface at `index`.
    void nameLogInterface(ifreq& request, unsigned index) {
      const auto name = std::span{sys::interfaceName(request)};

      std::format_to_n(name.data(), static_cast<std::ptrdiff_t>(name.size() - 1), "pflog{}", index);
    }

  }

  unsigned LogInterface::create() {
    FileDescriptor control{::socket(AF_INET, SOCK_DGRAM, 0)};
    if (!control) {
      throw SystemError{"Open PF log interface control"};
    }

    for (unsigned candidate = maximum; candidate != 0; --candidate) {
      ifreq request{};

      nameLogInterface(request, candidate - 1);
      if (::ioctl(control.get(), SIOCIFCREATE, &request) == 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
        return candidate - 1;
      }

      if (sys::lastError() != EEXIST) {
        throw SystemError{"Create private PF log interface"};
      }
    }

    throw SystemError{"No private PF log interface available", ENOSPC};
  }

  void LogInterface::remove(unsigned index) {
    if (index >= maximum) {
      throw std::invalid_argument{"Invalid private PF log interface"};
    }

    FileDescriptor control{::socket(AF_INET, SOCK_DGRAM, 0)};
    if (!control) {
      throw SystemError{"Open PF log interface control"};
    }

    ifreq request{};

    nameLogInterface(request, index);
    if (::ioctl(control.get(), SIOCIFDESTROY, &request) != 0 && sys::lastError() != ENXIO && sys::lastError() != ENODEV) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Remove private PF log interface"};
    }
  }

  void LoopbackFlags::setSkipped(bool skipped) {
    FileDescriptor device{::open("/dev/pf", combineFlags(O_RDWR, O_CLOEXEC, O_NOFOLLOW))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!device) {
      throw SystemError{"Open PF loopback control"};
    }

    InterfaceRequest request{};
    constexpr std::string_view loopback = "lo0";

    std::ranges::copy(loopback, request.name.viewMut().begin());
    request.flags = skip_flag;
    const auto operation = skipped ? Operation::set_flags : Operation::clear_flags;
    if (::ioctl(device.get(), static_cast<unsigned long>(operation), &request) != 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): ioctl's C signature is variadic
      throw SystemError{"Change PF loopback skip flag"};
    }
  }

  template <Allocator Memory>
  RecordFile<Memory>::RecordFile(tbc::mut_a<Memory> memory, std::string_view name, RecordLock mode)
      : memory_(memory),
        name_(memory, name) {
    constexpr std::size_t maximum_name_bytes = 64;
    if (name.empty() || name.size() > maximum_name_bytes || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != std::string_view::npos) {
      throw std::invalid_argument{"Invalid redirect record name"};
    }

    constexpr std::string_view directory = "/var/run/telar-redirect";

    createPrivateDirectory(directory);
    directory_.reset(::open(directory.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC))); // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    ds::String<Memory> lock_name{memory, name_};

    lock_name.append(".lock");
    lock_ = openLockFile(directory_.get(), lock_name.data());
    if (!directory_ || !lock_) {
      throw SystemError{"Open redirect recovery lock"};
    }

    validate(lock_.get());
    constexpr auto retry_interval = std::chrono::milliseconds{10};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{6};

    while (::flock(lock_.get(), combineFlags(LOCK_EX, LOCK_NB)) != 0) {
      if (mode == RecordLock::owner || sys::lastError() != EWOULDBLOCK || std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Redirect helper already active or recovery update busy"};
      }

      std::this_thread::sleep_for(retry_interval);
    }
  }

  template <Allocator Memory>
  ds::Option<ds::String<Memory>> RecordFile<Memory>::load() {
    FileDescriptor file{::openat(directory_.get(), name_.data(), combineFlags(O_RDONLY, O_NONBLOCK, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!file && sys::lastError() == ENOENT) {
      return ds::none;
    }

    if (!file) {
      throw SystemError{"Read redirect recovery record"};
    }

    validate(file.get());
    constexpr std::size_t maximum_record_bytes = 4096;

    return readFileContents(memory_, file.get(), maximum_record_bytes);
  }

  template <Allocator Memory>
  void RecordFile<Memory>::save(std::string_view content) {
    const auto error = writePrivateFile(directory_.get(), name_, byteView(content), PrivateFileMode::replace);
    if (error != 0) {
      throw SystemError{"Save redirect recovery record", error};
    }
  }

  template <Allocator Memory>
  void RecordFile<Memory>::clear() {
    if (::unlinkat(directory_.get(), name_.data(), 0) != 0 && sys::lastError() != ENOENT) {
      throw SystemError{"Remove redirect recovery record"};
    }
  }

  template <Allocator Memory>
  void RecordFile<Memory>::validate(int descriptor) {
    constexpr mode_t shared_permissions = 0077;
    struct stat metadata{};
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != 0 || metadata.st_nlink != 1 || (metadata.st_mode & shared_permissions) != 0) {
      throw SystemError{"Unsafe redirect recovery file", EACCES};
    }
  }

  template <Allocator Memory>
  LoopbackLeases<Memory>::LoopbackLeases(Memory& memory)
      : memory_(memory),
        owners_(memory) {}

  template <Allocator Memory>
  void LoopbackLeases<Memory>::validateOwner(std::string_view owner) {
    if (owner.size() != owner_bytes - 1 || !owner.starts_with("tlr_") || owner.substr(4).find_first_not_of("0123456789abcdef") != std::string_view::npos) {
      throw std::invalid_argument{"Invalid PF loopback owner"};
    }
  }

  template <Allocator Memory>
  ds::String<Memory> LoopbackLeases<Memory>::ownerMarker(std::string_view owner) {
    ds::String<Memory> marker{memory_, owner};

    marker.push('\n');
    return marker;
  }

  unsigned PacketLog::index() const noexcept {
    return index_;
  }

  int PacketLog::descriptor() const noexcept {
    return pcap_get_selectable_fd(capture_.get());
  }

  auto PacketLog::metadata() const noexcept -> const Metadata& {
    return metadata_;
  }

  std::span<Byte> PacketLog::receive() {
    pcap_pkthdr* header = nullptr;
    const u_char* packet = nullptr;
    const auto result = pcap_next_ex(capture_.get(), &header, &packet);
    if (result == 0) {
      return {};
    }

    if (result < 0) {
      throw std::runtime_error{pcap_geterr(capture_.get())};
    }

    // libpcap hands a packet as its address and captured length.
#pragma clang unsafe_buffer_usage begin
    const std::span<const Byte> captured{packet, header->caplen};
#pragma clang unsafe_buffer_usage end
    const auto frame = normalize(captured, uid_, bytes_.viewMut(), &metadata_, direction_);

    return bytes_.viewMut().first(frame);
  }

  std::size_t PacketLog::normalize(std::span<const Byte> packet, uid_t uid, std::span<Byte> output, Metadata* metadata, Direction direction) {
    if (output.size() < sizeof(std::uint32_t) || packet.size() < sizeof(Header)) {
      return 0;
    }

    const auto header = loadValue<Header>(std::as_bytes(packet));
    const bool incoming = header.direction == static_cast<Byte>(PfDirection::incoming);
    const bool outgoing = header.direction == static_cast<Byte>(PfDirection::outgoing);
    if (header.length != __builtin_offsetof(Header, padding) || !((incoming && allowsIncoming(direction)) || (outgoing && allowsOutgoing(direction))) || header.action != static_cast<Byte>(Action::pass) || header.uid != uid || (header.family != AF_INET && header.family != AF_INET6) || packet.size() - sizeof(Header) > output.size() - sizeof(std::uint32_t)) {
      return 0;
    }

    if (metadata != nullptr) {
      // The name ends at its NUL; one that fills the field is malformed.
      const auto interface = header.interface.view();
      const auto length = static_cast<std::size_t>(std::ranges::find(interface, '\0') - interface.begin());
      if (length == interface.size()) {
        return 0;
      }

      metadata->pid = header.pid;
      metadata->incoming = incoming;
      metadata->interface.assign({header.interface.data(), length});
      ds::Array<char, IFNAMSIZ> name{};

      std::copy_n(header.interface.data(), length, name.dataMut());
      metadata->interface_index = ::if_nametoindex(name.data());
    }

    const auto family = htonl(static_cast<std::uint32_t>(header.family));

    storeValue(std::as_writable_bytes(output), family);
    std::copy(packet.begin() + sizeof(Header), packet.end(), output.begin() + sizeof(family));
    return sizeof(family) + packet.size() - sizeof(Header);
  }

  template <Allocator Memory>
  Record<Memory>::Record(tbc::mut_a<Memory> memory, const PfIdentity<Memory>& identity, std::string_view endpoint)
      : memory_(memory),
        endpoint_(memory, endpoint),
        file_(memory, identity.label) {}

  template <Allocator Memory>
  ds::Option<std::uint64_t> Record<Memory>::load() {
    const auto content = file_.load();
    if (!content) {
      return ds::none;
    }

    const auto newline = content->view().find('\n');
    if (newline == std::string_view::npos || std::string_view{*content}.substr(0, newline) != endpoint_) {
      throw std::runtime_error{"Redirect recovery record belongs to another endpoint"};
    }

    auto value = std::string_view{*content}.substr(newline + 1);
    const auto log = value.find('\n');
    if (log != std::string_view::npos) {
      const auto name = value.substr(log + 1);
      const auto index = parseExact<unsigned>(name).valueOr(LogInterface::maximum);
      if (index >= LogInterface::maximum) {
        throw std::runtime_error{"Invalid redirect log recovery record"};
      }

      log_index_ = index;
      value = value.substr(0, log);
    }

    const auto token = parseExact<std::uint64_t>(value);
    if (!token) {
      throw std::runtime_error{"Invalid redirect recovery token"};
    }

    last_token_ = *token;
    return *token;
  }

  template <Allocator Memory>
  void Record<Memory>::save(std::uint64_t token) {
    ds::String<Memory> content{memory_, endpoint_};

    content.push('\n');
    ds::formatTo(content, "{}", token);
    if (log_index_) {
      content.push('\n');
      ds::formatTo(content, "{}", *log_index_);
    }

    file_.save(content);
    last_token_ = token;
  }

  template <Allocator Memory>
  void Record<Memory>::saveLog(unsigned index) {
    if (!last_token_ || index >= LogInterface::maximum) {
      throw std::runtime_error{"Redirect session must exist before reserving a log interface"};
    }

    const auto previous = log_index_;

    log_index_ = index;
    try {
      save(*last_token_);
    } catch (...) {
      log_index_ = previous;
      throw;
    }
  }

  template <Allocator Memory>
  void Record<Memory>::clear() {
    if (log_index_) {
      LogInterface::remove(*log_index_);
      log_index_.reset();
      save(last_token_.valueOr(0));
    }

    file_.clear();
    log_index_.reset();
    last_token_.reset();
  }

  template class RecordFile<Memory>;
  template class RecordFile<ConcurrentMemory>;
  template class LoopbackLeases<Memory>;
  template class LoopbackLeases<ConcurrentMemory>;
  template class Record<Memory>;
  template class Record<ConcurrentMemory>;

}
