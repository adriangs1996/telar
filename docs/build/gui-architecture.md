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
