module telar.runtime.traffic.capture;

import telar.native.pcap;
import telar.sys.socket;
import telar.sys.process;
import telar.platform.error;
import telar.platform.net;
import telar.runtime.vocabulary.traffic;
import telar.base.ds;

namespace telar::runtime::traffic {

  void KernelDrops::observe(Sample& previous, std::uint32_t buffer, std::uint32_t interface) noexcept {
    // libpcap counters are cumulative within one capture handle and can wrap.
    // A reopened handle gets a fresh Sample; the session total stays intact.
    const auto delta = std::uint64_t{static_cast<std::uint32_t>(buffer - previous.buffer)} + static_cast<std::uint32_t>(interface - previous.interface);
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();

    total_ = delta > maximum - total_ ? maximum : total_ + delta;
    previous = {.buffer = buffer, .interface = interface};
  }

  std::uint64_t KernelDrops::count() const noexcept {
    return total_;
  }

  Capture::Device::Device(pcap_t* value, std::string_view interface, std::uint32_t identity)
      : handle(value, &pcap_close),
        index(identity) {
    name.assign(interface);
  }

  Capture::Capture(Memory& memory, FileDescriptor socket)
      : memory_(memory),
        socket_(std::move(socket)),
        output_(AllocatorRef<Byte, ErasingAllocator<Memory>>{memory_}) {
    output_.resize(Limits::frame_bytes + Protocol::prefix_bytes);
    randomBytes(&session_, sizeof(session_));
  }

  void Capture::live() {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Live interface capture requires the privileged capture helper"};
    }

    greet(Role::live_capture);
    Signals signals;
    auto discovery = std::chrono::steady_clock::time_point::min();

    while (!signals.stopped()) {
      const auto now = std::chrono::steady_clock::now();
      if (discovery == std::chrono::steady_clock::time_point::min() || now - discovery >= std::chrono::seconds{1}) {
        discover();
        statistics();
        discovery = now;
      }

      ds::Array<pollfd, Limits::interfaces + 1> descriptors{};

      descriptors.atMut(0) = {.fd = socket_.get(), .events = POLLIN, .revents = 0};
      for (std::size_t index = 0; index < devices_.size(); ++index) {
        descriptors.atMut(index + 1) = {.fd = devices_[index] ? pcap_get_selectable_fd(devices_[index]->handle.get()) : -1, .events = POLLIN, .revents = 0};
      }

      constexpr int poll_ms = 100;
      if (::poll(descriptors.dataMut(), descriptors.size(), poll_ms) < 0 && sys::lastError() != EINTR) {
        throw SystemError{"Poll packet capture"};
      }

      if (descriptors[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
        return;
      }

      drainControl();
      for (std::size_t slot = 0; slot < devices_.size(); ++slot) {
        if (devices_[slot] && !drain(slot)) {
          close(slot);
        }
      }
    }
  }

  void Capture::offline(const char* path) {
    ds::Array<char, PCAP_ERRBUF_SIZE> error{};
    const std::unique_ptr<pcap_t, decltype(&pcap_close)> file{pcap_open_offline(path, error.dataMut()), &pcap_close};
    if (!file) {
      throw std::runtime_error{error.data()};
    }

    greet(Role::offline_capture);
    offline_ = true;
    for (;;) {
      pcap_pkthdr* header;
      const u_char* bytes;
      const auto result = pcap_next_ex(file.get(), &header, &bytes);
      if (result == PCAP_ERROR_BREAK) {
        return;
      }

      if (result < 0) {
        throw std::runtime_error{pcap_geterr(file.get())};
      }

      if (result > 0) {
        packet(static_cast<std::uint32_t>(pcap_datalink(file.get())), *header, bytes, "offline", 0);
      }

      drainControl();
    }
  }

  Capture::Signals::Signals() {
    sigemptyset(&selected_);
    sigaddset(&selected_, SIGTERM);
    sigaddset(&selected_, SIGINT);
    const auto result = pthread_sigmask(SIG_BLOCK, &selected_, &previous_);
    if (result != 0) {
      throw SystemError{"Block capture shutdown signals", result};
    }
  }

