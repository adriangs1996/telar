const { ipcRenderer } = require("electron");

function report(event, details = {}) {
  ipcRenderer.send("telar-verification", { event, ...details });
}

window.addEventListener("DOMContentLoaded", () => report("page-loaded"), { once: true });
window.addEventListener("keydown", (event) => report("key", { key: event.key }));
window.addEventListener("beforeinput", (event) => report("text-input", { data: event.data }));
window.addEventListener("pointerdown", (event) => report("pointer", {
  x: event.clientX,
  y: event.clientY,
  button: event.button,
}));

setTimeout(() => {
  report("completed");
  globalThis.terminalBrowser.quit();
}, 8000);
