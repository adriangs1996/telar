export module telar.runtime.traffic.capture;

import std;
import telar.native.pcap;
import telar.sys.process;
import telar.sys.posix;

export import telar.runtime.traffic.control_protocol;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;
export import telar.base.memory.sensitive;
import telar.base.diagnostics;
import telar.vocabulary;
import telar.platform.primitives;
import telar.platform.error;
import telar.platform.net;
import telar.runtime.vocabulary.traffic;

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

      std::uint64_t count() const noexcept;

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

      void live();

      void offline(const char* path);

    private:
      class Signals {
      public:
        Signals();

        ~Signals();

        bool stopped() const noexcept;

      private:
        sigset_t selected_{};
        sigset_t previous_{};
      };

      void greet(Role role);

      void drainControl();

      void emit(Event event);

      void notice(Kind kind, std::string_view interface, std::string_view message = {}, std::uint32_t index = 0);

      void discover();

      // Reads a batch of a device's packets. The device is named by its slot: what it emits is written
      // through the capture, so its name and handle are read out of the table first.
      bool drain(std::size_t slot);

      void packet(std::uint32_t link_type, const pcap_pkthdr& header, const u_char* bytes, std::string_view interface, std::uint32_t index);

      void statistics();

      static void sample(KernelDrops& drops, Device& device) noexcept;

      void close(std::size_t slot);

      ErasingAllocator<Memory> memory_;
      FileDescriptor socket_;
      Vector<Byte, ErasingAllocator<Memory>> output_;
      std::array<std::optional<Device>, Limits::interfaces> devices_;
      std::uint64_t session_ = 0;
      std::uint64_t sequence_ = 0;
      std::uint64_t dropped_ = 0;
      KernelDrops kernel_drops_;
      bool offline_ = false;
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
