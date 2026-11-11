#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <QImage>

namespace telar::gui::qt {

class ProviderArtwork {
public:
  [[nodiscard]] static QImage image(AgentProvider provider, int side);
  // `theme` is a ThemeName; a theme without its own colored mark draws the default one.
  [[nodiscard]] static QImage telar(int side, bool monochrome = true, int theme = -1);
};

}
