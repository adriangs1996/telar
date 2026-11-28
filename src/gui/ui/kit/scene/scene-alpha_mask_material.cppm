export module telar.gui.ui.kit.scene:alpha_mask_material;

import telar.gui.qt;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  enum class AlphaMaskSampling : unsigned char {
    standard,
    stable_nearest,
    // Box-filters the texels under each screen pixel: for oversampled or transformed icons.
    filtered,
  };

  enum class AlphaMaskBlend : unsigned char {
    premultiplied,
    straight,
  };

  class AlphaMaskMaterial final : public QSGMaterial {
  public:
    AlphaMaskMaterial(QSGTexture& texture, Color foreground, AlphaMaskSampling sampling = AlphaMaskSampling::standard, AlphaMaskBlend blend = AlphaMaskBlend::premultiplied) noexcept;
    [[nodiscard]] QSGMaterialType* type() const override;
    [[nodiscard]] QSGMaterialShader* createShader(QSGRendererInterface::RenderMode render_mode) const override;
    [[nodiscard]] int compare(const QSGMaterial* other) const override;
    [[nodiscard]] QSGTexture& texture() const noexcept;
    [[nodiscard]] Color foreground() const noexcept;
    [[nodiscard]] AlphaMaskBlend blend() const noexcept;
    void setForeground(Color foreground) noexcept;

  private:
    QSGTexture& texture_;
    Color foreground_;
    AlphaMaskSampling sampling_ = AlphaMaskSampling::standard;
    AlphaMaskBlend blend_ = AlphaMaskBlend::premultiplied;
  };

}
