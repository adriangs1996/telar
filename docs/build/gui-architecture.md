# Arquitectura de `src/gui`

`src/gui` se corta por casos de uso. Cuatro capas, de abajo arriba:

| Capa | Carpeta | Qué contiene | Importa, de `telar.gui.*` |
|---|---|---|---|
| foundation | `src/gui/foundation/<x>/` | Vocabulario sin casos de uso: tipos de valor, geometría, texto, fuentes, teclas, acciones, el modelo que informa el runtime, servicios del sistema | solo `telar.gui.foundation` |
| features | `src/gui/features/<x>/`, `features/terminal/<x>/` | Una feature por grupo de casos de uso relacionados; un módulo profundo cada una | solo `telar.gui.foundation` |
| application | `src/gui/application/` | La sesión de una máquina, el enrutado del protocolo del runtime, los casos de uso que cruzan features y la presentación compuesta | `telar.gui.features`, `telar.gui.foundation` |
| ui | `src/gui/ui/` | La capa Qt: controladores, ítems y QML | `telar.gui.application`, `telar.gui.foundation` |

Una feature nunca importa otra feature ni `application`; `ui` nunca importa una feature.
`tools/check-cpp-modules.py` lo comprueba (regla 9, `import_rules` en `modules.json`), junto
con el nombre (regla 1) y el namespace (regla 8) de cada módulo. Los tests pueden importar una
feature directamente para probar sus casos de uso.

## Carpeta = módulo = namespace

- `src/gui/features/history/` es el módulo `telar.gui.features.history`. Su interfaz primaria es
  `history.cppm`; cada archivo más es una partición, `history-browser.cppm` declara
  `export module telar.gui.features.history:browser;` (o `module …:browser;` si no se exporta).
- Una feature exporta en `telar::gui::features::history`, un namespace normal: quien la usa
  escribe `features::history::search(...)`.
- `foundation` exporta en namespaces inline, `export namespace telar::gui::inline foundation::inline core { … }`:
  el nombre completo `telar::gui::foundation::core::Rect` existe y refleja la carpeta, y el
  vocabulario se nombra corto (`Rect`) en todo `telar::gui`, como hasta ahora.
- `application` es un módulo, `telar.gui.application`, con una partición por feature que expone
  (`application-history.cppm`), y exporta en `telar::gui::application::<feature>`.
- Cada carpeta es un dominio de CMake, `telar_add_domain(gui features/history DEPS foundation/core …)`,
  y figura en `process_layers.gui` de `modules.json`.

## La interfaz de una feature

Una feature exporta tipos de valor y funciones de caso de uso; nada más.

```cpp
export module telar.gui.features.history;

export namespace telar::gui::features::history {

  // Value types callers hold and read.
  struct Query { … };
  struct Page { … };

  // The feature's state: opaque. Only the module's own code reaches its members.
  class State {
    friend struct Access;   // defined in a partition the module does not export
    Browser browser_;
    …
  };

  // Use cases: the only entry points. Pure: no I/O, no runtime connection, no other feature.
  // What must reach the runtime comes back as a value the caller executes.
  [[nodiscard]] Request search(State& state, const Query& query);
  void receive(State& state, const HistoryPageMessage& page);
  [[nodiscard]] const Page& page(const State& state) noexcept;

}
```

- No hay clases con métodos en la frontera: ni cadenas de llamadas, ni objetos que el llamador
  construya y configure. Las clases con estado (`Browser`, cachés) viven en particiones no
  exportadas.
- Un caso de uso recibe el estado de su feature y, si lo necesita, vocabulario de `foundation`
  (el modelo de tabs y panes, la configuración). Devuelve lo que pasó o lo que hay que pedir.

## application

`application` es la composición de las features, sin Qt:

1. `application::Session` es el estado de la conexión con un runtime: contiene el `State` de cada
   feature, el modelo replicado y la conexión.
2. Recibe cada mensaje del runtime y lo enruta al caso de uso de su feature.
3. Expone a `ui` un caso de uso por acción: `application::history::search(Session&, Query)` llama
   a `features::history::search` y ejecuta lo que devuelve (enviar la petición, avisar a otra
   feature).
4. Ejecuta los casos de uso que cruzan features (elegir un agente: `activity` resuelve el destino,
   `workbench` enfoca su pane, `peek` lo abre) y la presentación compuesta (geometría de la barra
   lateral, el frame preparado de un pane).
5. Reexporta a `ui` los tipos de valor que muestra, uno a uno: `export using features::history::Page;`
   dentro de `application::history`.

Un caso de uso de `application` es una función libre, no un método de `Session`. Llega a los
miembros de la sesión por `Access`, que `Session` declara amiga y que vive en la partición
`:access`, que el módulo no exporta: solo las unidades de `application` la importan.

