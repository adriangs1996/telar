module;
#include <QColor>
#include <QGuiApplication>
#include <QMetaObject>
#include <QMetaProperty>
#include <QMetaType>
#include <QObject>
#include <QPointF>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QString>
#include <QUrl>
#include <QVariant>
#include <QtCore/qflags.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmochelpers.h>
#include <QtCore/qtypes.h>
#include <QtQml/qqml.h>
#include <QtQml/qqmlmoduleregistration.h>
#include <QtTest/QSignalSpy>

export module telar.qt;

import std;

export {
  using ::QColor;
  using ::QFlags;
  using ::QGuiApplication;
  using ::QMetaClassInfo;
  using ::QMetaMethod;
  using ::QMetaObject;
  using ::QMetaProperty;
  using ::QMetaType;
  using ::QObject;
  using ::QPointF;
  using ::QQmlComponent;
  using ::QQmlEngine;
  using ::QQmlModuleRegistration;
  using ::QQuickItem;
  using ::QQuickWindow;
  using ::QRectF;
  using ::QSGNode;
  using ::QSignalSpy;
  using ::QString;
  using ::QUrl;
  using ::QVariant;
  using ::qReturnArg;
  using ::qobject_cast;
  using ::qmlRegisterAnonymousType;
  using ::qmlRegisterEnum;
  using ::qmlRegisterModule;
  using ::qmlRegisterNamespaceAndRevisions;
  using ::qmlRegisterTypesAndRevisions;
  using ::qreal;
  using ::qsizetype;
  using ::operator|;

  namespace Qt {
    using ::Qt::transparent;
    inline namespace StringLiterals {
      using ::Qt::StringLiterals::operator""_s;
      using ::Qt::StringLiterals::operator""_ba;
    }
  }

  namespace QtMocConstants {
    using ::QtMocConstants::AccessPrivate;
    using ::QtMocConstants::AccessProtected;
    using ::QtMocConstants::AccessPublic;
    using ::QtMocConstants::Constant;
    using ::QtMocConstants::DefaultPropertyFlags;
    using ::QtMocConstants::EnumFlags;
    using ::QtMocConstants::EnumIsScoped;
    using ::QtMocConstants::EnumOrFlag;
    using ::QtMocConstants::Final;
    using ::QtMocConstants::MetaObjectFlag;
    using ::QtMocConstants::PropertyAccessInStaticMetaCall;
    using ::QtMocConstants::Required;
    using ::QtMocConstants::Resettable;
    using ::QtMocConstants::StdCppSet;
    using ::QtMocConstants::Writable;
  }

  namespace QtMocHelpers {
    using ::QtMocHelpers::ClassInfos;
    using ::QtMocHelpers::EnumData;
    using ::QtMocHelpers::MethodData;
    using ::QtMocHelpers::PropertyData;
    using ::QtMocHelpers::SignalData;
    using ::QtMocHelpers::SlotData;
    using ::QtMocHelpers::StringRefStorage;
    using ::QtMocHelpers::UintData;
    using ::QtMocHelpers::indexOfMethod;
    using ::QtMocHelpers::metaObjectData;
  }
}

export namespace telar::qt {

  template <typename Read, typename Write = std::nullptr_t, typename Notify = std::nullptr_t, typename Reset = std::nullptr_t>
  struct PropertyDesc {
    const char* name;
    Read read;
    Write write = nullptr;
    Notify notify = nullptr;
    Reset reset = nullptr;
    bool is_constant = false;
    bool is_final = false;
    bool is_required = false;

    template <typename NewReset>
    constexpr auto withReset(NewReset fn) const noexcept {
      return PropertyDesc<Read, Write, Notify, NewReset>{name, read, write, notify, fn, is_constant, is_final, is_required};
    }

    constexpr auto constant() const noexcept {
      auto copy = *this;

      copy.is_constant = true;
      return copy;
    }

    constexpr auto finalProperty() const noexcept {
      auto copy = *this;

      copy.is_final = true;
      return copy;
    }

    constexpr auto required() const noexcept {
      auto copy = *this;

      copy.is_required = true;
      return copy;
    }
  };

  template <typename Read, typename Write = std::nullptr_t, typename Notify = std::nullptr_t, typename Reset = std::nullptr_t>
  constexpr PropertyDesc<Read, Write, Notify, Reset> property(
      const char* name,
      Read read,
      Write write = nullptr,
      Notify notify = nullptr,
      Reset reset = nullptr
  ) noexcept {
    return {name, read, write, notify, reset, false, false, false};
  }

  template <typename... Props>
  struct PropertyList {};

  template <typename Head, typename... Tail>
  struct PropertyList<Head, Tail...> {
    Head head;
    PropertyList<Tail...> tail;
  };

  constexpr PropertyList<> properties() noexcept {
    return {};
  }

  template <typename Head, typename... Tail>
  constexpr PropertyList<Head, Tail...> properties(Head head, Tail... tail) noexcept {
    return {head, properties(tail...)};
  }

}
