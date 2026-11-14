export module telar.gui.config.plugin_effects;

import std;
import telar.tbc;

export import telar.gui.input.copy_pointer;
export import telar.gui.input.binding_effects;
export import telar.config.client;
export import telar.config.runtime;

export import telar.plugins;

export import telar.gui.core.json_writer;
import telar.base.diagnostics;
import telar.gui.config.plugin_query;
import telar.gui.core.primitives;
import telar.gui.input.key_encoder;
import telar.platform.primitives;
import telar.wire.vocabulary;

// Interface: config/callback_invocation.cppm
export {
  namespace telar::gui {

    using CallbackInvocation = runtime::config::CallbackInvocation;

  }
}

// Interface: config/plugin_effects.cppm
export {
  namespace telar::gui {

    class PluginEffects {
    public:
      static_assert(BindingEffects::maximum_effects == runtime::plugins::ActionProtocol::maximum_effects);
      using Effect = std::variant<BindingAction, NotificationActionDescription>;
      static constexpr std::size_t maximum_bytes = runtime::plugins::ActionProtocol::maximum_bytes;

      [[nodiscard]] static PluginEffects decode(std::span<const Byte> input);

      [[nodiscard]] std::span<const Effect> effects() const noexcept;

      // A caller must finish this whole-batch check before applying the first effect.
      void authorize(const runtime::plugins::Package& package, const runtime::plugins::TrustStore& trust) const;

    private:
      using Tag = runtime::plugins::ActionTag;

      static BindingAction indexed(std::span<const BindingActionKind> kinds, std::span<const Byte>& input);
      static NotificationActionDescription notification(std::span<const Byte>& input);
      static Effect decodeEffect(std::span<const Byte>& input);
      static std::optional<runtime::plugins::Capability> capability(BindingActionKind kind);

      std::array<Effect, BindingEffects::maximum_effects> effects_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: config/plugin_invocation.cppm
export {
  namespace telar::gui {

    struct PluginInvocation {
      runtime::plugins::Package package;
      runtime::FixedText<runtime::plugins::PackageLimits::action_bytes> action;
      BindingContext context;
      std::uint64_t configuration_generation = 0;
      std::size_t package_index = 0;
    };

  }
}

// Interface: config/runtime_query.cppm
export {
  namespace telar::gui {

    class RuntimeQuery {
    public:
      template <Allocator Memory>
      // The query is written into the output, region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const runtime::config::RuntimeValues<Memory>& values, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static std::optional<std::string_view> nullablePath(std::string_view path) noexcept;

      template <Allocator Memory>
      static void writeProxy(JsonWriter& writer, const runtime::ProxyOptions<Memory>& proxy);
    };

    extern template tbc::view<std::string_view, tbc::lt::a> RuntimeQuery::write<telar::Memory>(const runtime::config::RuntimeValues<telar::Memory>& values, tbc::view<std::span<char>, tbc::lt::a> output);
    extern template tbc::view<std::string_view, tbc::lt::a> RuntimeQuery::write<telar::ConcurrentMemory>(const runtime::config::RuntimeValues<telar::ConcurrentMemory>& values, tbc::view<std::span<char>, tbc::lt::a> output);

  }
}
