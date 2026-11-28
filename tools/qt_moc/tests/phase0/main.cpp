import std;
import telar.qt;
import telar.phase0.rounded_rect;

using namespace Qt::StringLiterals;
using telar::gui::qt::NativeRoundedRectangle;

namespace {

  void require(bool condition, const char* message) {
    if (!condition) {
      std::cerr << "FAIL: " << message << "\n";
      std::exit(1);
    }
  }

}

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);

  // 1. qobject_cast verifies Qt 6.12 HasQ_OBJECT_Macro<NativeRoundedRectangle>::Value == true.
  NativeRoundedRectangle direct;
  QObject* base = &direct;
  auto* cast_back = qobject_cast<NativeRoundedRectangle*>(base);

  require(cast_back == &direct, "qobject_cast<NativeRoundedRectangle*> succeeded");

  // 2. QMetaObject introspection: className, classInfo, properties, signals, invokable.
  const QMetaObject* meta = direct.metaObject();

  require(std::string_view(meta->className()) == "telar::gui::qt::NativeRoundedRectangle", "meta->className()");
  const int info_idx = meta->indexOfClassInfo("QML.Element");

  require(info_idx >= 0 && std::string_view(meta->classInfo(info_idx).value()) == "auto", "QML.Element classInfo");

  // 3. Property read/write/reset + QSignalSpy.
  QSignalSpy clip_spy(&direct, &NativeRoundedRectangle::paintClipChanged);
  QSignalSpy color_spy(&direct, &NativeRoundedRectangle::colorChanged);

  require(clip_spy.isValid() && color_spy.isValid(), "QSignalSpy valid");
  require(direct.setProperty("color", QVariant::fromValue(QColor(0x11, 0x22, 0x33))), "setProperty(color)");
  require(direct.color() == QColor(0x11, 0x22, 0x33), "color updated");
  require(color_spy.size() == 1, "colorChanged emitted once");

  const QRectF clip_rect{1, 2, 30, 40};

  require(direct.setProperty("paintClip", QVariant::fromValue(clip_rect)), "setProperty(paintClip)");
  require(direct.property("paintClip").value<QRectF>() == clip_rect, "property(paintClip) round-trips");
  require(clip_spy.size() == 1, "paintClipChanged emitted on write");

  const int clip_prop_idx = meta->indexOfProperty("paintClip");

  require(clip_prop_idx >= 0, "indexOfProperty(paintClip)");
  require(meta->property(clip_prop_idx).reset(&direct), "QMetaProperty::reset(paintClip)");
  require(direct.paintClip() == QRectF{}, "paintClip reset to empty");
  require(clip_spy.size() == 2, "paintClipChanged emitted on reset");

  // 4. Q_INVOKABLE via QMetaObject::invokeMethod.
  direct.setRadius(10);
  direct.setBorderWidth(2.5);
  qreal effective = 0;

  require(QMetaObject::invokeMethod(&direct, "effectiveRadius", qReturnArg(effective)), "invokeMethod(effectiveRadius)");
  require(effective == 12.5, "effectiveRadius == 12.5");

  // 5. Real QML instantiation via QQmlComponent + QML property bindings + QML signal handler.
  QQmlEngine engine;
  QQmlComponent component(&engine);

  component.setData(
      "import Telar.Phase0 1.0\n"
      "NativeRoundedRectangle {\n"
      "  property int radiusChanges: 0\n"
      "  color: '#445566'\n"
      "  radius: 14\n"
      "  borderWidth: 3\n"
      "  onRadiusChanged: radiusChanges += 1\n"
      "}\n"_ba,
      QUrl()
  );

  require(component.isReady(), component.errorString().toUtf8().constData());
  std::unique_ptr<QObject> instance(component.create());

  require(instance != nullptr, "QQmlComponent::create() returned object");
  auto* qml_rect = qobject_cast<NativeRoundedRectangle*>(instance.get());

  require(qml_rect != nullptr, "QML instance qobject_cast to NativeRoundedRectangle");
  require(qml_rect->color() == QColor(0x44, 0x55, 0x66), "QML color binding");
  require(qml_rect->radius() == 14, "QML radius binding");
  require(qml_rect->effectiveRadius() == 17, "QML invokable/properties");

  qml_rect->setRadius(20);
  require(qml_rect->property("radiusChanges").toInt() >= 1, "QML onRadiusChanged handler fired");

  std::cout << "PASS: phase0 vertical prototype (qobject_cast, QMetaObject, properties, reset, QSignalSpy, invokable, QQmlComponent)\n";
  return 0;
}
