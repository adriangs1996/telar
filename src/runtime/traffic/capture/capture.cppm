export module telar.runtime.traffic.capture;

import std;
import telar.tbc;
import telar.native.pcap;
import telar.sys.process;
import telar.sys.posix;

import telar.runtime.traffic.control_protocol;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.vocabulary;
import telar.platform.primitives;
import telar.base.ds;

// Interface: traffic/kernel_drops.cppm
export {
  namespace telar::runtime::traffic {

    class KernelDrops {
    public:
      struct Sample {
        std::uint32_t buffer = 0;
        std::uint32_t interface = 0;
      };

      void observe(Sample& previous, std::uint32_t buffer, std::uint32_t interface) noexcept;

      [[nodiscard]] std::uint64_t count() const noexcept;

    private:
      std::uint64_t total_ = 0;
    };

  }
}

// Interface: traffic/capture.cppm
export {
  namespace telar::runtime::traffic {

    // This helper accepts no executable code, routing commands, CA keys or subscriber filters.
    // Its only privileged operations are opening capture devices and reading their packets.
    class Capture {
      struct Device {
        explicit Device(pcap_t* value, std::string_view interface, std::uint32_t identity);

        std::unique_ptr<pcap_t, decltype(&pcap_close)> handle;
        FixedText<Limits::interface_bytes + 1> name;
        std::uint32_t index = 0;
        KernelDrops::Sample drops;
        bool seen = false;
      };

    public:
      explicit Capture(Memory& memory, FileDescriptor socket);
      // The channel's buffer allocates from the capture's own allocator, so the capture stays put.
      Capture(const Capture&) = delete;
      Capture& operator=(const Capture&) = delete;
      Capture(Capture&&) = delete;
      Capture& operator=(Capture&&) = delete;
      ~Capture() = default;

      void live();

      void offline(const char* path);

    private:
      class Signals {
      public:
        Signals();
        Signals(const Signals&) = delete;
        Signals& operator=(const Signals&) = delete;
        Signals(Signals&&) = delete;
        Signals& operator=(Signals&&) = delete;
        ~Signals();

        [[nodiscard]] static bool stopped() noexcept;

      private:
        sigset_t selected_{};
        sigset_t previous_{};
      };

      // What the capture publishes on its data channel: publishing borrows the channel alone, so the
      // device being reported stays borrowed meanwhile.
      struct Channel {
        explicit Channel(ErasingAllocator<Memory>& memory, FileDescriptor descriptor);

        void emit(Event event);

        void notice(Kind kind, std::string_view interface, std::string_view message = {}, std::uint32_t index = 0);

        void packet(std::uint32_t link_type, const pcap_pkthdr& header, const u_char* bytes, std::string_view interface, std::uint32_t index);

        FileDescriptor socket;
        ds::Vec<Byte, ErasingAllocator<Memory>> output;
        std::uint64_t session = 0;
        std::uint64_t sequence = 0;
        std::uint64_t dropped = 0;
        KernelDrops kernel_drops;
        bool offline = false;
      };

      void greet(Role role);

      void drainControl();

      void discover();

      // Marks the device open on the interface seen, or closes one whose index changed: true when it stays.
      bool keep(std::string_view name, std::uint32_t index);

      // Opens a device on the interface in a free slot, reporting why when it cannot.
      void attach(const pcap_if_t& interface, std::uint32_t index);

      // Reads a batch of a device's packets. The device is named by its slot: what it emits is written
      // through the capture, so its name and handle are read out of the table first.
      bool drain(std::size_t slot);

      void statistics();

      static void sample(KernelDrops& drops, Device& device) noexcept;

      void close(std::size_t slot);

      ErasingAllocator<Memory> memory_;
      tbc::val_self<Channel> channel_;
      ds::Array<ds::Option<Device>, Limits::interfaces> devices_;
    };

  }
}

// Interface: traffic/event_frame.cppm
export {
  namespace telar::runtime::traffic {

    struct EventFrame {
      explicit EventFrame(ConcurrentMemory& memory, std::size_t size);

      SensitiveAllocation<ConcurrentMemory> bytes;
    };

  }
}