```cpp
// application-access.cppm
module telar.gui.application:access;

import :session;

namespace telar::gui::application {

  struct Access {
    // One accessor per member a use case reaches; constexpr, so inline like the method it replaces.
    [[nodiscard]] static constexpr features::history::State& history(Session& session) noexcept {
      return session.history_;
    }
  };

}

// application-history.cpp
module telar.gui.application;

import :access;

namespace telar::gui::application::history {

  void search(Session& session, const features::history::Query& query) {
    auto& state = Access::history(session);

    send(session, features::history::search(state, query));
  }

}
```

- La partición `application-<feature>.cppm` declara los casos de uso exportados en
  `telar::gui::application::<feature>`; `application-<feature>.cpp`, una unidad de implementación
  del módulo, los define e importa `:access`.
- `ui` no puede nombrar `Access`: la sesión sigue opaca para ella aunque sus miembros salgan de la
  interfaz pública.

## Convenciones de una feature

`features/peek` fijó estas; las demás las copian.

**Archivos.** `peek.cppm` es la interfaz primaria: `State`, los casos de uso y `export import` de
sus particiones. Los tipos de valor y la presentación pura van en particiones exportadas por tema
(`peek-target.cppm`, `peek-presentation.cppm`). Una clase con estado (`PeekScreen`) va en una
partición de interfaz sin ninguna declaración `export` (`peek-screen.cppm`, `export module
…peek:screen;`) que la primaria reexporta: el estándar exige exportar toda partición de interfaz,
y clang avisa si una interfaz importa una partición de implementación (`module …:screen;`). Sus
nombres siguen invisibles fuera del módulo. Las definiciones van en `peek.cpp` y `peek-<tema>.cpp`.

**State y Access.** `Access` se declara sin `export` en la interfaz primaria antes de `State` y se
define después: una partición no puede importar la primaria, así que `Access` vive junto a `State`.
Así los casos de uso `inline` de la interfaz también lo usan, e importar la feature no lo hace
visible.

```cpp
namespace telar::gui::features::peek { struct Access; }

export namespace telar::gui::features::peek {
  class State { friend struct Access; … PeekScreen<Memory> screen_; };
  [[nodiscard]] std::optional<ReadPane> read(State& state, std::uint64_t request_id);
}

namespace telar::gui::features::peek {
  struct Access { static constexpr PeekScreen<Memory>& screen(State& state) noexcept { … } };
}
```

**Lo que hay que enviar.** Un caso de uso puro devuelve la petición del protocolo como valor
(`read` devuelve el `ReadPane`) o lo que el usuario pidió (`submit` devuelve una `Submission`);
recibe el id de la petición, no lo inventa. `application` pide el id (`Access::pending`), envía
(`Access::send`, `Access::sendRegistered`) y, si el transporte falla, se lo dice a la feature
(`fail`). Cada tipo de petición que `application::<feature>` registra tiene su instanciación de
`Session::sendRegistered` en `application-session-layout.cpp`, como `send` en
`application-session.cpp`.

**Lo que ui lee.** Una consulta devuelve un valor: `palette::suggestion(session)` da una
`Suggestion` con vistas al estado. Cuando ui lee mucho de una clase con estado, la feature exporta
una vista de solo lectura con los métodos `const` de la clase (`PathPickerPage` sobre el
`PathPicker` oculto), válida hasta el siguiente caso de uso.

Una vista que se lee en un camino caliente (el puntero sobre el panel de historial lee
`HistoryView`) define sus métodos `inline` en la interfaz, y `view(state)` también, para costar lo
que costaba el método al que sustituye. Las constantes que los llamadores leían de la clase oculta
salen a un tipo de valor (`HistoryLimits`).

**Tests de una clase oculta.** Un test que manejaba la clase con estado pasa por los casos de uso;
si sus aserciones usan los nombres de los métodos, un adaptador local los reenvía a los casos de uso
y a la vista (`Browser` en `history_test.cpp`), sin tocar lo que afirman.

**Fuera de las features.** Una sección que hace I/O no es pura: va a `foundation/system`
(`DirectoryCompletion` lista el sistema de archivos) o se queda en `application` (la reproducción
de sonido). Lo que una feature compone con otra aún no migrada (el workbench para `links`) lo hace
`application`, con accesores temporales en `Access` (`launchTab`, `launchSplit`, `findTab`) que
desaparecen cuando esa otra feature exista; lo que compone con una ya migrada lo hace con sus casos
de uso (`paths` escribe en la línea con `features::prompt::replace`). Lo que la sesión guarda para varias features se alcanza igual: los límites que
informa (`countLimitReach`, `limitReports`) y la conexión (`sharesImages`, `sharedImage`,
`recoverRuntime`).

Un encabezado textual que Objective-C++ o Qt incluyen (`core/wheel_accumulator.hpp`) declara sus
nombres en el namespace inline del módulo de `foundation` que lo posee
(`telar::gui::inline foundation::inline core`), y ese módulo los reexporta con `using` desde su
fragmento global (`core-wheel.cppm`). Así un fuente de Qt que incluye el encabezado después de
importar el módulo nombra una sola entidad. Reexportar desde el namespace inline nombres que el
encabezado declara en `telar::gui` los deja ambiguos en ese mismo fuente.

