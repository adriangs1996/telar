#pragma once

class QWindow;

namespace telar::gui::test {

void activateApplication();
void configureComponentWindow(QWindow &window);
void activateWindow(QWindow &window);

}
