export module telar.runtime.platform.private_tunnel;

import std;
import telar.sys.posix;

import telar.base.memory.containers;
import telar.platform.primitives;
import telar.sys.socket;

#if defined(__linux__)
// Interface: platform/linux/private_tunnel.cppm
export {
  namespace telar::runtime {

    class PrivateTunnel {
    public:
      PrivateTunnel();

      ssize_t write(std::span<const std::uint8_t> bytes) const noexcept;

      int descriptor() const noexcept;

      unsigned index() const noexcept;

      std::string_view name() const noexcept;

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
      PrivateTunnel();

      ssize_t write(std::span<const std::uint8_t> bytes) const noexcept;

      int descriptor() const noexcept;

      unsigned index() const noexcept;

      std::string_view name() const noexcept;

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