  Capture::Signals::~Signals() {
    pthread_sigmask(SIG_SETMASK, &previous_, nullptr);
  }

  bool Capture::Signals::stopped() const noexcept {
    sigset_t pending;

    return ::sigpending(&pending) == 0 && (sigismember(&pending, SIGTERM) || sigismember(&pending, SIGINT));
  }

  void Capture::greet(Role role) {
    ds::Array<Byte, Protocol::greeting_bytes> output;

    sendAll(socket_.get(), Protocol::greeting(output.viewMut(), role));
    setNonblocking(socket_.get());
  }

  void Capture::drainControl() {
    ds::Array<Byte, Limits::metadata_bytes> bytes;
    const auto count = ::recv(socket_.get(), bytes.dataMut(), bytes.size(), MSG_DONTWAIT);
    if (count == 0 || (count < 0 && !socketWouldBlock(sys::lastError()))) {
      throw SystemError{"Traffic runtime disconnected", ECONNRESET};
    }
  }

  void Capture::emit(Event event) {
    event.session = session_;
    event.sequence = ++sequence_;
    event.offline = offline_;
    event.capture_drops = dropped_;
    event.kernel_drops = kernel_drops_.count();
    const auto payload = Protocol::encode(std::span{output_}.subspan(Protocol::prefix_bytes), event);
    const auto prefix = Protocol::prefix(payload.size());

    std::ranges::copy(prefix, output_.begin());

    // Once any part of a frame is written it must finish, or close the channel.
    // Only a wholly unsent frame may be dropped under capture backpressure.
    const auto bytes = std::span<const Byte>{output_}.first(prefix.size() + payload.size());
    const auto count = ::send(socket_.get(), bytes.data(), bytes.size(), 0);
    if (count < 0 && socketWouldBlock(sys::lastError())) {
      ++dropped_;
      return;
    }

    if (count < 0 && sys::lastError() == EINTR) {
      ++dropped_;
      return;
    }

    if (count <= 0) {
      throw SystemError{"Publish captured packet"};
    }

    auto remaining = bytes.subspan(static_cast<std::size_t>(count));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{1};

    while (!remaining.empty()) {
      pollfd descriptor{.fd = socket_.get(), .events = POLLOUT, .revents = 0};
      constexpr int write_poll_ms = 20;

      ::poll(&descriptor, 1, write_poll_ms);
      const auto written = ::send(socket_.get(), remaining.data(), remaining.size(), 0);
      if (written > 0) {
        remaining = remaining.subspan(static_cast<std::size_t>(written));
      } else if (written == 0 || !socketWouldBlock(sys::lastError())) {
        throw SystemError{"Publish partial capture frame"};
      }

      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Capture data channel stalled", ETIMEDOUT};
      }
    }
  }

  void Capture::notice(Kind kind, std::string_view interface, std::string_view message, std::uint32_t index) {
    emit(Event{.kind = kind, .interface_index = index, .interface = interface, .bytes = {reinterpret_cast<const Byte*>(message.data()), message.size()}});
  }

  void Capture::discover() {
    pcap_if_t* raw = nullptr;
    ds::Array<char, PCAP_ERRBUF_SIZE> error{};
    if (pcap_findalldevs(&raw, error.dataMut()) < 0) {
      throw std::runtime_error{error.data()};
    }

    const std::unique_ptr<pcap_if_t, decltype(&pcap_freealldevs)> interfaces{raw, &pcap_freealldevs};

    for (auto& device : devices_.viewMut()) {
      if (device) {
        device.getMut().seen = false;
      }
    }

    for (auto* interface = raw; interface != nullptr; interface = interface->next) {
      const std::string_view name{interface->name};
      const auto index = ::if_nametoindex(interface->name);
      if ((interface->flags & PCAP_IF_UP) == 0 || name.size() > Limits::interface_bytes || index == 0) {
        continue;
      }

      const auto devices = devices_.viewMut();
      auto existing = std::ranges::find_if(devices, [&](auto& device) {
        return device && device->name.view() == name;
      });
      if (existing != devices.end()) {
        if ((*existing)->index == index) {
          existing->getMut().seen = true;
          continue;
        }

        close(static_cast<std::size_t>(existing - devices.begin()));
      }

      auto slot = std::ranges::find_if(devices, [](auto& device) {
        return !device;
      });
      if (slot == devices.end()) {
        notice(Kind::interface_error, name, "Capture interface limit reached", index);
        continue;
      }

      pcap_t* handle = pcap_create(interface->name, error.dataMut());
      if (!handle) {
        notice(Kind::interface_error, name, error.data(), index);
        continue;
      }

      slot->emplace(handle, name, index);
      auto& capture = slot->getMut();
      constexpr int read_timeout_ms = 50;
      constexpr int kernel_buffer_bytes = 1024 * 1024;
      if (pcap_set_snaplen(handle, Limits::packet_bytes) != 0 || pcap_set_promisc(handle, 0) != 0 || pcap_set_timeout(handle, read_timeout_ms) != 0 || pcap_set_buffer_size(handle, kernel_buffer_bytes) != 0 || pcap_set_immediate_mode(handle, 1) != 0 || pcap_activate(handle) < 0 || pcap_setnonblock(handle, 1, error.dataMut()) != 0) {
        notice(Kind::interface_error, name, pcap_geterr(handle), index);
        slot->reset();
        continue;
      }

      if (::if_nametoindex(interface->name) != index) {
        notice(Kind::interface_error, name, "Interface changed during capture activation", index);
        slot->reset();
        continue;
      }

      capture.seen = true;
      notice(Kind::interface_open, name, {}, index);
    }

    for (std::size_t slot = 0; slot < devices_.size(); ++slot) {
      if (devices_[slot] && !devices_[slot]->seen) {
        close(slot);
      }
    }
  }

  bool Capture::drain(std::size_t slot) {
    constexpr std::size_t batch_packets = 64;
    auto* handle = devices_[slot]->handle.get();
    const auto name = devices_[slot]->name;
    const auto index = devices_[slot]->index;
    const auto link_type = static_cast<std::uint32_t>(pcap_datalink(handle));

    for (std::size_t round = 0; round < batch_packets; ++round) {
      pcap_pkthdr* header;
      const u_char* bytes;
      const auto result = pcap_next_ex(handle, &header, &bytes);
      if (result == 0) {
        return true;
      }

      if (result < 0) {
        notice(Kind::interface_error, name.view(), pcap_geterr(handle), index);
        return false;
      }

      packet(link_type, *header, bytes, name.view(), index);
    }

    return true;
  }

  void Capture::packet(std::uint32_t link_type, const pcap_pkthdr& header, const u_char* bytes, std::string_view interface, std::uint32_t index) {
    constexpr std::uint64_t micros_per_second = 1000000;
    const auto captured = std::min<std::size_t>(header.caplen, Limits::packet_bytes);

    emit(Event{
        .kind = Kind::packet,
        .timestamp_us = static_cast<std::uint64_t>(header.ts.tv_sec) * micros_per_second + static_cast<std::uint64_t>(header.ts.tv_usec),
        .interface_index = index,
        .link_type = link_type,
        .original_bytes = header.len,
        .interface = interface,
        .bytes = {bytes, captured},
    });
  }

  void Capture::statistics() {
    for (auto& device : devices_.viewMut()) {
      if (device) {
        sample(kernel_drops_, device.getMut());
      }
    }

    emit(Event{.kind = Kind::statistics});
  }

  void Capture::sample(KernelDrops& drops, Device& device) noexcept {
    pcap_stat value{};
    if (pcap_stats(device.handle.get(), &value) == 0) {
      drops.observe(device.drops, value.ps_drop, value.ps_ifdrop);
    }
  }

  void Capture::close(std::size_t slot) {
    sample(kernel_drops_, devices_.atMut(slot).getMut());
    const auto name = devices_[slot]->name;
    const auto index = devices_[slot]->index;

    notice(Kind::interface_closed, name.view(), {}, index);
    devices_.atMut(slot).reset();
  }

  EventFrame::EventFrame(ConcurrentMemory& memory, std::size_t size)
      : bytes(memory, size) {}

}
