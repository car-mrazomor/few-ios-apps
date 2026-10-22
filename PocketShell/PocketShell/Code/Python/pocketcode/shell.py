"""PocketCode's mini shell: file commands plus python, pip and git, all running in-process."""

import code
import fnmatch
import importlib
import os
import re
import runpy
import shutil
import sys
import traceback

import _pocketcode

from . import runtime, sh
from .colors import AQUA, BLUE, BOLD, GRAY, GREEN, PURPLE, RED, RESET, YELLOW, paint

COMMANDS = {}
last_status = 0


def command(*names):
    def register(func):
        for name in names:
            COMMANDS[name] = func
        return func

    return register


class UsageError(Exception):
    pass


# MARK: - Entry points called from Swift


def run_line(line):
    """Runs one command line (any shell syntax) and returns its exit status."""
    global last_status
    if not line.strip():
        return last_status
    try:
        last_status = SHELL.run(line)
    except sh.ParseError as error:
        print(paint(RED, f"pcsh: {error}"), file=sys.stderr)
        last_status = 2
    except KeyboardInterrupt:
        print(paint(GRAY, "^C"))
        last_status = 130
    SHELL.status = last_status
    _pocketcode.event("files", os.getcwd())
    return last_status


def run_command(name, args):
    """Runs a registered command (or a .py / .sh file). Returns its status, or None if there's no such command."""
    handler = COMMANDS.get(name)
    if handler is None and os.path.isfile(expand(name)) and ("/" in name or name.endswith((".py", ".sh"))):
        if name.endswith(".py"):
            handler, args = COMMANDS["python"], [name, *args]
        else:
            handler, args = COMMANDS["sh"], [name, *args]
    if handler is None:
        return None
    try:
        result = handler(args)
        return 0 if result is None else int(result)
    except UsageError as error:
        print(paint(RED, f"{name}: {error}"), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        raise
    except sh.ShellExit:
        raise
    except (OSError, ValueError) as error:
        print(paint(RED, f"{name}: {error}"), file=sys.stderr)
        return 1
    except Exception:
        traceback.print_exc()
        return 1


def prompt(_=""):
    cwd = display_path(os.getcwd())
    branch = current_branch()
    arrow = paint(RED if last_status else GREEN, "❯")
    branch_text = f" {paint(GRAY, 'on')} {paint(PURPLE, branch)}" if branch else ""
    return f"{BOLD}{paint(AQUA, cwd)}{RESET}{branch_text}\n{arrow} "


def complete(line):
    """Tab completion for the last word: command names first, then paths. Returns the completed line."""
    words = line.split(" ")
    word = words[-1]
    if len(words) == 1:
        options = sorted(name for name in COMMANDS if name.startswith(word))
    else:
        directory, partial = os.path.split(word)
        base = expand(directory) if directory else "."
        try:
            entries = os.listdir(base)
        except OSError:
            return line
        options = sorted(
            os.path.join(directory, e) + ("/" if os.path.isdir(os.path.join(base, e)) else "")
            for e in entries
            if e.startswith(partial) and (partial.startswith(".") or not e.startswith("."))
        )
    if not options:
        return line
    common = os.path.commonprefix(options)
    if len(options) == 1 and not common.endswith("/"):
        common += " "
    if common == word and len(options) > 1:
        print()
        print("  ".join(options))
    words[-1] = common
    return " ".join(words)


def set_size(spec):
    """Called by the app when the terminal resizes: 'cols rows'."""
    cols, rows = spec.split()
    os.environ["COLUMNS"], os.environ["LINES"] = cols, rows
    return ""


def set_git_credentials(spec):
    """Called by the app with 'username\ntoken' from the Keychain."""
    from .git_cmd import set_credentials

    username, _, token = spec.partition("\n")
    set_credentials(username, token)
    return ""


# MARK: - Helpers


def display_path(path):
    workspace = runtime.WORKSPACE
    if path == workspace:
        return "~"
    if path.startswith(workspace + os.sep):
        return "~/" + path[len(workspace) + 1 :]
    return path


def expand(path):
    if path == "~" or path.startswith("~/"):
        return runtime.WORKSPACE + path[1:]
    return path


def find_repo(path="."):
    path = os.path.abspath(path)
    while True:
        if os.path.isdir(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


def current_branch():
    repo = find_repo()
    if not repo:
        return None
    try:
        head = open(os.path.join(repo, ".git", "HEAD")).read().strip()
    except OSError:
        return None
    return head.removeprefix("ref: refs/heads/") if head.startswith("ref:") else head[:7]


def parse_flags(args, known):
    """Splits '-rf' style flags from positional arguments."""
    flags, rest = set(), []
    for arg in args:
        if arg.startswith("-") and len(arg) > 1 and arg != "--":
            for ch in arg.lstrip("-") if not arg.startswith("--") else [arg]:
                if ch not in known:
                    raise UsageError(f"unknown option {arg}")
                flags.add(ch)
        else:
            rest.append(arg)
    return flags, rest


# MARK: - Built-in commands


@command("help")
def cmd_help(args):
    print(f"""{BOLD}PocketCode shell{RESET} — everything runs inside the app.

  {YELLOW}python{RESET} [file.py | -c code | -m module] [args]   run Python (no args: REPL)
  {YELLOW}pip{RESET} install|uninstall|list|show|freeze ...      pure-Python packages
  {YELLOW}git{RESET} clone|status|add|commit|push|pull|log|diff|branch|checkout ...
  {YELLOW}vim{RESET} file                                         open in the editor
  sh script.sh · ./script.sh · bash -c "..."            run shell scripts
  ls [-a] · cd · pwd · cat · head · tail · mkdir [-p] · touch · rm [-r] · mv · cp [-r]
  tree · grep · find · wc · sort · uniq · echo · printf · env · export · which · date · sleep · clear

  Shell syntax: a && b · a || b · a; b · a | b · > >> < 2>&1 · $VAR · $(cmd) · *.py
                if/elif/else/fi · for x in ...; do ...; done · while ...; do ...; done · f() {{ ...; }}
  Python's subprocess / os.system run these same commands.

{GRAY}Ctrl-C interrupts · ↑/↓ history · Tab completes · ~ is your workspace (Files app → On My iPhone → PocketShell){RESET}""")


@command("clear", "cls")
def cmd_clear(args):
    sys.stdout.write("\x1b[2J\x1b[3J\x1b[H")


@command("pwd")
def cmd_pwd(args):
    print(display_path(os.getcwd()))


@command("echo")
def cmd_echo(args):
    newline, escapes = True, False
    while args and args[0] in ("-n", "-e", "-ne", "-en", "-E"):
        flag, args = args[0], args[1:]
        newline = newline and "n" not in flag
        escapes = "e" in flag or escapes
    text = " ".join(args)
    if escapes:
        text = text.encode().decode("unicode_escape")
    sys.stdout.write(text + ("\n" if newline else ""))


@command("ls", "ll")
def cmd_ls(args):
    flags, paths = parse_flags(args, "al1")
    for index, path in enumerate(paths or ["."]):
        path = expand(path)
        if not os.path.isdir(path):
            print(path if os.path.exists(path) else paint(RED, f"ls: {path}: no such file or directory"))
            continue
        if len(paths) > 1:
            print(("\n" if index else "") + f"{path}:")
        entries = sorted(os.listdir(path), key=str.lower)
        if "a" not in flags:
            entries = [e for e in entries if not e.startswith(".")]
            if os.path.abspath(path) == runtime.WORKSPACE:
                entries = [e for e in entries if e != "Inbox"]  # iOS's folder for files opened from other apps
        styled = []
        for entry in entries:
            full = os.path.join(path, entry)
            if os.path.isdir(full):
                styled.append(paint(BLUE, BOLD + entry + "/"))
            elif entry.endswith(".py"):
                styled.append(paint(GREEN, entry))
            elif entry.endswith(".ipynb"):
                styled.append(paint(YELLOW, entry))
            else:
                styled.append(entry)
        if not sys.stdout.isatty():
            for entry in entries:
                print(entry)
        elif "l" in flags or "1" in flags:
            for entry, text in zip(entries, styled):
                full = os.path.join(path, entry)
                size = "" if os.path.isdir(full) else human_size(os.path.getsize(full))
                print(f"{size:>7}  {text}")
        elif styled:
            print("  ".join(styled))


def human_size(size):
    for unit in ("B", "K", "M", "G"):
        if size < 1024 or unit == "G":
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024


@command("cat")
def cmd_cat(args):
    if not args or args == ["-"]:
        sys.stdout.write(sys.stdin.read())
        return
    for path in args:
        with open(expand(path), encoding="utf-8", errors="replace") as f:
            sys.stdout.write(f.read())


@command("head")
def cmd_head(args):
    count = 10
    if args and args[0].startswith("-") and args[0][1:].isdigit():
        count, args = int(args[0][1:]), args[1:]
    for stream in open_inputs(args):
        for _, line in zip(range(count), stream):
            sys.stdout.write(line)


@command("mkdir")
def cmd_mkdir(args):
    flags, paths = parse_flags(args, "p")
    if not paths:
        raise UsageError("usage: mkdir [-p] dir...")
    for path in paths:
        if "p" in flags:
            os.makedirs(expand(path), exist_ok=True)
        else:
            os.mkdir(expand(path))


@command("touch")
def cmd_touch(args):
    for path in args:
        with open(expand(path), "a"):
            os.utime(expand(path))


@command("rm")
def cmd_rm(args):
    flags, paths = parse_flags(args, "rf")
    if not paths:
        raise UsageError("usage: rm [-rf] path...")
    for path in map(expand, paths):
        if os.path.abspath(path) == runtime.WORKSPACE:
            raise UsageError("refusing to remove the workspace")
        if os.path.isdir(path) and not os.path.islink(path):
            if "r" not in flags:
                raise UsageError(f"{path} is a directory (use -r)")
            shutil.rmtree(path)
        elif os.path.exists(path) or "f" not in flags:
            os.remove(path)


@command("mv")
def cmd_mv(args):
    if len(args) != 2:
        raise UsageError("usage: mv source destination")
    shutil.move(expand(args[0]), expand(args[1]))


@command("cp")
def cmd_cp(args):
    flags, paths = parse_flags(args, "r")
    if len(paths) != 2:
        raise UsageError("usage: cp [-r] source destination")
    source, destination = map(expand, paths)
    if os.path.isdir(source):
        if "r" not in flags:
            raise UsageError(f"{source} is a directory (use -r)")
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)


@command("tree")
def cmd_tree(args):
    root = expand(args[0]) if args else "."
    print(paint(BLUE, BOLD + root + RESET))

    def walk(path, prefix):
        entries = sorted(e for e in os.listdir(path) if not e.startswith(".") and e != "__pycache__")
        for index, entry in enumerate(entries):
            last = index == len(entries) - 1
            full = os.path.join(path, entry)
            name = paint(BLUE, BOLD + entry + RESET) if os.path.isdir(full) else entry
            print(f"{prefix}{'└── ' if last else '├── '}{name}")
            if os.path.isdir(full):
                walk(full, prefix + ("    " if last else "│   "))

    walk(root, "")


@command("find")
def cmd_find(args):
    root, pattern = ".", "*"
    if args and not args[0].startswith("-"):
        root, args = expand(args[0]), args[1:]
    if len(args) == 2 and args[0] == "-name":
        pattern = args[1]
    for path, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for name in dirs + files:
            if fnmatch.fnmatch(name, pattern):
                print(os.path.join(path, name))


@command("grep")
def cmd_grep(args):
    flags, rest = parse_flags(args, "nricvlh")
    if not rest:
        raise UsageError("usage: grep [-nricvl] pattern [paths]")
    regex = re.compile(rest[0], re.IGNORECASE if "i" in flags else 0)
    invert, color = "v" in flags, sys.stdout.isatty()

    def matches(line):
        return bool(regex.search(line)) != invert

    def show(line):
        return regex.sub(lambda m: paint(RED, BOLD + m.group(0) + RESET), line) if color and not invert else line

    if not rest[1:] and "r" not in flags:
        sources = [("(standard input)", sys.stdin.read().splitlines())]
    else:
        files = []
        for path in list(map(expand, rest[1:])) or ["."]:
            if os.path.isdir(path):
                if "r" not in flags:
                    raise UsageError(f"{path} is a directory (use -r)")
                for root, dirs, names in os.walk(path):
                    dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", "node_modules")]
                    files += [os.path.join(root, n) for n in sorted(names)]
            else:
                files.append(path)
        sources = []
        for path in files:
            try:
                with open(path, encoding="utf-8") as f:
                    sources.append((path, f.read().splitlines()))
            except (UnicodeDecodeError, OSError):
                continue

    show_names = (len(sources) > 1 or "r" in flags) and "h" not in flags
    found = False
    for name, lines in sources:
        hits = [(number, line) for number, line in enumerate(lines, 1) if matches(line)]
        found = found or bool(hits)
        if "l" in flags:
            if hits:
                print(name)
        elif "c" in flags:
            print(f"{paint(PURPLE, name)}:{len(hits)}" if show_names else len(hits))
        else:
            for number, line in hits:
                prefix = (paint(PURPLE, name) + ":" if show_names else "") + (paint(GREEN, str(number)) + ":" if "n" in flags else "")
                print(prefix + show(line))
    return 0 if found else 1


def open_inputs(paths):
    """File arguments as open text streams, or stdin when there are none."""
    if not paths or paths == ["-"]:
        return [sys.stdin]
    return [open(expand(p), encoding="utf-8", errors="replace") for p in paths]


@command("tail")
def cmd_tail(args):
    count = 10
    if args and args[0].startswith("-") and args[0][1:].isdigit():
        count, args = int(args[0][1:]), args[1:]
    elif args[:1] == ["-n"]:
        count, args = int(args[1]), args[2:]
    for stream in open_inputs(args):
        sys.stdout.write("".join(stream.readlines()[-count:]))


@command("wc")
def cmd_wc(args):
    flags, paths = parse_flags(args, "lwc")
    for stream in open_inputs(paths):
        text = stream.read()
        counts = {"l": text.count("\n"), "w": len(text.split()), "c": len(text.encode())}
        shown = [counts[f] for f in "lwc" if not flags or f in flags]
        print(" ".join(f"{c:>7}" for c in shown) + (f" {stream.name}" if paths else ""))


@command("sort")
def cmd_sort(args):
    flags, paths = parse_flags(args, "rnu")
    lines = [line.rstrip("\n") for stream in open_inputs(paths) for line in stream]
    key = (lambda l: float(re.match(r"\s*-?[\d.]*", l).group(0) or 0)) if "n" in flags else None
    lines.sort(key=key, reverse="r" in flags)
    if "u" in flags:
        lines = list(dict.fromkeys(lines))
    for line in lines:
        print(line)


@command("uniq")
def cmd_uniq(args):
    previous = object()
    for line in (line for stream in open_inputs(args) for line in stream):
        if line != previous:
            sys.stdout.write(line)
        previous = line


@command("which", "type", "command")
def cmd_which(args):
    names = [a for a in args if not a.startswith("-")]
    status = 0
    for name in names:
        if name in COMMANDS or hasattr(SHELL, "builtin_" + name) or name in SHELL.functions:
            print(f"/usr/bin/{name}")
        else:
            print(f"{name} not found", file=sys.stderr)
            status = 1
    return status


@command("env", "printenv")
def cmd_env(args):
    if args:
        print(os.environ.get(args[0], ""))
        return 0 if args[0] in os.environ else 1
    for key, value in sorted(os.environ.items()):
        print(f"{key}={value}")


@command("date")
def cmd_date(args):
    import time

    fmt = args[0][1:] if args and args[0].startswith("+") else "%a %b %d %H:%M:%S %Z %Y"
    print(time.strftime(fmt))


@command("sleep")
def cmd_sleep(args):
    import time

    time.sleep(float(args[0]) if args else 0)


@command("basename")
def cmd_basename(args):
    name = os.path.basename(args[0].rstrip("/")) if args else ""
    if len(args) > 1 and name.endswith(args[1]):
        name = name[: -len(args[1])]
    print(name)


@command("dirname")
def cmd_dirname(args):
    print(os.path.dirname(args[0].rstrip("/")) or "." if args else ".")


@command("sh", "bash", "zsh")
def cmd_sh(args):
    """Runs a shell script (or -c 'commands') in a child shell: its cd/variables don't leak out."""
    if not args:
        raise UsageError("interactive sub-shells aren't supported; run 'sh script.sh' or 'sh -c \"...\"'")
    if args[0] == "-c":
        source, name, positional = (args[1] if len(args) > 1 else ""), "sh", args[2:]
    else:
        path = expand(args[0])
        with open(path, encoding="utf-8") as f:
            source = f.read()
        name, positional = args[0], args[1:]
    child = sh.Shell(run_command)
    child.variables = dict(SHELL.variables)
    child.functions = dict(SHELL.functions)
    child.script_name, child.positional = name, positional
    saved_cwd = os.getcwd()
    try:
        return child.run(source)
    finally:
        if os.path.isdir(saved_cwd):
            os.chdir(saved_cwd)


@command("vim", "vi", "nvim", "edit", "open")
def cmd_vim(args):
    if not args:
        raise UsageError("usage: vim file")
    path = os.path.abspath(expand(args[0]))
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "a").close()
    _pocketcode.event("open", path)


