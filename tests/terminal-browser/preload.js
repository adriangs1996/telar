const { ipcRenderer } = require("electron");

function report(event, details = {}) {
  ipcRenderer.send("telar-verification", { event, ...details });
}

window.addEventListener("DOMContentLoaded", () => {
  document.querySelector("#keyboard-input").focus();
  report("page-loaded");
}, { once: true });
window.addEventListener("keydown", (event) => report("key", { key: event.key }));
window.addEventListener("beforeinput", (event) => report("text-input", { data: event.data }));
window.addEventListener("input", (event) => {
  if (event.target.id !== "keyboard-input") {
    return;
  }

  report("input", { value: event.target.value, input_type: event.inputType });
});
window.addEventListener("pointerdown", (event) => report("pointer", {
  x: event.clientX,
  y: event.clientY,
  button: event.button,
}));

// The verifier keeps the animated page alive this long; the measurement mode
// stretches it to cover its frames-per-second window.
const runMs = Number(process.env.TELAR_TERMINAL_BROWSER_RUN_MS) || 8000;
setTimeout(() => {
  report("completed", { keyboard_value: document.querySelector("#keyboard-input")?.value });
  globalThis.terminalBrowser.quit();
}, runMs);
