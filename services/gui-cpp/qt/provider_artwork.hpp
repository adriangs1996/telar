#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <QImage>

namespace telar::gui::qt {

class ProviderArtwork {
public:
  [[nodiscard]] static QImage image(AgentProvider provider, int side);
  [[nodiscard]] static QImage telar(int side);
};

}
