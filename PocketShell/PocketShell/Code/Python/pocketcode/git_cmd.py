"""`git`, implemented with dulwich (pure Python). HTTPS remotes, authenticated with a token from Settings."""

import io
import os
import sys
import time

from dulwich import hooks, porcelain
from dulwich import repo as dulwich_repo
from dulwich.config import ConfigFile
from dulwich.errors import GitProtocolError, HangupException, NotGitRepository
from dulwich.repo import Repo

from . import runtime
from .colors import AQUA, BOLD, GRAY, GREEN, PURPLE, RED, RESET, YELLOW, paint

# iOS can't run hook scripts (no processes).
hooks.ShellHook.execute = lambda self, *args: None
# iOS has no login user, so dulwich's last-resort identity lookup fails. It's only reached for bookkeeping
# (ref logs during clone/pull); commits require a configured identity, checked in git_commit.
dulwich_repo._get_default_identity = lambda: ("PocketCode", "pocketcode@localhost")

#: Set from the app's Settings (Keychain) via set_credentials().
USERNAME = None
TOKEN = None


def set_credentials(username, token):
    global USERNAME, TOKEN
    USERNAME, TOKEN = username or None, token or None


class GitError(Exception):
    pass


class _Progress(io.RawIOBase):
    """Forwards dulwich's progress bytes (with \\r updates) to the terminal."""

    def writable(self):
        return True

    def write(self, data):
        sys.stdout.write(bytes(data).decode("utf-8", "replace"))
        return len(data)


class _MixedOutput:
    """dulwich's show() writes both str and bytes to one stream."""

    def write(self, data):
        sys.stdout.write(data.decode("utf-8", "replace") if isinstance(data, (bytes, bytearray)) else data)

    def flush(self):
        pass


def auth():
    if TOKEN:
        return {"username": USERNAME or "git", "password": TOKEN}
    return {}


def repo_root():
    from .shell import find_repo

    root = find_repo()
    if not root:
        raise GitError("not a git repository (run 'git init' or 'git clone <url>')")
    return root


def rel(root, path):
    return os.path.relpath(os.path.abspath(path), root)


def resolve(root, spec):
    """Resolves revisions like HEAD~2, main^ or a short sha to a full commit id (dulwich lacks ~ and ^)."""
    import re

    from dulwich.objectspec import parse_commit

    match = re.fullmatch(r"(.*?)((?:[~^]\d*)*)", spec)
    base, suffix = match.group(1) or "HEAD", match.group(2)
    repo = Repo(root)
    commit = parse_commit(repo, base.encode())
    for op, digits in re.findall(r"([~^])(\d*)", suffix):
        steps = int(digits or 1) if op == "~" else 1
        parent_index = int(digits or 1) - 1 if op == "^" else 0
        for _ in range(steps):
            if len(commit.parents) <= parent_index:
                raise GitError(f"revision '{spec}' goes past the first commit")
            commit = repo[commit.parents[parent_index]]
            parent_index = 0
    return commit.id


def text(value):
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


COMMANDS = {}


def subcommand(*names):
    def register(func):
        for name in names:
            COMMANDS[name] = func
        return func

    return register


def run(args):
    if not args or args[0] in ("help", "-h", "--help"):
        names = sorted(n for n in COMMANDS)
        print(f"{BOLD}git{RESET} (dulwich) — supported: " + ", ".join(names))
        print(paint(GRAY, "HTTPS remotes only. Add a token in Settings for private repos and pushing."))
        return 0
    handler = COMMANDS.get(args[0])
    if handler is None:
        print(paint(RED, f"git: '{args[0]}' isn't supported here. Try 'git help'."), file=sys.stderr)
        return 1
    try:
        return handler(args[1:]) or 0
    except GitError as error:
        print(paint(RED, f"fatal: {error}"), file=sys.stderr)
    except NotGitRepository:
        print(paint(RED, "fatal: not a git repository"), file=sys.stderr)
    except (HangupException, GitProtocolError) as error:
        message = str(error)
        if "401" in message or "403" in message or "Authentication" in message or "authorization" in message.lower():
            message += "\n" + paint(GRAY, "Authentication failed — add a token in PocketCode Settings → Git.")
        print(paint(RED, f"fatal: {message}"), file=sys.stderr)
    except porcelain.Error as error:
        print(paint(RED, f"fatal: {error}"), file=sys.stderr)
    except KeyError as error:
        print(paint(RED, f"fatal: unknown revision or ref {error}"), file=sys.stderr)
    return 1