@command("exit", "logout")
def cmd_exit(args):
    print(paint(GRAY, "There's nowhere to exit to — this shell is the app. Use 'clear' to tidy up."))


# MARK: - python


@command("python", "python3")
def cmd_python(args):
    if not args:
        return python_repl()
    saved_argv, saved_path, saved_cwd = sys.argv[:], sys.path[:], os.getcwd()
    before = set(sys.modules)
    try:
        if args[0] == "-c":
            if len(args) < 2:
                raise UsageError("argument expected for -c")
            sys.argv = ["-c", *args[2:]]
            sys.path.insert(0, "")
            exec(compile(args[1], "<string>", "exec"), {"__name__": "__main__", "__builtins__": __builtins__})
        elif args[0] == "-m":
            if len(args) < 2:
                raise UsageError("argument expected for -m")
            sys.argv = [args[1], *args[2:]]
            sys.path.insert(0, os.getcwd())
            runpy.run_module(args[1], run_name="__main__", alter_sys=True)
        elif args[0] in ("-V", "--version"):
            print(f"Python {sys.version.split()[0]}")
        else:
            script = os.path.abspath(expand(args[0]))
            sys.argv = [script, *args[1:]]
            sys.path.insert(0, os.path.dirname(script))
            runpy.run_path(script, run_name="__main__")
    except SystemExit as exit:
        return exit_code(exit)
    except KeyboardInterrupt:
        raise
    except Exception:
        print_traceback()
        return 1
    finally:
        sys.argv, sys.path[:] = saved_argv, saved_path
        if os.path.isdir(saved_cwd):
            os.chdir(saved_cwd)
        forget_modules(before)
    return 0


