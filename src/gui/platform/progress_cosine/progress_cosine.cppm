export module telar.gui.platform.progress_cosine;

export {
  namespace telar::gui::platform {

    struct ProgressCosine {
      [[nodiscard]] static float evaluate(float angle) noexcept;
    };

  }
}
