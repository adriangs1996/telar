export module telar.gui.ui.design.controls:form_composition_events;

import std;
import telar.gui.qt;
import telar.gui.qt.platform;

export namespace telar::gui::qt {

  class NativeFormField;

  template <typename Receiver>
  concept CompositionReceiver = requires(Receiver& receiver) {
    { receiver.window() } -> std::convertible_to<QWindow*>;
    { receiver.hasActiveFocus() } -> std::same_as<bool>;
    { receiver.cancelComposition() } -> std::same_as<bool>;
  };

  [[tbc::generic]] [[nodiscard]] bool cancelNativeComposition(CompositionReceiver auto& receiver, std::string_view event_type, const void* message) {
    const QWindow* const window = receiver.window();

    return window != nullptr && receiver.hasActiveFocus() &&
           platform::isCompositionCancellation(event_type, message, *window) &&
           receiver.cancelComposition();
  }

  class FormCompositionEvents final : public QAbstractNativeEventFilter {
  public:
    explicit FormCompositionEvents(NativeFormField& receiver);
    void setActive(bool active);
    bool nativeEventFilter(const QByteArray& event_type, void* message, qintptr* result) override;

  private:
    NativeFormField& receiver_;
    bool installed_ = false;
  };

  class InactiveCompositionEvents {
  public:
    [[tbc::hot_path]] inline explicit InactiveCompositionEvents([[maybe_unused]] NativeFormField& receiver) noexcept {}

    [[tbc::hot_path]] inline void setActive([[maybe_unused]] bool active) noexcept {}
  };

  using ActiveCompositionEvents = std::conditional_t<platform::native_composition_events, FormCompositionEvents, InactiveCompositionEvents>;

}
