// What a render produced, read on the interpreter's thread so the window never reads it: the
// content or the element tree, and what each action it holds means.
export module telar.gui.features.components:rendered;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.config.client;
import telar.gui.foundation.actions;
import :content;
import :elements;
import telar.base.ds;

// Interface: components/rendered_content.cppm
export {
  namespace telar::gui::features::components {

    // A command tab that outlives the Lua thread's registry row it was read from.
    class CommandTabCopy {
    public:
      using View = runtime::config::CommandTabView;

      explicit CommandTabCopy(const View& view);

      [[nodiscard]] View view() const noexcept;

    private:
      ds::Array<char, View::maximum_argument_bytes + View::maximum_label_bytes> bytes_{};
      ds::Array<std::uint16_t, View::maximum_arguments> lengths_{};
      std::size_t count_ = 0;
      std::uint16_t label_ = 0;
    };

    // What an action produced by Lua means, read on the Lua thread so the window never reads the VM.
    struct ResolvedAction {
      BindingAction action;
      ds::Option<ExtendedActionDescription> description = ds::none;
      ds::Option<CommandTabCopy> command = ds::none;
    };

    template <Allocator Memory>
    class ResolvedActions {
    public:
      explicit ResolvedActions(Memory& memory);

      void add(ResolvedAction entry);

      [[nodiscard]] const ResolvedAction* find(BindingAction action) const noexcept;

      [[nodiscard]] bool contains(BindingAction action) const noexcept;

    private:
      Vector<ResolvedAction, Memory> entries_;
    };

    template <Capacity Bounds, Allocator Memory>
    struct RenderedContent {
      explicit RenderedContent(Memory& memory);

      Content<Bounds> content;
      ResolvedActions<Memory> actions;
    };

    template <Allocator Memory>
    struct ResolvedEffects {
      explicit ResolvedEffects(Memory& memory);

      BindingEffects effects;
      ResolvedActions<Memory> actions;
    };

    extern template class ResolvedActions<telar::Memory>;
    extern template class ResolvedActions<telar::ConcurrentMemory>;
    extern template struct RenderedContent<bar_capacity, telar::Memory>;
    extern template struct RenderedContent<panel_capacity, telar::Memory>;
    extern template struct RenderedContent<bar_capacity, telar::ConcurrentMemory>;
    extern template struct RenderedContent<panel_capacity, telar::ConcurrentMemory>;
    extern template struct ResolvedEffects<telar::Memory>;
    extern template struct ResolvedEffects<telar::ConcurrentMemory>;

  }
}

// Interface: components/rendered_elements.cppm
export {
  namespace telar::gui::features::components {

    template <Allocator Memory>
    struct RenderedElements {
      explicit RenderedElements(Memory& memory);

      [[nodiscard]] std::string_view view(ElementText range) const noexcept;

      Vector<Element, Memory> elements;
      String<Memory> text;
      Vector<CanvasStep, Memory> steps;
      // Element `action` indices name these; `actions` holds what each one means.
      Vector<BindingAction, Memory> bindings;
      ResolvedActions<Memory> actions;
      // Lua handlers this render registered for `on_click` functions, by element `callback`.
      std::uint32_t callbacks = 0;
    };

    extern template struct RenderedElements<telar::Memory>;
    extern template struct RenderedElements<telar::ConcurrentMemory>;

  }
}
