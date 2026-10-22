// PocketCode notebook: cells + outputs UI, nbformat 4 load/save, and the Pyodide kernel worker.
"use strict";

const app = {
  cells: [],
  selected: 0,
  metadata: {},
  vim: false,
  worker: null,
  interrupt: null,
  kernelReady: false,
  running: null, // cell currently executing
  queue: [], // cells waiting to run
  files: [],
  saveTimer: null,
};

// MARK: - Bridge to the app (Swift)

function native(message) {
  window.webkit?.messageHandlers?.pc?.postMessage(message);
}

function debug(text) {
  native({ type: "debug", text: String(text) });
}
window.addEventListener("error", (event) => debug(`page error: ${event.message} @${event.lineno}`));
window.addEventListener("unhandledrejection", (event) => debug(`page rejection: ${event.reason}`));

window.PC = {
  load(notebook, options) {
    app.vim = !!options.vim;
    app.files = options.files || [];
    document.documentElement.style.setProperty("--size", `${options.fontSize || 14}px`);
    app.metadata = notebook.metadata || {};
    app.cells = (notebook.cells || []).map(fromNbformat);
    if (!app.cells.length) app.cells.push(newCell("code"));
    renderAll();
    select(0, false);
    startKernel();
  },
  setOptions(options) {
    if ("fontSize" in options) {
      document.documentElement.style.setProperty("--size", `${options.fontSize}px`);
      app.cells.forEach((cell) => cell.editor?.refresh());
    }
    if ("vim" in options) {
      app.vim = !!options.vim;
      app.cells.forEach((cell) => cell.editor?.setOption("keyMap", app.vim ? "vim" : "default"));
      updateEscButton();
    }
  },
  save() {
    saveNow();
  },
};

// MARK: - Model

let nextId = 1;

function newCell(type, source = "") {
  return { id: `c${nextId++}`, type, source, outputs: [], count: null, metadata: {}, editing: type === "code" };
}

function joinSource(source) {
  return Array.isArray(source) ? source.join("") : source || "";
}

function fromNbformat(cell) {
  const result = newCell(cell.cell_type === "markdown" ? "markdown" : "code", joinSource(cell.source));
  result.metadata = cell.metadata || {};
  result.count = cell.execution_count ?? null;
  result.outputs = (cell.outputs || []).map((output) => {
    switch (output.output_type) {
      case "stream": return { type: "stream", name: output.name, text: joinSource(output.text) };
      case "error": return { type: "error", ename: output.ename, evalue: output.evalue, traceback: output.traceback || [] };
      default: return { type: output.output_type, data: normalizeData(output.data || {}), execution_count: output.execution_count };
    }
  });
  result.editing = result.type === "code" || !result.source.trim();
  return result;
}

function normalizeData(data) {
  const result = {};
  for (const [mime, value] of Object.entries(data)) result[mime] = joinSource(value);
  return result;
}

function splitLines(text) {
  const lines = text.split("\n");
  return lines.map((line, i) => (i < lines.length - 1 ? line + "\n" : line)).filter((line, i, all) => line !== "" || i < all.length - 1);
}

function toNbformat() {
  return {
    nbformat: 4,
    nbformat_minor: 5,
    metadata: {
      ...app.metadata,
      kernelspec: { name: "python3", display_name: "Python 3 (Pyodide)", language: "python" },
      language_info: { name: "python" },
    },
    cells: app.cells.map((cell) => {
      const base = { id: cell.id, cell_type: cell.type, metadata: cell.metadata, source: splitLines(cell.source) };
      if (cell.type === "markdown") return base;
      return {
        ...base,
        execution_count: cell.count,
        // "log" lines (package loading, restarts) are UI-only and not part of the notebook.
        outputs: cell.outputs.filter((output) => output.type !== "log").map((output) => {
          if (output.type === "stream") return { output_type: "stream", name: output.name, text: splitLines(output.text) };
          if (output.type === "error") return { output_type: "error", ename: output.ename, evalue: output.evalue, traceback: output.traceback };
          const data = {};
          for (const [mime, value] of Object.entries(output.data)) {
            data[mime] = mime.startsWith("image/") && mime !== "image/svg+xml" ? value : splitLines(value);
          }
          return output.type === "execute_result"
            ? { output_type: "execute_result", execution_count: output.execution_count, data, metadata: {} }
            : { output_type: "display_data", data, metadata: {} };
        }),
      };
    }),
  };
}

