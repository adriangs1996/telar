#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <cstdint>

class QQuickWindow;

namespace telar::gui::probe {

void observeAnimationPresentation();
void recordAnimationPresentation(std::uint64_t cycle, double value);
QJsonArray animationPresentations();
QJsonObject animationDisplay(const QQuickWindow &window);

}
