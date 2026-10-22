"""Notebook kernel running inside Pyodide (in a Web Worker). Talks to the page through js.pcEmit(json)."""

import base64
import io
import json
import os
import re
import sys
import traceback
import warnings

import js
from pyodide.code import eval_code_async

MAX_SYNC_BYTES = 20 * 1024 * 1024
# Pyodide's own matplotlib build triggers this deprecation internally on every chart; it isn't actionable by users.
warnings.filterwarnings("ignore", message=r"The [xy] parameter as float was deprecated")

# Figures render through a tiny inline backend (defined below) whose show() puts the image in the cell output.
os.environ["MPLBACKEND"] = "module://pocketcode_mpl"


def emit(message):
    js.pcEmit(json.dumps(message, default=str))


# MARK: - Rich display


def _figure_png(figure):
    buffer = io.BytesIO()
    figure.savefig(buffer, format="png", bbox_inches="tight", dpi=110)
    return base64.b64encode(buffer.getvalue()).decode()


def mimebundle(obj):
    data = {"text/plain": repr(obj)}
    if isinstance(obj, type):
        return data
    if type(obj).__name__ == "Figure" and hasattr(obj, "savefig"):
        data["image/png"] = _figure_png(obj)
        return data
    for method, mime in (
        ("_repr_html_", "text/html"),
        ("_repr_markdown_", "text/markdown"),
        ("_repr_svg_", "image/svg+xml"),
        ("_repr_png_", "image/png"),
        ("_repr_jpeg_", "image/jpeg"),
        ("_repr_latex_", "text/latex"),
    ):
        func = getattr(obj, method, None)
        if not callable(func):
            continue
        try:
            value = func()
        except Exception:
            continue
        if isinstance(value, tuple):
            value = value[0]
        if value is None:
            continue
        if isinstance(value, bytes):
            value = base64.b64encode(value).decode()
        data[mime] = value
    return data


def display(*objects, **kwargs):
    for obj in objects:
        emit({"type": "display_data", "data": mimebundle(obj), "metadata": {}})


class HTML:
    def __init__(self, html):
        self.data = html

    def _repr_html_(self):
        return self.data


class Markdown:
    def __init__(self, text):
        self.data = text

    def _repr_markdown_(self):
        return self.data


def flush_figures():
    pyplot = sys.modules.get("matplotlib.pyplot")
    if pyplot is None:
        return
    for number in pyplot.get_fignums():
        figure = pyplot.figure(number)
        emit({"type": "display_data", "data": {"image/png": _figure_png(figure), "text/plain": repr(figure)}, "metadata": {}})
    pyplot.close("all")


# `from IPython.display import display, HTML, Markdown` works, but the shim only exists once a notebook imports it:
# libraries like matplotlib change behaviour when they see IPython already loaded.
class _IPythonShimFinder:
    def find_spec(self, name, path=None, target=None):
        if name not in ("IPython", "IPython.display", "pocketcode_mpl"):
            return None
        import importlib.machinery

        return importlib.machinery.ModuleSpec(name, self, is_package=name == "IPython")

    def create_module(self, spec):
        module = type(sys)(spec.name)
        if spec.name == "pocketcode_mpl":
            # matplotlib backend: Agg rendering, and plt.show() emits the figures into the running cell.
            from matplotlib.backends.backend_agg import FigureCanvasAgg

            module.FigureCanvas = FigureCanvasAgg
            module.show = lambda *args, **kwargs: flush_figures()
        elif spec.name == "IPython":
            module.__path__ = []
            module.version_info = (8, 0, 0, "")
            module.get_ipython = lambda: None  # "not running inside IPython"
        else:
            module.display = display
            module.HTML = HTML
            module.Markdown = Markdown
        return module

    def exec_module(self, module):
        pass


sys.meta_path.append(_IPythonShimFinder())


# MARK: - Magics


