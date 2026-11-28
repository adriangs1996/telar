export module telar.gui.tests.appearance_fixture;

import telar.gui.qt;

export namespace telar::gui::test {

  class AppearanceFixture {
  public:
    AppearanceFixture()
        : original_(QGuiApplication::styleHints()->colorScheme()) {}

    ~AppearanceFixture() {
      set(original_);
    }

    AppearanceFixture(const AppearanceFixture&) = delete;
    AppearanceFixture& operator=(const AppearanceFixture&) = delete;
    AppearanceFixture(AppearanceFixture&&) = delete;
    AppearanceFixture& operator=(AppearanceFixture&&) = delete;

    static void set(Qt::ColorScheme scheme) {
      QGuiApplication::styleHints()->colorSchemeChanged(scheme);
    }

  private:
    Qt::ColorScheme original_;
  };

}