# MARK: - Setup


@subcommand("init")
def git_init(args):
    path = os.path.abspath(args[0] if args else ".")
    os.makedirs(path, exist_ok=True)
    repo = porcelain.init(path)
    repo.refs.set_symbolic_ref(b"HEAD", b"refs/heads/main")
    print(f"Initialized empty Git repository in {path}/.git/")


@subcommand("clone")
def git_clone(args):
    depth = branch = None
    positional = []
    it = iter(args)
    for arg in it:
        if arg == "--depth":
            depth = int(next(it))
        elif arg in ("-b", "--branch"):
            branch = next(it)
        else:
            positional.append(arg)
    if not positional:
        raise GitError("usage: git clone <url> [dir] [--depth N] [-b branch]")
    url = positional[0]
    if url.startswith("git@") or url.startswith("ssh://"):
        raise GitError("SSH remotes aren't supported yet — use the https:// URL")
    from .shell import expand

    target = expand(positional[1]) if len(positional) > 1 else os.path.basename(url.rstrip("/")).removesuffix(".git")
    if os.path.exists(target) and os.listdir(target):
        raise GitError(f"destination path '{target}' already exists and is not empty")
    from .shell import display_path

    print(f"Cloning into '{display_path(os.path.abspath(target))}'...")
    started = time.monotonic()
    try:
        porcelain.clone(url, target, depth=depth, branch=branch, errstream=_Progress(), **auth())
    except BaseException:
        if os.path.isdir(target) and not os.listdir(target):
            os.rmdir(target)
        raise
    print(paint(GREEN, f"\nDone in {time.monotonic() - started:.1f}s."))


@subcommand("config")
def git_config(args):
    is_global = "--global" in args
    args = [a for a in args if a not in ("--global", "--local")]
    if is_global:
        path = os.path.join(runtime.HOME, ".gitconfig")
    else:
        path = os.path.join(repo_root(), ".git", "config")
    config = ConfigFile.from_path(path) if os.path.exists(path) else ConfigFile()
    config.path = path
    if not args or args[0] in ("-l", "--list"):
        for section, values in config.items():
            for key, value in values.items():
                name = ".".join(text(p) for p in section) + "." + text(key)
                print(f"{name}={text(value)}")
        return
    section, _, key = args[0].rpartition(".")
    if not section:
        raise GitError("key must look like section.name, e.g. user.name")
    if len(args) == 1:
        try:
            print(text(config.get((section.encode(),), key.encode())))
        except KeyError:
            return 1
    else:
        config.set((section.encode(),), key.encode(), " ".join(args[1:]).encode())
        config.write_to_path(path)


# MARK: - Changes