function scheduleSave() {
  clearTimeout(app.saveTimer);
  app.saveTimer = setTimeout(saveNow, 1200);
  native({ type: "dirty" });
}

function saveNow() {
  clearTimeout(app.saveTimer);
  native({ type: "save", notebook: JSON.stringify(toNbformat(), null, 1) + "\n" });
}

// MARK: - Rendering

const cellsElement = document.getElementById("cells");

function renderAll() {
  cellsElement.textContent = "";
  app.cells.forEach((cell) => cellsElement.appendChild(renderCell(cell)));
}

function renderCell(cell) {
  const element = document.createElement("section");
  element.className = `cell ${cell.type}`;
  element.dataset.id = cell.id;
  cell.element = element;

  const gutter = document.createElement("div");
  gutter.className = "gutter";
  element.appendChild(gutter);
  cell.gutter = gutter;

  const input = document.createElement("div");
  input.className = "input";
  element.appendChild(input);
  cell.input = input;

  const outputs = document.createElement("div");
  outputs.className = "outputs";
  element.appendChild(outputs);
  cell.outputsElement = outputs;

  element.addEventListener("pointerdown", () => select(app.cells.indexOf(cell), false));
  if (cell.type === "markdown") {
    element.addEventListener("dblclick", () => editMarkdown(cell));
  }
  renderInput(cell);
  renderGutter(cell);
  renderOutputs(cell);
  return element;
}

function renderGutter(cell) {
  if (cell.type === "markdown") {
    cell.gutter.textContent = "";
    return;
  }
  const label = cell === app.running ? "*" : app.queue.includes(cell) ? "…" : cell.count ?? " ";
  cell.gutter.textContent = `[${label}]`;
  cell.element.classList.toggle("running", cell === app.running);
}

function renderInput(cell) {
  cell.input.textContent = "";
  cell.editor = null;
  cell.element.classList.toggle("editing", cell.editing);
  if (cell.type === "markdown" && !cell.editing) {
    const view = document.createElement("div");
    view.className = "markdown-view";
    if (cell.source.trim()) {
      view.appendChild(sanitize(marked.parse(cell.source)));
    } else {
      view.innerHTML = '<span class="placeholder">Empty Markdown cell — double-tap to edit</span>';
    }
    cell.input.appendChild(view);
    return;
  }
  const editor = CodeMirror(cell.input, {
    value: cell.source,
    mode: cell.type === "code" ? "python" : "markdown",
    keyMap: app.vim ? "vim" : "default",
    theme: "gruvbox",
    lineNumbers: false,
    lineWrapping: true,
    indentUnit: 4,
    tabSize: 4,
    indentWithTabs: false,
    matchBrackets: true,
    autoCloseBrackets: false,
    viewportMargin: Infinity,
    inputStyle: "contenteditable",
    spellcheck: false,
    autocorrect: false,
    autocapitalize: false,
    extraKeys: {
      "Shift-Enter": () => runAndAdvance(),
      "Cmd-Enter": () => runCell(cell),
      "Ctrl-Enter": () => runCell(cell),
      "Cmd-S": () => saveNow(),
      Tab: (cm) => cm.execCommand(cm.somethingSelected() ? "indentMore" : "insertSoftTab"),
      "Shift-Tab": (cm) => cm.execCommand("indentLess"),
    },
  });
  editor.on("change", () => {
    cell.source = editor.getValue();
    scheduleSave();
  });
  editor.on("focus", () => {
    select(app.cells.indexOf(cell), false);
    updateEscButton();
  });
  editor.on("vim-mode-change", updateEscButton);
  cell.editor = editor;
  setTimeout(() => editor.refresh(), 0);
}

function editMarkdown(cell) {
  if (cell.type !== "markdown" || cell.editing) return;
  cell.editing = true;
  renderInput(cell);
  cell.editor?.focus();
}

