export module telar.gui.input.binding_effects;

import std;

export import telar.config.client;
export import telar.gui.input.copy_pointer;
export import telar.gui.input.key_encoder;
import telar.base.memory.containers;
import telar.wire.vocabulary;

// Interface: config/callback.cppm
export {
  namespace telar::gui {

    using BindingContext = runtime::config::BindingContext;

    struct BindingEffects {
      static constexpr std::size_t maximum_effects = 16;
      std::array<BindingAction, maximum_effects> actions{};
      std::size_t length = 0;
      std::size_t dropped = 0;
    };

    struct InputExpression {
      enum class Kind : std::uint8_t {
        consume,
        forward,
        keys,
        paste,
      };

      static constexpr std::size_t maximum_keys = 16;
      static constexpr std::size_t maximum_paste_bytes = 4096;
      Kind kind = Kind::consume;
      std::array<KeyChord, maximum_keys> keys{};
      std::size_t length = 0;
      runtime::FixedText<maximum_paste_bytes> paste;
    };

  }
}

// Interface: config/action_descriptions.cppm
export {
  namespace telar::gui {

    struct NotificationActionDescription {
      runtime::FixedText<max_notification_title_bytes> title;
      runtime::FixedText<max_notification_message_bytes> message;
      NotificationLevel level = NotificationLevel::info;
      std::uint32_t duration_ms = default_notification_duration_ms;
      NotificationTarget target;
    };

    struct DefinitionActionDescription {
      enum class Kind : std::uint8_t {
        panel,
        pick,
      };
      Kind kind = Kind::panel;
      std::uint8_t index = 0;
    };

    struct PluginActionDescription {
      std::uint64_t plugin = 0;
      std::uint64_t action = 0;
    };

    using NamedActionDescription = std::variant<DefinitionActionDescription, PluginActionDescription>;
    using ExtendedActionDescription = std::variant<NotificationActionDescription, DefinitionActionDescription, PluginActionDescription>;

  }
}