@subcommand("status", "st")
def git_status(args):
    root = repo_root()
    st = porcelain.status(root)
    branch = text(porcelain.active_branch(root)) if _has_head(root) else "main (no commits yet)"
    print(f"On branch {paint(PURPLE, branch)}")
    staged = [("new file", p) for p in st.staged["add"]] + [("modified", p) for p in st.staged["modify"]] + [
        ("deleted", p) for p in st.staged["delete"]
    ]
    if staged:
        print("Changes to be committed:")
        for kind, path in staged:
            print(paint(GREEN, f"\t{kind + ':':<12}{text(path)}"))
    unstaged = []
    for path in st.unstaged:
        kind = "deleted" if not os.path.exists(os.path.join(root, text(path))) else "modified"
        unstaged.append((kind, path))
    if unstaged:
        print("Changes not staged for commit:")
        for kind, path in unstaged:
            print(paint(RED, f"\t{kind + ':':<12}{text(path)}"))
    if st.untracked:
        print("Untracked files:")
        for path in st.untracked:
            print(paint(RED, f"\t{text(path)}"))
    if not (staged or unstaged or st.untracked):
        print("nothing to commit, working tree clean")


def _has_head(root):
    try:
        Repo(root).head()
        return True
    except KeyError:
        return False


@subcommand("add")
def git_add(args):
    root = repo_root()
    if not args:
        raise GitError("nothing specified, nothing added (try 'git add .')")
    if "-A" in args or "--all" in args or "." in args and os.path.abspath(".") == root:
        _stage_all(root)
        return
    paths = [os.path.abspath(p) for p in args if not p.startswith("-")]
    existing = [p for p in paths if os.path.exists(p)]
    missing = [rel(root, p) for p in paths if not os.path.exists(p)]
    if existing:
        porcelain.add(root, existing)
    if missing:
        porcelain.remove(root, missing, cached=True)


def _stage_all(root):
    st = porcelain.status(root)
    porcelain.add(root)
    deleted = [text(p) for p in st.unstaged if not os.path.exists(os.path.join(root, text(p)))]
    if deleted:
        porcelain.remove(root, deleted, cached=True)


@subcommand("rm")
def git_rm(args):
    root = repo_root()
    cached = "--cached" in args
    paths = [rel(root, p) for p in args if not p.startswith("-")]
    porcelain.remove(root, paths, cached=cached)


@subcommand("mv")
def git_mv(args):
    if len(args) != 2:
        raise GitError("usage: git mv <source> <destination>")
    root = repo_root()
    porcelain.mv(root, rel(root, args[0]), rel(root, args[1]))


@subcommand("restore")
def git_restore(args):
    root = repo_root()
    staged = "--staged" in args
    paths = [rel(root, p) for p in args if not p.startswith("-")]
    if not paths:
        raise GitError("usage: git restore [--staged] <file>...")
    porcelain.restore(root, paths, staged=staged, worktree=not staged)


@subcommand("commit", "ci")
def git_commit(args):
    root = repo_root()
    message = None
    all_ = amend = False
    it = iter(args)
    for arg in it:
        if arg in ("-m", "--message"):
            message = next(it, None)
        elif arg.startswith("-") and not arg.startswith("--") and "m" in arg:
            all_ = "a" in arg
            message = next(it, None)
        elif arg in ("-a", "--all"):
            all_ = True
        elif arg == "--amend":
            amend = True
    if not message:
        raise GitError("please supply a message with -m \"...\"")
    if not _identity(root):
        raise GitError(
            "who are you? Set your identity first:\n"
            '  git config --global user.name "Your Name"\n'
            '  git config --global user.email "you@example.com"'
        )
    if all_:
        st = porcelain.status(root)
        tracked = [text(p) for p in st.unstaged]
        present = [os.path.join(root, p) for p in tracked if os.path.exists(os.path.join(root, p))]
        if present:
            porcelain.add(root, present)
        gone = [p for p in tracked if not os.path.exists(os.path.join(root, p))]
        if gone:
            porcelain.remove(root, gone, cached=True)
    st = porcelain.status(root)
    if not any(st.staged.values()) and not amend:
        print("nothing to commit (use 'git add' first)")
        return 1
    sha = porcelain.commit(root, message=message.encode(), no_verify=True, amend=amend)
    branch = text(porcelain.active_branch(root))
    print(f"[{paint(PURPLE, branch)} {paint(YELLOW, text(sha)[:7])}] {message.splitlines()[0]}")