function renderOutputs(cell) {
  const container = cell.outputsElement;
  container.textContent = "";
  for (const output of cell.outputs) container.appendChild(renderOutput(output));
}

function appendOutput(cell, output) {
  // Consecutive stream writes merge, like Jupyter.
  const last = cell.outputs[cell.outputs.length - 1];
  if (output.type === "stream" && last?.type === "stream" && last.name === output.name) {
    last.text += output.text;
    const pre = cell.outputsElement.lastElementChild;
    if (pre) pre.textContent = applyCarriageReturns(last.text);
    return;
  }
  cell.outputs.push(output);
  cell.outputsElement.appendChild(renderOutput(output));
}

function applyCarriageReturns(text) {
  // Progress bars rewrite the current line with \r.
  return text.split("\n").map((line) => line.split("\r").pop()).join("\n");
}

function renderOutput(output) {
  if (output.type === "stream") {
    const pre = document.createElement("pre");
    pre.className = output.name === "stderr" ? "output-stderr" : "output-stdout";
    pre.textContent = applyCarriageReturns(output.text);
    return pre;
  }
  if (output.type === "error") {
    const pre = document.createElement("pre");
    pre.className = "output-error";
    pre.textContent = stripAnsi((output.traceback || []).join("\n") || `${output.ename}: ${output.evalue}`);
    return pre;
  }
  if (output.type === "log") {
    const div = document.createElement("div");
    div.className = "output-log";
    div.textContent = output.text;
    return div;
  }
  const data = output.data || {};
  const wrapper = document.createElement("div");
  if (data["image/png"] || data["image/jpeg"]) {
    const img = document.createElement("img");
    const mime = data["image/png"] ? "image/png" : "image/jpeg";
    img.src = `data:${mime};base64,${data[mime].replace(/\s/g, "")}`;
    wrapper.appendChild(img);
  } else if (data["image/svg+xml"]) {
    const img = document.createElement("img");
    img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(data["image/svg+xml"]);
    wrapper.appendChild(img);
  } else if (data["text/html"]) {
    wrapper.appendChild(sandboxedHTML(data["text/html"]));
  } else if (data["text/markdown"]) {
    const view = document.createElement("div");
    view.className = "markdown-view";
    view.appendChild(sanitize(marked.parse(data["text/markdown"])));
    wrapper.appendChild(view);
  } else {
    const pre = document.createElement("pre");
    pre.textContent = data["text/plain"] ?? "";
    wrapper.appendChild(pre);
  }
  return wrapper;
}

function stripAnsi(text) {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

/// HTML outputs (e.g. pandas tables) render in a script-less sandboxed frame: notebooks from other people
/// can't run code in the app or reach the app bridge.
function sandboxedHTML(html) {
  const frame = document.createElement("iframe");
  frame.setAttribute("sandbox", "allow-same-origin");
  frame.srcdoc = `<!doctype html><meta charset="utf-8"><style>
    body{margin:0;color:#ebdbb2;background:transparent;font:13px -apple-system,system-ui;overflow-x:auto}
    table{border-collapse:collapse;font:12px ui-monospace,Menlo,monospace}
    th,td{border:1px solid #504945;padding:3px 8px;text-align:right;white-space:nowrap}
    thead th{background:#3c3836;color:#fabd2f} tbody tr:nth-child(even){background:#32302f}
    tbody th{color:#83a598} a{color:#83a598}</style>${html}`;
  frame.addEventListener("load", () => {
    const resize = () => {
      const body = frame.contentDocument?.body;
      if (body) frame.style.height = `${Math.min(body.scrollHeight + 4, 1200)}px`;
    };
    resize();
    setTimeout(resize, 100);
  });
  return frame;
}

/// Minimal sanitizer for Markdown cells: drops active content (scripts, frames, event handlers, javascript: URLs).
function sanitize(html) {
  const doc = new DOMParser().parseFromString(`<div>${html}</div>`, "text/html");
  const root = doc.body.firstElementChild;
  root.querySelectorAll("script,iframe,object,embed,link,meta,style,form,input,button,textarea,select,base").forEach((n) => n.remove());
  root.querySelectorAll("*").forEach((element) => {
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase();
      const value = attribute.value.trim().toLowerCase();
      if (name.startsWith("on") || ((name === "href" || name === "src" || name === "xlink:href") && /^(javascript|vbscript|data:text)/.test(value))) {
        element.removeAttribute(attribute.name);
      }
    }
    if (element.tagName === "A") element.setAttribute("target", "_blank");
  });
  const fragment = document.createDocumentFragment();
  for (const node of [...root.childNodes]) fragment.appendChild(document.importNode(node, true));
  return fragment;
}

