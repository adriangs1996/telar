module telar.gui.ui.kit.scene.optical_text;

#if !defined(Q_OS_MACOS)

namespace telar::gui::qt {
  std::unique_ptr<OpticalText> OpticalText::create() {
    return nullptr;
  }
} // namespace workbench
#endif
