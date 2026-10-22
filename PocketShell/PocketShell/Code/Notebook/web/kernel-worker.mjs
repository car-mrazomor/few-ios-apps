// Pyodide kernel in a module Web Worker, so long-running cells don't freeze the notebook UI.
import { loadPyodide } from "../pyodide/pyodide.mjs";

let pyodide = null;
let kernel = null;
const WORKDIR = "/home/pyodide/work";

function post(message) {
  self.postMessage(message);
}

// Python -> page: outputs, file writes.
self.pcEmit = (json) => post({ type: "emit", message: JSON.parse(json) });

function streamWriter(name) {
  const decoder = new TextDecoder();
  return {
    write(bytes) {
      const text = decoder.decode(bytes, { stream: true });
      if (text) post({ type: "emit", message: { type: "stream", name, text } });
      return bytes.length;
    },
  };
}

async function boot({ interruptBuffer, files }) {
  post({ type: "status", status: "starting", detail: "Starting Python…" });
  pyodide = await loadPyodide({ indexURL: new URL("../pyodide/", self.location.href).href });
  if (interruptBuffer) pyodide.setInterruptBuffer(interruptBuffer);
  pyodide.setStdout(streamWriter("stdout"));
  pyodide.setStderr(streamWriter("stderr"));
  pyodide.setStdin({
    stdin() {
      throw new Error("input() isn't available in notebooks; use a variable, or run the script in the Terminal tab.");
    },
  });

  // Copy the notebook's folder into Pyodide's file system so open("data.csv") works.
  const FS = pyodide.FS;
  FS.mkdirTree(WORKDIR);
  if (files.length) post({ type: "status", status: "starting", detail: `Loading ${files.length} files…` });
  for (const file of files) {
    try {
      const response = await fetch("../workspace/" + file.path.split("/").map(encodeURIComponent).join("/"));
      const data = new Uint8Array(await response.arrayBuffer());
      const dir = WORKDIR + "/" + file.path.split("/").slice(0, -1).join("/");
      FS.mkdirTree(dir);
      FS.writeFile(WORKDIR + "/" + file.path, data);
    } catch (error) {
      post({ type: "log", text: `couldn't load ${file.path}: ${error}` });
    }
  }
  FS.chdir(WORKDIR);

  const source = await (await fetch("kernel.py")).text();
  kernel = await pyodide.runPythonAsync(source);
  const python = pyodide.runPython("import sys; sys.version.split()[0]");
  post({ type: "status", status: "idle", detail: `Python ${python} · Pyodide ${pyodide.version}` });
}

async function run({ id, code }) {
  post({ type: "status", status: "busy", id });
  try {
    await pyodide.loadPackagesFromImports(code, {
      messageCallback: (text) => {
        if (/^Load(ing|ed)/.test(text)) post({ type: "status", status: "busy", id, detail: text });
      },
      errorCallback: (text) => post({ type: "log", text }),
    });
  } catch (error) {
    post({ type: "log", text: String(error) });
  }
  let result = { execution_count: null, status: "error" };
  try {
    result = JSON.parse(await kernel.run(code));
  } catch (error) {
    post({ type: "log", text: `kernel.run failed: ${error}` });
    post({ type: "emit", message: { type: "error", ename: "KernelError", evalue: String(error), traceback: [String(error)] } });
  }
  post({ type: "done", id, ...result });
  post({ type: "status", status: "idle" });
}

const queue = [];
let running = false;

async function drain() {
  if (running) return;
  running = true;
  while (queue.length) {
    const message = queue.shift();
    if (message.type === "boot") await boot(message).catch((error) => post({ type: "status", status: "dead", detail: String(error) }));
    if (message.type === "run") await run(message);
  }
  running = false;
}

self.onmessage = (event) => {
  queue.push(event.data);
  drain();
};
