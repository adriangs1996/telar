export module telar.gui.ui.design.controls:provider_artwork;

import telar.gui.qt;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  class ProviderArtwork {
  public:
    [[nodiscard]] static QImage image(AgentProvider provider, int side);
    // `theme` is a ThemeName; a theme without its own colored mark draws the default one.
    [[nodiscard]] static QImage telar(int side, bool monochrome = true, int theme = -1);
    // One of the bundled line icons, drawn in black for the caller to tint; null for an unknown name.
    [[nodiscard]] static QImage symbol(QStringView name, int side);

  private:
    [[nodiscard]] static QImage vector(const QString& source, int side);
  };

}