// MARK: - Selection & editing

function select(index, focus = true) {
  index = Math.max(0, Math.min(app.cells.length - 1, index));
  app.cells.forEach((cell, i) => cell.element?.classList.toggle("selected", i === index));
  app.selected = index;
  const cell = app.cells[index];
  if (focus) {
    cell.element.scrollIntoView({ block: "nearest", behavior: "smooth" });
    if (cell.editor) cell.editor.focus();
  }
}

function currentCell() {
  return app.cells[app.selected];
}

function insertCell(type, index) {
  const cell = newCell(type);
  cell.editing = true;
  app.cells.splice(index, 0, cell);
  const element = renderCell(cell);
  cellsElement.insertBefore(element, cellsElement.children[index] || null);
  select(index);
  scheduleSave();
  return cell;
}

function deleteCell() {
  const cell = currentCell();
  if (cell === app.running) return;
  app.cells.splice(app.selected, 1);
  cell.element.remove();
  if (!app.cells.length) insertCell("code", 0);
  select(Math.min(app.selected, app.cells.length - 1), false);
  scheduleSave();
}

function moveCell(delta) {
  const from = app.selected;
  const to = from + delta;
  if (to < 0 || to >= app.cells.length) return;
  const [cell] = app.cells.splice(from, 1);
  app.cells.splice(to, 0, cell);
  renderAll();
  select(to, false);
  scheduleSave();
}

function toggleType() {
  const cell = currentCell();
  cell.type = cell.type === "code" ? "markdown" : "code";
  cell.outputs = [];
  cell.count = null;
  cell.editing = true;
  const element = renderCell(cell);
  cellsElement.replaceChild(element, cellsElement.children[app.selected]);
  select(app.selected);
  scheduleSave();
}

function updateEscButton() {
  const cm = currentCell()?.editor;
  const inInsert = app.vim && cm?.hasFocus() && cm.state.vim?.insertMode;
  document.getElementById("btn-esc").classList.toggle("hidden", !inInsert);
}

// MARK: - Kernel

function setKernelStatus(status, detail) {
  const element = document.getElementById("kernel");
  element.className = status;
  if (detail) document.getElementById("kernel-text").textContent = detail;
  else if (status === "busy") document.getElementById("kernel-text").textContent = "Running…";
}

function startKernel() {
  app.worker?.terminate();
  app.kernelReady = false;
  app.running = null;
  app.queue = [];
  app.cells.forEach(renderGutter);
  try {
    app.interrupt = self.crossOriginIsolated ? new Uint8Array(new SharedArrayBuffer(1)) : null;
  } catch {
    app.interrupt = null;
  }
  app.worker = new Worker("kernel-worker.mjs", { type: "module" });
  app.worker.onmessage = (event) => handleKernelMessage(event.data);
  app.worker.onerror = (event) => {
    debug(`worker error: ${event.message} ${event.filename}:${event.lineno}`);
    setKernelStatus("dead", `Kernel error: ${event.message}`);
  };
  debug(`crossOriginIsolated=${self.crossOriginIsolated}`);
  app.worker.postMessage({ type: "boot", interruptBuffer: app.interrupt, files: app.files });
  setKernelStatus("starting", "Starting Python…");
}