@command("run")
def cmd_run(args):
    """The editor's Run button: cd to the file's folder, then run it."""
    if not args:
        raise UsageError("usage: run file.py [args]")
    path = os.path.abspath(expand(args[0]))
    os.chdir(os.path.dirname(path))
    if path.endswith(".py"):
        return cmd_python([path, *args[1:]])
    raise UsageError(f"don't know how to run {os.path.basename(path)} (only .py files)")


def exit_code(exit):
    if exit.code is None:
        return 0
    if isinstance(exit.code, int):
        return exit.code
    print(exit.code, file=sys.stderr)
    return 1


def print_traceback():
    """Prints the traceback without PocketCode's own frames (runpy, shell)."""
    kind, value, tb = sys.exc_info()
    frames = traceback.extract_tb(tb)
    internal = (os.sep + "pocketcode" + os.sep, "runpy")
    keep = [i for i, frame in enumerate(frames) if not any(part in frame.filename for part in internal)]
    start = keep[0] if keep else len(frames)
    while tb is not None and start > 0:
        tb, start = tb.tb_next, start - 1
    traceback.print_exception(kind, value, tb)


def forget_modules(before):
    """Drops modules imported from the workspace so the next run picks up edits."""
    workspace = runtime.WORKSPACE + os.sep
    for name in set(sys.modules) - before:
        module = sys.modules.get(name)
        if (getattr(module, "__file__", None) or "").startswith(workspace):
            del sys.modules[name]
    importlib.invalidate_caches()


class _Exit:
    def __repr__(self):
        return "Use exit() or Ctrl-D to leave the REPL"

    def __call__(self, code=None):
        raise SystemExit(code)


def python_repl():
    namespace = {"__name__": "__main__", "__builtins__": __builtins__, "exit": _Exit(), "quit": _Exit()}
    console = code.InteractiveConsole(namespace)
    sys.ps1, sys.ps2 = paint(YELLOW, ">>> "), paint(GRAY, "... ")
    print(paint(GRAY, f"Python {sys.version.split()[0]} on iOS · Ctrl-D or exit() to leave"))
    try:
        console.interact(banner="", exitmsg="")
    except SystemExit:
        pass
    return 0


SHELL = sh.Shell(run_command)


# MARK: - pip and git (in their own modules)


@command("pip", "pip3")
def cmd_pip(args):
    from .pip_cmd import run

    return run(args)


@command("git")
def cmd_git(args):
    from .git_cmd import run

    return run(args)
