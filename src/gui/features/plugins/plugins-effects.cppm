// What a plugin's action does: the run of one action of a package with the client's context,
// and the effects the run returns, decoded and authorized against what the package may do.
export module telar.gui.features.plugins:effects;

import std;

import telar.config.client;
import telar.plugins;
import telar.base.memory.containers;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.base.ds;

// Interface: config/plugin_effects.cppm
export {
  namespace telar::gui::features::plugins {

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
      static ds::Option<runtime::plugins::Capability> capability(BindingActionKind kind);

      ds::Array<Effect, BindingEffects::maximum_effects> effects_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: config/plugin_invocation.cppm
export {
  namespace telar::gui::features::plugins {

    struct PluginInvocation {
      runtime::plugins::Package package;
      runtime::FixedText<runtime::plugins::PackageLimits::action_bytes> action;
      BindingContext context;
      std::uint64_t configuration_generation = 0;
      std::size_t package_index = 0;
    };

  }
}
