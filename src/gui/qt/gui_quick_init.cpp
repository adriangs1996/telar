#include <QtCore/qtsymbolmacros.h>

QT_DECLARE_EXTERN_RESOURCE(qmlcache_gui_quick)
QT_DECLARE_EXTERN_RESOURCE(qmake_Telar_Gui)
QT_DECLARE_EXTERN_RESOURCE(gui_quick_raw_qml_0)
QT_DECLARE_EXTERN_RESOURCE(gui_quick_raw_qml_0_extra_qmldirs)
QT_DECLARE_EXTERN_SYMBOL_VOID(qml_register_types_Telar_Gui)

namespace {

  struct KeepTelarGuiQml {
    KeepTelarGuiQml() noexcept {
      QT_KEEP_SYMBOL(qml_register_types_Telar_Gui)
      QT_KEEP_RESOURCE(qmlcache_gui_quick)
      QT_KEEP_RESOURCE(qmake_Telar_Gui)
      QT_KEEP_RESOURCE(gui_quick_raw_qml_0)
      QT_KEEP_RESOURCE(gui_quick_raw_qml_0_extra_qmldirs)
    }
  };

  const KeepTelarGuiQml keep_telar_gui_qml{};

}
