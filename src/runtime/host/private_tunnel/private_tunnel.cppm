export module telar.runtime.host.private_tunnel;

import std;
import telar.sys.posix;

import telar.base.memory.containers;
import telar.platform.primitives;
import telar.sys.socket;

#ifdef __linux__
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

#ifdef __APPLE__
// Interface: platform/macos/private_tunnel.cppm
export {
  namespace telar::runtime {

    class PrivateTunnel {
    public:
      PrivateTunnel();

      [[nodiscard]] ssize_t write(std::span<const std::uint8_t> bytes) const noexcept;

      [[nodiscard]] int descriptor() const noexcept;

      [[nodiscard]] unsigned index() const noexcept;

      [[nodiscard]] std::string_view name() const noexcept;

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
#ifdef __APPLE__
#else
#endif
}
