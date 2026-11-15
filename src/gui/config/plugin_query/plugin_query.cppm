export module telar.gui.config.plugin_query;

import std;
import telar.tbc;

import telar.gui.input.key_encoder;

import telar.gui.input.copy_pointer;
import telar.config.client;

import telar.gui.core.json_writer;

import telar.gui.input.binding_effects;
import telar.gui.input.configuration;

import telar.plugins;
import telar.base.diagnostics;
import telar.gui.config.gui_query;
import telar.gui.core.primitives;
import telar.gui.core.unicode_scalar;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

// Interface: config/action_descriptions.cppm
export {
  namespace telar::gui {

    template <Allocator Memory>
    class ActionDescriptions {
    public:
      explicit ActionDescriptions(Memory& memory);

      void replaceBindings() noexcept;

      [[nodiscard]] const ExtendedActionDescription& at(std::int32_t index) const;

      void replaceDefinition(std::int32_t index, DefinitionActionDescription definition);

      std::int32_t retain(const ExtendedActionDescription& description);

      std::int32_t registerCallback();

    private:
      static constexpr std::size_t compiled_client_sections = 2;
      static constexpr std::size_t maximum_callbacks = compiled_client_sections * BindingLimits::bindings;

      Vector<ExtendedActionDescription, Memory> extended_;
      std::size_t callbacks_ = 0;
    };

    extern template class ActionDescriptions<telar::Memory>;
    extern template class ActionDescriptions<telar::ConcurrentMemory>;

  }
}

// Interface: config/command_tab_action.cppm
export {
  namespace telar::gui {

    [[nodiscard]] BindingAction commandTabAction(runtime::config::CommandTabReference reference, std::uint64_t generation) noexcept;

    [[nodiscard]] std::optional<runtime::config::CommandTabReference> commandTabReference(BindingAction action) noexcept;

  }
}

// Interface: config/action_query.cppm
export {
  namespace telar::gui {

    class ActionQuery {
    public:
      template <Allocator Memory>
      static void write(JsonWriter& writer, BindingAction action, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

    private:
      template <typename Value>
      static void writeValue(JsonWriter& writer, std::string_view type, const Value& value);

      struct NamedAction {
        BindingActionKind kind;
        std::string_view type;
        std::string_view value;
      };

      static bool writeNamed(JsonWriter& writer, BindingActionKind kind);
      static void writeNumeric(JsonWriter& writer, BindingAction action);
      static void writeStoredCommand(JsonWriter& writer, runtime::config::CommandTabReference reference, const runtime::config::RetainedCommandTabRegistry& commands);
      static void writeCommand(JsonWriter& writer, const runtime::config::CommandTabView& command);
      static void writeArguments(JsonWriter& writer, std::span<const std::string_view> arguments);
      static void writeExtended(JsonWriter& writer, const NotificationActionDescription& description);
      static void writeNotification(JsonWriter& writer, const NotificationActionDescription& description);
      static void emptyObject(JsonWriter& writer);
      static void writeTarget(JsonWriter& writer, NotificationTarget target);
      static void writeExtended(JsonWriter& writer, DefinitionActionDescription description);
      static void writeExtended(JsonWriter& writer, PluginActionDescription description);
    };

    extern template void ActionQuery::write<telar::Memory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);
    extern template void ActionQuery::write<telar::ConcurrentMemory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

  }
}

// Interface: config/input_query.cppm
export {
  namespace telar::gui {

    class InputQuery {
    public:
      // Each query is written into the output, region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const InputConfiguration& input, tbc::view<std::span<char>, tbc::lt::a> output);

      static void writeKey(JsonWriter& writer, KeyChord key);

    private:
      static void writeCode(JsonWriter& writer, KeyChord key);
      static void writeEmptyObject(JsonWriter& writer);
      static void writeCharacter(JsonWriter& writer, KeyChord key);
      static std::string_view keyName(KeyChord::Key key);
    };

  }
}

// Interface: config/binding_query.cppm
export {
  namespace telar::gui {

    class BindingQuery {
    public:
      template <Allocator Memory>
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const InputConfiguration& input, std::size_t index, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static void writeKeys(JsonWriter& writer, std::span<const KeyChord> keys);
    };

    extern template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::Memory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);
    extern template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::ConcurrentMemory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

  }
}

// Interface: config/plugin_overrides.cppm
export {
  namespace telar::gui {

    class PluginOverrides {
    public:
      void set(const runtime::plugins::ConfiguredPlugin& specification, std::optional<std::uint64_t> identity);

      [[nodiscard]] std::optional<bool> requested(std::string_view path) const noexcept;

      void apply(runtime::plugins::Specifications& specifications) const noexcept;

      [[nodiscard]] bool disabled(std::uint64_t identity, std::span<const runtime::plugins::ConfiguredPlugin> specifications) const noexcept;

    private:
      struct Entry {
        runtime::plugins::ConfiguredPlugin specification;
        std::optional<std::uint64_t> identity;
      };

      std::array<Entry, runtime::plugins::PackageLimits::configured> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: config/plugin_catalog.cppm
export {
  namespace telar::gui {

    class PluginCatalog {
    public:
      explicit PluginCatalog(std::uint64_t generation, std::span<const runtime::plugins::ConfiguredPlugin> specifications, std::span<const runtime::plugins::Package> packages, const PluginOverrides* overrides = nullptr) noexcept;

      [[nodiscard]] std::uint64_t generation() const noexcept;

      [[nodiscard]] std::size_t size() const noexcept;

      [[nodiscard]] const runtime::plugins::ConfiguredPlugin& specification(std::size_t index) const;

      [[nodiscard]] const runtime::plugins::Package* package(std::size_t index) const noexcept;

      [[nodiscard]] bool requestedEnabled(std::size_t index) const;

      [[nodiscard]] std::size_t find(std::string_view name) const;

      void validateGeneration(std::uint64_t requested) const;

      [[nodiscard]] const runtime::plugins::Package& resolve(const PluginActionDescription& requested) const;

    private:
      std::uint64_t generation_;
      std::span<const runtime::plugins::ConfiguredPlugin> specifications_;
      std::span<const runtime::plugins::Package> packages_;
      const PluginOverrides* overrides_;
    };

  }
}

// Interface: config/plugin_query.cppm
export {
  namespace telar::gui {

    struct PluginPage {
      std::string_view text;
      std::int64_t next = -1;
    };

    class PluginQuery {
    public:
      // A page is written into the output, region `a`.
      [[nodiscard]] static tbc::view<PluginPage, tbc::lt::a> list(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output);

      [[nodiscard]] static tbc::view<PluginPage, tbc::lt::a> get(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      template <typename Entries>
      static void writePage(JsonWriter& writer, std::uint64_t generation, Entries&& entries);

      [[nodiscard]] static std::size_t page(std::int64_t value, std::size_t maximum);
      static void listEntry(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index);
      static void metadata(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index);
      static void writeCapabilities(JsonWriter& writer, runtime::plugins::Capabilities capabilities);
      static void digest(JsonWriter& writer, const runtime::plugins::PackageDigest& digest);
    };

  }
}