def _identity(root):
    config = Repo(root).get_config_stack()
    try:
        return config.get((b"user",), b"name") and config.get((b"user",), b"email")
    except KeyError:
        return None


@subcommand("reset")
def git_reset(args):
    root = repo_root()
    mode = "mixed"
    target = "HEAD"
    files = []
    for arg in args:
        if arg in ("--hard", "--soft", "--mixed"):
            mode = arg[2:]
        elif os.path.exists(arg):
            files.append(arg)
        else:
            target = arg
    if files:
        porcelain.restore(root, [rel(root, f) for f in files], staged=True, worktree=False)
    else:
        porcelain.reset(root, mode, resolve(root, target))


@subcommand("stash")
def git_stash(args):
    root = repo_root()
    action = args[0] if args else "push"
    if action == "push":
        porcelain.stash_push(root)
        print("Saved working directory and index state")
    elif action == "pop":
        porcelain.stash_pop(root)
    elif action == "list":
        for index, entry in enumerate(porcelain.stash_list(root)):
            print(f"stash@{{{index}}}: {text(getattr(entry, 'message', entry))}")
    else:
        raise GitError("usage: git stash [push|pop|list]")


# MARK: - History


@subcommand("log")
def git_log(args):
    root = repo_root()
    oneline = "--oneline" in args
    limit = None
    for i, arg in enumerate(args):
        if arg == "-n" and i + 1 < len(args):
            limit = int(args[i + 1])
        elif arg.startswith("-") and arg[1:].isdigit():
            limit = int(arg[1:])
    repo = Repo(root)
    if not _has_head(root):
        raise GitError("your current branch does not have any commits yet")
    for entry in repo.get_walker(max_entries=limit):
        c = entry.commit
        sha = text(c.id)
        title = text(c.message).strip().splitlines()[0] if c.message.strip() else ""
        if oneline:
            print(f"{paint(YELLOW, sha[:7])} {title}")
        else:
            when = time.strftime("%a %b %d %H:%M:%S %Y", time.localtime(c.author_time))
            print(paint(YELLOW, f"commit {sha}"))
            print(f"Author: {text(c.author)}\nDate:   {when}\n")
            for line in text(c.message).rstrip().splitlines():
                print(f"    {line}")
            print()


@subcommand("diff")
def git_diff(args):
    root = repo_root()
    staged = "--staged" in args or "--cached" in args
    positional = [a for a in args if not a.startswith("-")]
    if "--" in args:
        commits, files = positional[: args.index("--")], args[args.index("--") + 1 :]
    else:
        commits = [a for a in positional if not os.path.exists(a)]
        files = [a for a in positional if os.path.exists(a)]
    paths = [rel(root, p).encode() for p in files]
    out = io.BytesIO()
    porcelain.diff(
        root, commit=resolve(root, commits[0]) if commits else None,
        commit2=resolve(root, commits[1]) if len(commits) > 1 else None,
        staged=staged, paths=paths or None, outstream=out,
    )
    for line in out.getvalue().decode("utf-8", "replace").splitlines():
        if line.startswith(("+++", "---", "diff ", "index ")):
            print(paint(BOLD, line))
        elif line.startswith("+"):
            print(paint(GREEN, line))
        elif line.startswith("-"):
            print(paint(RED, line))
        elif line.startswith("@@"):
            print(paint(AQUA, line))
        else:
            print(line)


@subcommand("show")
def git_show(args):
    root = repo_root()
    porcelain.show(root, objects=[resolve(root, a) for a in args] or None, outstream=_MixedOutput())


# MARK: - Branches


