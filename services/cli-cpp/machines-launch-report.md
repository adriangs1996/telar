# Entrega: máquinas y arranque de la CLI C++

Rama `cli-port-machines-launch`, desde `2c0ee1e9d`. La implementación no lee
`src/`, ejecuta Zig ni incluye código de los servicios GUI/runtime. No cambia
el protocolo ni la GUI. Los scripts comparativos admiten un Zig externo como
oráculo; los tests de CTest conservan los contratos sin él.

## Estado

**done**: `machine add/list/check/remove/rename/enable/disable/receive-config`,
`--machine LABEL COMMAND...`, `dispatch-argv`, `cli install/status/uninstall`,
`gui`, arranque sin argumentos o con un comando, sus opciones de configuración,
perfil, tema, fresh y selección remota, y las diferencias de `integration`.

**partial**: `machine setup`. Están implementados los diez pasos: acceso SSH,
sonda de plataforma, instalación, runtime, perfil, agentes, integración,
configuración, login y comprobación final. Se han comparado configuración y
ciclo de login con Zig, e instalado una distribución C++ real por SSH a localhost.
Quedan estas fronteras de verificación/integración:

- No se ha iniciado sesión con cuentas reales en proveedores ni ejecutado sus
  instaladores públicos. Confirmación interactiva de host/login y sustitución
  consentida de un runtime anterior están implementadas, pero no comparadas con
  una persona respondiendo desde un terminal. Los casos automatizados cubren
  login autenticado, pendiente, terminado, fallido, desaparecido y SSH fallido.
- El login ejecuta los comandos remotos `workspace create/list`, `tab get/close`
  y `pane read/send-keys`. Deben integrarse los paquetes sessions/panes para que
  esos caminos funcionen en una instalación compuesta enteramente por esta
  rama. No hay fallback a Zig.
- La descarga de releases implementa pinning de SHA-256 y exige los acompañantes
  C++. No se ha probado un archivo publicado de release C++; el empaquetado
  existente debe incluir `telar-runtime` y `telar-launch.so` junto a `telar`.
  Se rechaza un archivo que no los incluya. La instalación verificada usa
  `--binary` y los tres artefactos construidos aquí.

No queda un comando de este paquete clasificado como `unverified`; las rutas de
setup anteriores son las que mantienen ese comando en `partial`.

## Comprobaciones

| Comprobación | Resultado |
| --- | --- |
| `tools/check_machines_launch.py` | 143/143 casos coinciden con Zig: argumentos, texto/JSON, stderr, estados, enlaces, perfiles, modos y recepción de configuración. |
| `tools/check_machine_setup.py` | 15/15 escenarios, dos ejecuciones por escenario, coinciden: cinco proveedores, JSONC/TOML, secretos, hooks, symlinks, errores y seis estados de login. |
| `tools/check_integration.py` | 68/68 escenarios coinciden, ahora incluyendo stderr. Los ficheros JSON se comparan como JSON, como ya hacía este comparador. |
| `tools/check_window_parity.py` | Cuatro ventanas reales Zig/C++ coinciden: sin argumentos, comando, gui y config/profile. Se comprueba salida, terminación y supervivencia de runtime/hijo. |
| `tools/check_window_launch.py` | Resolución hermano/bundle, argv literal, login shell, configuración/perfil/tema, fresh, máquina guardada y GUI Qt real. |
| `tools/check_machine_ssh.py` | Siete comprobaciones con sshd/llaves/perfiles privados: argv, stdin, stderr/estado, instalación idempotente, reparación del módulo, ruta instalada y ventana remota real. |
| CTest del runtime | 41/41, secuencial, Release. Incluye ayuda intacta y tres tests nuevos de CLI/carga del módulo. |
| Instalación CMake en prefijo privado | CLI, runtime y módulo instalados; `machine list --json` funciona desde ese prefijo. |
| `tools/measure_launch_hook.py` | 50 muestras pareadas por binario: p50 5,274 ms antes y 5,314 ms después (+0,75%, 0,040 ms). Mismos informes del hook. |

Los resultados completos están en el scratch de esta tarea:
`~/sandbox/cli-port-scratch/cli-port-machines-launch/` (`machines-final.json`,
`setup-final.json`, `integration-final.json`, `window-parity.json`,
`window-final.json`, `ssh-final.json`, `runtime-ctest-final.log`,
`hook-final.json`, `install.log`). Los golden de los tests nuevos están en
`tests/`, no dependen de ese directorio ni de Zig.