function handleKernelMessage(message) {
  if (message.type !== "emit") debug(`kernel ${message.type}: ${message.status || ""} ${message.detail || message.text || ""}`);
  switch (message.type) {
    case "status":
      if (message.status === "idle") {
        app.kernelReady = true;
        if (message.detail) app.kernelInfo = message.detail;
        if (!app.running) setKernelStatus("idle", app.kernelInfo);
      } else {
        setKernelStatus(message.status, message.detail);
      }
      break;
    case "emit":
      handleEmit(message.message);
      break;
    case "done": {
      const cell = app.running;
      if (cell) {
        cell.count = message.execution_count;
        app.running = null;
        renderGutter(cell);
        scheduleSave();
      }
      runNextQueued();
      break;
    }
    case "log":
      if (app.running && message.text) appendOutput(app.running, { type: "log", text: message.text });
      break;
  }
}

function handleEmit(message) {
  if (message.type === "file") {
    native({ type: "file", path: message.path, data: message.data });
    return;
  }
  if (message.type === "delete") {
    native({ type: "delete", path: message.path });
    return;
  }
  const cell = app.running;
  if (!cell) return;
  if (message.type === "stream") appendOutput(cell, { type: "stream", name: message.name, text: message.text });
  else if (message.type === "error") appendOutput(cell, { type: "error", ename: message.ename, evalue: message.evalue, traceback: message.traceback });
  else appendOutput(cell, { type: message.type, data: message.data, execution_count: message.execution_count });
}

function runCell(cell) {
  if (cell.type === "markdown") {
    cell.editing = false;
    renderInput(cell);
    scheduleSave();
    return;
  }
  if (cell === app.running || app.queue.includes(cell)) return;
  cell.outputs = [];
  renderOutputs(cell);
  app.queue.push(cell);
  renderGutter(cell);
  runNextQueued();
}

function runNextQueued() {
  if (app.running || !app.queue.length) return;
  const cell = app.queue.shift();
  app.running = cell;
  renderGutter(cell);
  setKernelStatus("busy", "Running…");
  app.worker.postMessage({ type: "run", id: cell.id, code: cell.source });
}

function runAndAdvance() {
  const cell = currentCell();
  runCell(cell);
  if (app.selected === app.cells.length - 1) insertCell("code", app.cells.length);
  else select(app.selected + 1);
}

function runAll() {
  app.cells.forEach(runCell);
}

function interruptKernel() {
  if (!app.running) return;
  if (app.interrupt) {
    app.interrupt[0] = 2; // SIGINT
  } else {
    // No SharedArrayBuffer: the only way to stop is a restart.
    restartKernel();
  }
}

function restartKernel(thenRunAll = false) {
  const wasRunning = app.running;
  if (wasRunning) appendOutput(wasRunning, { type: "log", text: "Kernel restarted." });
  startKernel();
  if (thenRunAll) runAll();
}

// MARK: - Toolbar

document.getElementById("btn-run").onclick = () => runAndAdvance();
document.getElementById("btn-run-all").onclick = () => runAll();
document.getElementById("btn-stop").onclick = () => interruptKernel();
document.getElementById("btn-add").onclick = () => insertCell("code", app.selected + 1);
document.getElementById("btn-esc").onclick = () => {
  const cm = currentCell()?.editor;
  if (cm) CodeMirror.Vim.exitInsertMode(cm);
  updateEscButton();
};
const menu = document.getElementById("menu");
document.getElementById("btn-menu").onclick = (event) => {
  event.stopPropagation();
  menu.classList.toggle("hidden");
};
document.addEventListener("pointerdown", (event) => {
  if (!menu.contains(event.target) && event.target.id !== "btn-menu") menu.classList.add("hidden");
});
menu.addEventListener("click", (event) => {
  const action = event.target.dataset.action;
  menu.classList.add("hidden");
  switch (action) {
    case "add-markdown": insertCell("markdown", app.selected + 1); break;
    case "toggle-type": toggleType(); break;
    case "move-up": moveCell(-1); break;
    case "move-down": moveCell(1); break;
    case "delete": deleteCell(); break;
    case "clear":
      app.cells.forEach((cell) => { cell.outputs = []; cell.count = null; renderOutputs(cell); renderGutter(cell); });
      scheduleSave();
      break;
    case "restart": restartKernel(); break;
    case "restart-run": restartKernel(true); break;
  }
});

native({ type: "ready" });
