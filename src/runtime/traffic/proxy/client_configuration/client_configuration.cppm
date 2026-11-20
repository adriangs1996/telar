export module telar.runtime.traffic.proxy.client_configuration;

import std;

import telar.runtime.traffic.proxy.authenticate;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.process;
import telar.sys.posix;
import telar.wire.runtime;

export {
  namespace telar::runtime {

    // What a child process is told to reach the proxy through. It shares the identity the proxy made
    // once it was ready, so a holder keeps no part of the proxy itself: launching a pane imports this
    // module, not the proxy.
    class ProxyClientConfiguration {
    public:
      struct Identity {
        ProxyStatus status{};
        ProxySecret secret;
        bool https_proxy = true;
        FixedText<PATH_MAX> certificate;
        FixedText<PATH_MAX> bundle;
      };

      ProxyClientConfiguration() noexcept = default;

      explicit ProxyClientConfiguration(std::shared_ptr<const Identity> identity) noexcept;

      [[nodiscard]] const ProxyStatus& status() const noexcept;

      // The command takes each variable the child gets. Built in client_configuration.cpp for the
      // allocators of Command.
      template <Allocator Memory>
      void apply(Command<Memory>& command) const;

    private:
      void environment(void* target, void (*set)(void* target, std::string_view name, std::string_view value)) const;

      inline static const ProxyStatus inactive{};
      std::shared_ptr<const Identity> identity_;
    };

    extern template void ProxyClientConfiguration::apply(Command<Memory>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<ConcurrentMemory>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<SystemAllocator>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<BudgetAllocator<SystemAllocator>>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& command) const;

  }
}
