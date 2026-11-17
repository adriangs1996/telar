export module telar.gui.foundation.actions:action_descriptions;

import std;

import telar.config.client;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import :binding;
import :binding_effects;

// Interface: config/action_descriptions.cppm
export {
  namespace telar::gui::inline foundation::inline actions {

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
