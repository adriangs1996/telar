export module telar.gui.ui.kit.scene:alpha_mask;

import std;
import telar.gui.qt;

export namespace telar::gui::qt {

  class AlphaMask final : public QSharedData {
  public:
    [[tbc::hot_path]] inline AlphaMask(QImage mask, std::unique_ptr<QSGTexture> mask_texture)
        : alpha(std::move(mask)),
          texture(std::move(mask_texture)) {}

    const QImage alpha;
    const std::unique_ptr<QSGTexture> texture;
  };

  using AlphaMaskRef = QExplicitlySharedDataPointer<AlphaMask>;

}