async def _pip(arguments):
    import shlex

    try:
        import micropip
    except ImportError:
        import pyodide_js

        await pyodide_js.loadPackage("micropip")
        import micropip

    args = shlex.split(arguments)
    if not args:
        print("usage: %pip install <package> ...")
        return
    command, rest = args[0], [a for a in args[1:] if not a.startswith("-")]
    if command == "install":
        print(f"Installing {', '.join(rest)}…")
        await micropip.install(rest, keep_going=True)
        print("Successfully installed " + ", ".join(rest))
    elif command == "uninstall":
        micropip.uninstall(rest)
    elif command in ("list", "freeze"):
        for name, package in sorted(micropip.list().items()):
            print(f"{name}=={package.version}")
    else:
        print(f"%pip {command} isn't supported (install, uninstall, list)")


def transform_magics(code):
    lines = []
    for line in code.split("\n"):
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        match = re.match(r"^[%!]\s*pip3?\s+(.*)$", stripped)
        if match:
            lines.append(f"{indent}await __pc_pip({match.group(1)!r})")
        elif stripped.startswith(("%matplotlib", "%load_ext", "%config")):
            lines.append(f"{indent}pass")
        elif stripped.startswith("!"):
            lines.append(f"{indent}print({'Shell commands (!) need a real system; use the Terminal tab instead.'!r})")
        elif stripped.startswith("%") and not stripped.startswith("%%"):
            name = stripped.split()[0]
            lines.append(f"{indent}print({f'{name} magic is not supported in PocketCode notebooks.'!r})")
        else:
            lines.append(line)
    return "\n".join(lines)


# MARK: - Files (synced back to the real folder by the app)


def snapshot():
    state = {}
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "__pycache__"]
        for name in files:
            path = os.path.normpath(os.path.join(root, name))
            try:
                info = os.stat(path)
            except OSError:
                continue
            state[path] = (info.st_mtime_ns, info.st_size)
    return state


def sync_files(before):
    after = snapshot()
    for path, stamp in after.items():
        if before.get(path) != stamp and stamp[1] <= MAX_SYNC_BYTES:
            with open(path, "rb") as f:
                emit({"type": "file", "path": path, "data": base64.b64encode(f.read()).decode()})
    for path in before.keys() - after.keys():
        emit({"type": "delete", "path": path})


# MARK: - Kernel


class Kernel:
    def __init__(self):
        self.count = 0
        self.namespace = {"__name__": "__main__", "display": display, "__pc_pip": _pip}
        self.files = snapshot()

    def mark_files_synced(self):
        self.files = snapshot()

    async def run(self, code):
        self.count += 1
        status = "ok"
        try:
            result = await eval_code_async(
                transform_magics(code), self.namespace, filename=f"<cell {self.count}>", quiet_trailing_semicolon=True
            )
            flush_figures()
            if result is not None:
                self.namespace["_"] = result
                emit({"type": "execute_result", "execution_count": self.count, "data": mimebundle(result), "metadata": {}})
        except BaseException as error:  # noqa: BLE001 — report everything, including KeyboardInterrupt
            flush_figures()
            status = "error"
            emit({
                "type": "error",
                "ename": type(error).__name__,
                "evalue": str(error) + self._hint(error),
                "traceback": self._traceback(error),
            })
        finally:
            sync_files(self.files)
            self.files = snapshot()
        return json.dumps({"execution_count": self.count, "status": status})

    @staticmethod
    def _hint(error):
        if isinstance(error, ModuleNotFoundError) and error.name:
            return f"\n(Not in Pyodide's package set? Try: %pip install {error.name.split('.')[0]})"
        return ""

    @staticmethod
    def _traceback(error):
        frames = traceback.extract_tb(error.__traceback__)
        user = [f for f in frames if f.filename.startswith("<cell ") or "/home/pyodide" in f.filename]
        lines = ["Traceback (most recent call last):\n"] + traceback.format_list(user) if user else []
        lines += traceback.format_exception_only(type(error), error)
        return [line.rstrip("\n") for line in lines]


kernel = Kernel()
kernel