@subcommand("branch")
def git_branch(args):
    root = repo_root()
    if not args or args == ["-a"] or args == ["--list"]:
        current = text(porcelain.active_branch(root)) if _has_head(root) else None
        for name in sorted(text(b) for b in porcelain.branch_list(root)):
            print(paint(GREEN, f"* {name}") if name == current else f"  {name}")
        return
    if args[0] in ("-d", "-D", "--delete"):
        for name in args[1:]:
            porcelain.branch_delete(root, name)
            print(f"Deleted branch {name}")
        return
    porcelain.branch_create(root, args[0], args[1] if len(args) > 1 else None)


@subcommand("checkout", "co")
def git_checkout(args):
    root = repo_root()
    if "--" in args:
        files = args[args.index("--") + 1 :]
        porcelain.restore(root, [rel(root, f) for f in files], worktree=True)
        return
    if args[:1] == ["-b"]:
        if len(args) < 2:
            raise GitError("usage: git checkout -b <new-branch>")
        porcelain.checkout(root, args[2] if len(args) > 2 else None, new_branch=args[1])
        print(f"Switched to a new branch '{args[1]}'")
        return
    if not args:
        raise GitError("usage: git checkout <branch> | -b <new-branch> | -- <file>")
    if os.path.isfile(args[0]):
        porcelain.restore(root, [rel(root, args[0])], worktree=True)
        return
    porcelain.checkout(root, args[0])
    print(f"Switched to branch '{args[0]}'")


@subcommand("switch")
def git_switch(args):
    if args[:1] in (["-c"], ["--create"]):
        return git_checkout(["-b", *args[1:]])
    return git_checkout(args)


@subcommand("tag")
def git_tag(args):
    root = repo_root()
    if not args:
        for tag in porcelain.tag_list(root):
            print(text(tag))
    elif args[0] == "-d":
        porcelain.tag_delete(root, args[1])
    else:
        porcelain.tag_create(root, args[0])


# MARK: - Remotes


@subcommand("remote")
def git_remote(args):
    root = repo_root()
    config = Repo(root).get_config()
    if not args or args == ["-v"]:
        for section in config.sections():
            if section[0] == b"remote":
                name, url = text(section[1]), text(config.get(section, b"url"))
                print(f"{name}\t{url} (fetch)\n{name}\t{url} (push)" if args else name)
    elif args[0] == "add" and len(args) == 3:
        porcelain.remote_add(root, args[1], args[2])
    elif args[0] in ("remove", "rm") and len(args) == 2:
        porcelain.remote_remove(root, args[1])
    elif args[0] == "set-url" and len(args) == 3:
        config.set((b"remote", args[1].encode()), b"url", args[2].encode())
        config.write_to_path()
    else:
        raise GitError("usage: git remote [-v] | add <name> <url> | remove <name> | set-url <name> <url>")


@subcommand("push")
def git_push(args):
    root = repo_root()
    force = "-f" in args or "--force" in args
    set_upstream = "-u" in args or "--set-upstream" in args
    positional = [a for a in args if not a.startswith("-")]
    remote = positional[0] if positional else "origin"
    branch = positional[1] if len(positional) > 1 else text(porcelain.active_branch(root))
    porcelain.push(
        root, remote, branch, force=force, set_upstream=set_upstream,
        outstream=_Progress(), errstream=_Progress(), **auth(),
    )
    print(paint(GREEN, f"Pushed {branch} → {remote}"))


@subcommand("pull")
def git_pull(args):
    root = repo_root()
    positional = [a for a in args if not a.startswith("-")]
    remote = positional[0] if positional else "origin"
    branch = positional[1] if len(positional) > 1 else text(porcelain.active_branch(root))
    porcelain.pull(root, remote, branch.encode(), outstream=_Progress(), errstream=_Progress(), **auth())
    print(paint(GREEN, f"Pulled {remote}/{branch}"))


@subcommand("fetch")
def git_fetch(args):
    root = repo_root()
    remote = args[0] if args else "origin"
    porcelain.fetch(root, remote, outstream=_Progress(), errstream=_Progress(), **auth())
    print(paint(GREEN, f"Fetched {remote}"))