El primer CTest encontró el límite blando de 2560 descriptores del proceso:
`platform_test.cpp:165` pide el descriptor 4096. El lanzador aislado eleva solo
su propio límite a 8192. La repetición individual y la suite completa pasan.

La primera compilación Zig falló en su libc++ (`INFINITY` no declarado).
Se copió libc++ al scratch, sustituyendo esa referencia por
`__builtin_huge_val()`, y se indicó `--zig-lib-dir` privado. No se modificó
el toolchain del agente de rendimiento ni una fuente Zig del repositorio.

## Decisiones de distribución y rendimiento

`telar-launch.so` contiene el código de máquinas/instaladores/configuración y
arranque de ventana. Se carga mediante `dlopen` únicamente para esas entradas y
valida un identificador de ABI. Se instala junto al ejecutable real; un enlace
creado con `cli install` sigue funcionando porque se resuelve primero ese
ejecutable. `hook`, ayuda y bootstrap del runtime no necesitan el módulo;
`launch-loader-tests` lo comprueba con una copia sin módulo. El ejecutable
mantiene las mismas cuatro bibliotecas dinámicas que la base y crece de 992 a
994 KiB. La primera variante enlazada directamente medía entre un 4 y un 7%
más de latencia; separar la carga devuelve la medida prácticamente a la base.

Para encontrar la GUI: `telar-gui` hermano, después
`../../MacOS/telar-gui`, después PATH. Esto invierte la búsqueda de CLI de
`services/gui-cpp/platform/runtime_endpoint.cpp:109`: una CLI en
`Contents/Resources/bin` encuentra la GUI en `Contents/MacOS`.
Se hace exec con argv literal, cwd y socket seleccionados. `--fresh` se aplica
al arranque del runtime, además de a la restauración de diseño de la GUI.

La distribución de `--binary` necesita los tres ficheros. Su directorio de
versión suma los prefijos SHA-256 de CLI, runtime y módulo, puesto que los
acompañantes pueden cambiar sin cambiar el pequeño ejecutable. Cada transferencia
se escribe temporalmente con modo privado, verifica el hash y reemplaza su
acompañante. Una repetición reconoce bytes idénticos y repara un acompañante
que falta. Es una diferencia de empaquetado necesaria respecto al único binario
Zig, documentada también en README y parity.

## Piezas comunes y referencias de comportamiento

- `dlls/telar-client/include/telar_client/machines/`: perfiles, validación,
  identidad, codec JSON y sonda/comandos remotos, bajo `runtime::machines`.
  Son una adaptación sin Qt de los helpers ya presentes en la GUI. La GUI
  sigue con sus originales; el coordinador puede unificar sus imports después.
- `launch_commands.hpp/.cpp`, `launch_commands_loader.cpp`: entradas y carga
  diferida; `CommandError` preserva el prefijo `error:` de errores de ejecución.
- `launch_process.hpp`: spawn, exec, captura limitada con timeout y entrada en
  un fichero privado desenlazado; streams SSH heredados explícitamente en macOS.
- `machine_store.hpp`, `machine_ssh.hpp`, `config_receive.hpp` y `machines/`:
  edición bajo lock, base64url, SSH administrado, instalación y filtros/logins.
- `integration/assets/`: copias propias de extensiones y skills; CMake ya no
  busca los assets en `src/cli`.

Referencias Zig usadas: `src/cli/arguments/MachineOptions.zig:34`,
`CliOptions.zig:12`, `RunOptions.zig:22`, `GuiOptions.zig:15`,
`src/cli/machine_profiles.zig:26`, `machine_dispatch.zig:32`,
`dispatch_argv.zig:14`, `machine_setup.zig:87`, `config_receive.zig:37`,
`config_sync.zig:250`, `config_filter.zig:78`, `config_secrets.zig:126`,
`agent_setup.zig:125`, `agent_login.zig:147`, `cli_install.zig:13`,
`client.zig:20` y `integration_support.zig:121`.

La verificación final usó HOME/XDG/TMP/socket privados y limpió el contexto
TELAR heredado. Los procesos lanzados y los directorios temporales de pruebas
se han cerrado/eliminado. No se instalaron comandos en el PATH real ni se
cambiaron los perfiles o el runtime de Adrian; no hay merge ni push.