**Estado que ui sostiene.** Una clase con estado que no guarda la sesión sino cada ítem o ventana
de ui, y que se lee en un camino caliente, sigue exportada con sus métodos: el gesto del ratón de
un terminal (`ChildMouseGesture`), el enlace bajo el puntero (`LinkHover`), las texturas
residentes de una ventana (`ImageResidency`), el `GraphicsStore` de cada pane y el catálogo de la
estantería de adjuntos. Esconderla tras un `State` de la sesión añadiría una indirección por evento
o por frame; `application::<feature>` la reexporta con `using` como un tipo de valor más.

**Una feature sin estado de la sesión.** `terminal/input` y `terminal/attachments` no tienen
`State`: su interfaz primaria solo reexporta sus particiones, y su partición de `application`
reexporta sus tipos y, si hace falta, compone un caso de uso con la API pública de `Session`
(`application::terminal::input::scroll`).

**Casos de uso en un camino caliente.** Un caso de uso que reenvía a la clase oculta y corre por
tecla, por evento del puntero o por frame se define `inline` y `TBC_HOT_PATH` en la interfaz
primaria (`copy_mode::key`, `commit`, `clearPointer`, `follow`; `graphics::paused`), y cuesta la
llamada a la clase oculta que costaba el método de `Session`. Uno genérico sobre el llamable del
llamador (`graphics::pause`, `resume`) es una plantilla de la interfaz que reenvía a la de la clase.

**Encabezados textuales de una feature.** El encabezado que Objective-C++ comparte
(`attachments/capture.hpp`) declara en `telar::gui`; la partición que lo incluye en su fragmento
global reexporta sus nombres con `using` en el namespace de la feature, y ui, que lo incluye, los
nombra como antes. Una sección que hace I/O de la plataforma (`ClipboardImagePipe` lee un
descriptor) se queda en `platform`, que reexporta lo que entrega en vez de importar la feature.

**Estado por pane en un camino caliente.** `prompt` guarda una línea por pane, y una tecla compone
varios casos de uso sobre ella: los bloques de comandos (que siguen en `application`), la cola, la
edición y el completado. `features::prompt::open` y `find` dan un `PaneLine&` opaco, amigo de
`Access` como `State`, que los casos de uso de esa tecla reciben: la tecla busca la línea una vez,
como el método al que sustituye.

**Varias peticiones de un caso de uso.** Tab pregunta al runtime hasta once cosas. `plan` devuelve
un `CompletionPlan` opaco; `application` pide un id por pregunta, la envía (`request`), anota las que
salieron (`sent`) y devuelve el plan a la feature (`offer`), en el orden en que el método pedía los
ids. Una pregunta que solo a veces hace falta se parte en lo que ya se sabe (`presence`, `spec`), la
petición con el id que da `application` (`ask`, `askSpec`) y lo que pasó al enviarla (`asked`,
`askedSpec`). Una respuesta que puede no ser de la feature devuelve `std::optional<std::uint64_t>`:
ninguno si no es suya, 0 si no cambió nada que se vea, el pane cuya vista cambió.

**El reloj en un camino caliente.** Un caso de uso que solo a veces lee el reloj de la sesión recibe
un llamable (`prompt::output` por frame, `prompt::toProgram` por tecla), así el reloj se lee solo
cuando el método al que sustituye lo leía.

**En Session.** El estado de la feature es un miembro, `features::peek::State peek_;`, con el
nombre de la feature; `Access::peek(session)` lo da, en versión `const` y no `const`.

**Namespaces de application.** `application::<feature>` usa el nombre de la carpeta; una feature
anidada usa namespaces anidados, `features/terminal/links` es `application::terminal::links`, en
`application-terminal_links.cppm` (`:terminal_links`). Los tipos de valor conservan su nombre y se
reexportan con `using`: `ui` escribe `application::peek::PeekTarget`.

**Mensajes del runtime.** `Session::consume` sigue enrutando a su sobrecarga `apply(const M&)`; la
de un mensaje de una feature solo llama a `application::<feature>::receive(Session&, const M&)`.
Esas funciones de enrutado (`receive`, `follow`, `readFailed`) se declaran sin `export` en la misma
partición `application-<feature>.cppm`: las ven las unidades de `application`, no `ui`. Los
fallos de peticiones pendientes los reparte `apply(const RequestFailed&)` por `RequestKind`.

## ui

Los controladores Qt llaman a `application::<feature>::<caso_de_uso>(store_.session(), …)` dentro
de `Store::interact`, y releen con las consultas de `application` cuando el store notifica un
cambio.

## Rendimiento

Lo que se ejecuta por frame o por tecla (preparar y presentar frames, codificar teclas, leer filas)
no gana llamadas indirectas, asignaciones ni copias: las consultas devuelven referencias o vistas
constantes y son `inline` (`TBC_HOT_PATH` si están en una interfaz). Un caso de uso en un camino
caliente cuesta lo mismo que el método al que sustituye.

## Reparto

`gui-features.md` y `gui-features.json` asignan cada sección `// Interface:` de los módulos
anteriores a su carpeta.
