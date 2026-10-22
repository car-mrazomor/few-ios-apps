"""A small POSIX-shell interpreter that runs PocketCode's built-in commands in-process.

Supports: ; && || | & (runs in foreground), newlines, comments, quoting ('...', "...", \\), $VAR ${VAR} $? $# $@ $1..,
$(...) and `...`, globbing, VAR=value, redirections (> >> < 2> 2>> 2>&1 &> >&2), if/elif/else, for, while/until,
case is not supported. Functions: name() { ...; }. Builtins: cd export unset set exit return source . true false
test [ read shift local eval printf.
"""

import fnmatch
import glob
import io
import os
import re
import sys

from .colors import GRAY, RED, paint


class ShellExit(Exception):
    def __init__(self, code):
        self.code = code


class ShellReturn(Exception):
    def __init__(self, code):
        self.code = code


class ParseError(Exception):
    pass


# MARK: - Lexer

OPERATORS = ["2>&1", "&>>", "&>", ">&2", "1>&2", "2>>", "&&", "||", ";;", ">>", "2>", "<<", "|", "&", ";", "<", ">", "(", ")", "{", "}"]


class Word:
    """A word made of parts: ("lit", text) never expands; ("dq", text) expands without splitting; ("raw", text)
    expands, splits and globs."""

    def __init__(self, parts):
        self.parts = parts

    @property
    def literal(self):
        """The word's text if it was written without any quoting (used for keywords)."""
        if len(self.parts) == 1 and self.parts[0][0] == "raw":
            return self.parts[0][1]
        return None

    def __repr__(self):
        return f"Word({self.parts!r})"


def tokenize(source):
    tokens = []
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        if c in " \t":
            i += 1
            continue
        if c == "\\" and i + 1 < n and source[i + 1] == "\n":
            i += 2
            continue
        if c == "\n":
            tokens.append(("nl", "\n"))
            i += 1
            continue
        if c == "#":
            while i < n and source[i] != "\n":
                i += 1
            continue
        for op in OPERATORS:
            # "{" and "}" are only operators when standing alone.
            if op in "{}" and not (source.startswith(op, i) and (i + 1 == n or source[i + 1] in " \t\n;")):
                continue
            if source.startswith(op, i):
                tokens.append(("op", op))
                i += len(op)
                break
        else:
            word, i = read_word(source, i)
            tokens.append(("word", word))
    tokens.append(("eof", None))
    return tokens


def read_word(source, i):
    parts = []
    raw = []
    n = len(source)

    def flush():
        if raw:
            parts.append(("raw", "".join(raw)))
            raw.clear()

    while i < n:
        c = source[i]
        if c in " \t\n;&|<>()":
            # A digit-prefixed redirection like 2> ends the word only if it's the whole word; keep it simple.
            break
        if c == "\\":
            flush()
            if i + 1 < n:
                parts.append(("lit", source[i + 1]))
            i += 2
        elif c == "'":
            flush()
            end = source.find("'", i + 1)
            if end == -1:
                raise ParseError("unterminated single quote")
            parts.append(("lit", source[i + 1 : end]))
            i = end + 1
        elif c == '"':
            flush()
            j = i + 1
            buf = []
            while j < n and source[j] != '"':
                if source[j] == "\\" and j + 1 < n and source[j + 1] in '"\\$`\n':
                    buf.append("\\" + source[j + 1])
                    j += 2
                    continue
                if source.startswith("$(", j):
                    end = matching_paren(source, j + 1)
                    buf.append(source[j : end + 1])
                    j = end + 1
                    continue
                buf.append(source[j])
                j += 1
            if j >= n:
                raise ParseError("unterminated double quote")
            parts.append(("dq", "".join(buf)))
            i = j + 1
        elif source.startswith("$(", i):
            end = matching_paren(source, i + 1)
            raw.append(source[i : end + 1])
            i = end + 1
        elif c == "`":
            end = source.find("`", i + 1)
            if end == -1:
                raise ParseError("unterminated backquote")
            raw.append("$(" + source[i + 1 : end] + ")")
            i = end + 1
        elif source.startswith("${", i):
            end = source.find("}", i)
            if end == -1:
                raise ParseError("bad substitution")
            raw.append(source[i : end + 1])
            i = end + 1
        else:
            raw.append(c)
            i += 1
    flush()
    return Word(parts), i


def matching_paren(source, open_index):
    depth = 0
    i = open_index
    quote = None
    while i < len(source):
        c = source[i]
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unterminated $(")


# MARK: - Parser (AST as tuples)


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def peek(self):
        return self.tokens[self.pos]

    def next(self):
        token = self.tokens[self.pos]
        self.pos += 1
        return token

    def at_keyword(self, *names):
        kind, value = self.peek()
        return kind == "word" and value.literal in names

    def at_op(self, *ops):
        kind, value = self.peek()
        return kind == "op" and value in ops

    def skip_newlines(self):
        while self.peek()[0] == "nl" or self.at_op(";"):
            self.next()

    def expect_keyword(self, name):
        if not self.at_keyword(name):
            raise ParseError(f"expected '{name}'")
        self.next()

    def parse_program(self):
        body = self.parse_list(stop=())
        if self.peek()[0] != "eof":
            kind, value = self.peek()
            raise ParseError(f"syntax error near '{value.literal if kind == 'word' else value}'")
        return body

    def parse_list(self, stop):
        items = []
        self.skip_newlines()
        while self.peek()[0] != "eof" and not self.at_keyword(*stop) and not self.at_op(")", "}"):
            items.append(self.parse_and_or())
            if self.at_op(";", "&") or self.peek()[0] == "nl":
                self.next()
                self.skip_newlines()
            else:
                break
        return ("list", items)

    def parse_and_or(self):
        node = self.parse_pipeline()
        while self.at_op("&&", "||"):
            op = self.next()[1]
            self.skip_newlines()
            node = (op, node, self.parse_pipeline())
        return node

    def parse_pipeline(self):
        negate = False
        if self.at_keyword("!"):
            self.next()
            negate = True
        commands = [self.parse_command()]
        while self.at_op("|"):
            self.next()
            self.skip_newlines()
            commands.append(self.parse_command())
        node = ("pipe", commands) if len(commands) > 1 else commands[0]
        return ("not", node) if negate else node

    def parse_command(self):
        if self.at_keyword("if"):
            node = self.parse_if()
        elif self.at_keyword("for"):
            node = self.parse_for()
        elif self.at_keyword("while", "until"):
            node = self.parse_while()
        elif self.at_op("{"):
            self.next()
            body = self.parse_list(stop=())
            if not self.at_op("}"):
                raise ParseError("expected '}'")
            self.next()
            node = ("group", body)
        elif self.at_op("("):
            self.next()
            body = self.parse_list(stop=())
            if not self.at_op(")"):
                raise ParseError("expected ')'")
            self.next()
            node = ("subshell", body)
        elif self.is_function_definition():
            name = self.next()[1].literal
            self.next(), self.next()  # ( )
            self.skip_newlines()
            node = ("function", name, self.parse_command())
            return node
        else:
            return self.parse_simple()
        return ("redirected", node, self.parse_redirections())

    def is_function_definition(self):
        kind, value = self.peek()
        if kind != "word" or not value.literal or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", value.literal):
            return False
        following = self.tokens[self.pos + 1 : self.pos + 3]
        return [t for t in following] == [("op", "("), ("op", ")")]

    def parse_redirections(self):
        redirections = []
        while self.at_op(">", ">>", "<", "2>", "2>>", "&>", "&>>", "2>&1", ">&2", "1>&2"):
            op = self.next()[1]
            if op in ("2>&1", ">&2", "1>&2"):
                redirections.append((op, None))
            else:
                kind, target = self.next()
                if kind != "word":
                    raise ParseError(f"expected a file name after {op}")
                redirections.append((op, target))
        return redirections

    def parse_simple(self):
        words, redirections = [], []
        while True:
            kind, value = self.peek()
            if kind == "word":
                words.append(self.next()[1])
            elif kind == "op" and value in (">", ">>", "<", "2>", "2>>", "&>", "&>>", "2>&1", ">&2", "1>&2"):
                redirections += self.parse_redirections()
            else:
                break
        if not words and not redirections:
            raise ParseError(f"syntax error near '{value if kind == 'op' else 'newline'}'")
        return ("simple", words, redirections)

    def parse_if(self):
        branches = []
        self.expect_keyword("if")
        condition = self.parse_list(stop=("then",))
        self.expect_keyword("then")
        branches.append((condition, self.parse_list(stop=("elif", "else", "fi"))))
        otherwise = None
        while self.at_keyword("elif"):
            self.next()
            condition = self.parse_list(stop=("then",))
            self.expect_keyword("then")
            branches.append((condition, self.parse_list(stop=("elif", "else", "fi"))))
        if self.at_keyword("else"):
            self.next()
            otherwise = self.parse_list(stop=("fi",))
        self.expect_keyword("fi")
        return ("if", branches, otherwise)

    def parse_for(self):
        self.expect_keyword("for")
        kind, name = self.next()
        if kind != "word" or not name.literal:
            raise ParseError("bad for loop variable")
        items = None
        if self.peek()[0] == "nl":
            self.skip_newlines()
        if self.at_keyword("in"):
            self.next()
            items = []
            while self.peek()[0] == "word" and not self.at_keyword("do"):
                items.append(self.next()[1])
        self.skip_newlines()
        self.expect_keyword("do")
        body = self.parse_list(stop=("done",))
        self.expect_keyword("done")
        return ("for", name.literal, items, body)

    def parse_while(self):
        until = self.next()[1].literal == "until"
        condition = self.parse_list(stop=("do",))
        self.expect_keyword("do")
        body = self.parse_list(stop=("done",))
        self.expect_keyword("done")
        return ("while", condition, body, until)


def parse(source):
    return Parser(tokenize(source)).parse_program()


# MARK: - Interpreter


class Shell:
    def __init__(self, run_command):
        #: run_command(name, args) -> int, for PocketCode's registered commands; returns None if unknown.
        self.run_command = run_command
        self.variables = {}
        self.functions = {}
        self.positional = []
        self.script_name = "pcsh"
        self.status = 0
        self.errexit = False

    # Entry points

    def run(self, source):
        tree = parse(source)
        try:
            return self.execute(tree)
        except ShellExit as exit:
            self.status = exit.code
            return exit.code

    def capture(self, source):
        """Runs source with stdout captured; returns (status, output)."""
        buffer = io.StringIO()
        saved = sys.stdout
        sys.stdout = buffer
        try:
            status = self.run(source)
        finally:
            sys.stdout = saved
        return status, buffer.getvalue()

    # Execution

    def execute(self, node):
        kind = node[0]
        if kind == "list":
            status = 0
            for item in node[1]:
                status = self.execute(item)
                if self.errexit and status != 0 and item[0] not in ("&&", "||", "not"):
                    raise ShellExit(status)
            return status
        if kind == "&&":
            status = self.execute(node[1])
            return self.execute(node[2]) if status == 0 else status
        if kind == "||":
            status = self.execute(node[1])
            return status if status == 0 else self.execute(node[2])
        if kind == "not":
            self.status = 0 if self.execute(node[1]) else 1
            return self.status
        if kind == "pipe":
            return self.execute_pipe(node[1])
        if kind == "simple":
            return self.execute_simple(node[1], node[2])
        if kind == "redirected":
            return self.with_redirections(node[2], lambda: self.execute(node[1]))
        if kind == "group":
            return self.execute(node[1])
        if kind == "subshell":
            saved_cwd, saved_vars, saved_env = os.getcwd(), dict(self.variables), dict(os.environ)
            try:
                return self.execute(node[1])
            except ShellExit as exit:
                return exit.code
            finally:
                os.chdir(saved_cwd)
                self.variables = saved_vars
                os.environ.clear()
                os.environ.update(saved_env)
        if kind == "if":
            for condition, body in node[1]:
                if self.execute(condition) == 0:
                    return self.execute(body)
            return self.execute(node[2]) if node[2] else 0
        if kind == "for":
            items = self.expand_words(node[2]) if node[2] is not None else list(self.positional)
            status = 0
            for item in items:
                self.variables[node[1]] = item
                status = self.execute(node[3])
            return status
        if kind == "while":
            status = 0
            while (self.execute(node[1]) == 0) != node[3]:
                status = self.execute(node[2])
            return status
        if kind == "function":
            self.functions[node[1]] = node[2]
            return 0
        raise ParseError(f"unknown node {kind}")

    def execute_pipe(self, commands):
        data = None
        status = 0
        for index, command in enumerate(commands):
            last = index == len(commands) - 1
            saved_in, saved_out = sys.stdin, sys.stdout
            if data is not None:
                sys.stdin = io.StringIO(data)
            buffer = None if last else io.StringIO()
            if buffer is not None:
                sys.stdout = buffer
            try:
                status = self.execute(command)
            finally:
                sys.stdin, sys.stdout = saved_in, saved_out
            data = buffer.getvalue() if buffer is not None else None
        self.status = status
        return status

    def execute_simple(self, words, redirections):
        assignments = []
        while words and (assignment := split_assignment(words[0])):
            name, value = assignment
            assignments.append((name, " ".join(self.expand_word(value, split=False)) if value.parts else ""))
            words = words[1:]
        if not words:
            for name, value in assignments:
                self.variables[name] = value
                if name in os.environ:
                    os.environ[name] = value
            self.status = self.with_redirections(redirections, lambda: 0)
            return self.status

        args = self.expand_words(words)
        if not args:
            return self.with_redirections(redirections, lambda: 0)

        saved_env = {name: os.environ.get(name) for name, _ in assignments}
        for name, value in assignments:
            os.environ[name] = value
        try:
            self.status = self.with_redirections(redirections, lambda: self.call(args[0], args[1:]))
        finally:
            for name, value in saved_env.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        return self.status

    def call(self, name, args):
        if name in self.functions:
            saved = self.positional
            self.positional = args
            try:
                return self.execute(self.functions[name])
            except ShellReturn as ret:
                return ret.code
            finally:
                self.positional = saved
        builtin = getattr(self, "builtin_" + name.replace("[", "test").replace(".", "source"), None)
        if builtin is not None and name not in ("run",):
            return builtin(args)
        status = self.run_command(name, args)
        if status is None:
            print(paint(RED, f"pcsh: command not found: {name}") + paint(GRAY, "  (type 'help')"), file=sys.stderr)
            return 127
        return status

    # Redirections

    def with_redirections(self, redirections, action):
        if not redirections:
            return action()
        saved = (sys.stdin, sys.stdout, sys.stderr)
        opened = []
        try:
            for op, target in redirections:
                if op in ("2>&1",):
                    sys.stderr = sys.stdout
                    continue
                if op in (">&2", "1>&2"):
                    sys.stdout = sys.stderr
                    continue
                path = os.path.expanduser("".join(self.expand_word(target, split=False)))
                from .shell import expand

                path = expand(path)
                if path == "/dev/null":
                    stream = io.StringIO() if op != "<" else io.StringIO("")
                elif op == "<":
                    stream = open(path, encoding="utf-8")
                else:
                    stream = open(path, "a" if op.endswith(">>") else "w", encoding="utf-8")
                opened.append(stream)
                if op == "<":
                    sys.stdin = stream
                elif op in (">", ">>"):
                    sys.stdout = stream
                elif op in ("2>", "2>>"):
                    sys.stderr = stream
                elif op in ("&>", "&>>"):
                    sys.stdout = sys.stderr = stream
            return action()
        finally:
            sys.stdin, sys.stdout, sys.stderr = saved
            for stream in opened:
                stream.close()

    # Expansion

    def expand_words(self, words):
        result = []
        for word in words:
            result.extend(self.expand_word(word, split=True))
        return result

    def expand_word(self, word, split):
        """Returns a list of fields."""
        fields = [""]
        has_glob = False
        quoted_any = False
        for kind, text in word.parts:
            if kind == "lit":
                fields[-1] += text
                quoted_any = True
            elif kind == "dq":
                value = self.expand_text(re.sub(r'\\(["\\$`])', r"\1", text), at_quoted=True)
                if isinstance(value, list):  # "$@"
                    if value:
                        fields[-1] += value[0]
                        fields.extend(value[1:])
                else:
                    fields[-1] += value
                quoted_any = True
            else:
                value = self.expand_text(text, at_quoted=False)
                if isinstance(value, list):
                    value = " ".join(value)
                if text.startswith("~") and fields == [""]:
                    from .shell import expand

                    value = expand(value) if value == "~" or value.startswith("~/") else value
                if split and re.search(r"\$", text):
                    pieces = value.split()
                    if pieces:
                        fields[-1] += pieces[0]
                        fields.extend(pieces[1:])
                    if value and value[-1].isspace() and pieces:
                        fields.append("")
                else:
                    fields[-1] += value
                if any(ch in text for ch in "*?[") and not text.startswith("$"):
                    has_glob = True
        if split and has_glob and not quoted_any and len(fields) == 1:
            matches = sorted(glob.glob(fields[0]))
            if matches:
                return matches
        if split and not quoted_any and fields == [""]:
            return []
        return [f for f in fields if f != "" or quoted_any]

    def expand_text(self, text, at_quoted):
        if text == "$@" or text == "${@}":
            return list(self.positional) if at_quoted else " ".join(self.positional)
        out = []
        i = 0
        while i < len(text):
            c = text[i]
            if c == "$" and text.startswith("$(", i):
                end = matching_paren(text, i + 1)
                _, output = Shell.capture(self, text[i + 2 : end])
                out.append(output.rstrip("\n"))
                i = end + 1
            elif c == "$" and text.startswith("${", i):
                end = text.find("}", i)
                out.append(self.expand_parameter(text[i + 2 : end]))
                i = end + 1
            elif c == "$" and i + 1 < len(text) and (text[i + 1].isalnum() or text[i + 1] in "_?#@*$!"):
                if text[i + 1] in "?#@*$!" or text[i + 1].isdigit():
                    name = text[i + 1]
                    i += 2
                else:
                    match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i + 1 :])
                    name = match.group(0)
                    i += 1 + len(name)
                out.append(self.lookup(name))
            else:
                out.append(c)
                i += 1
        return "".join(out)

    def expand_parameter(self, spec):
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?#@*])(?:(:?[-=+?])(.*))?", spec)
        if not match:
            if spec.startswith("#"):
                return str(len(self.lookup(spec[1:])))
            raise ParseError(f"bad substitution: ${{{spec}}}")
        name, op, word = match.groups()
        value = self.lookup(name)
        if not op:
            return value
        is_set = value != "" if op.startswith(":") else (name in self.variables or name in os.environ)
        word = self.expand_text(word or "", at_quoted=True)
        if op.endswith("-"):
            return value if is_set else word
        if op.endswith("="):
            if not is_set:
                self.variables[name] = word
                return word
            return value
        if op.endswith("+"):
            return word if is_set else ""
        if op.endswith("?"):
            if not is_set:
                raise ShellExit(self.error(f"{name}: {word or 'parameter not set'}"))
            return value
        return value

    def lookup(self, name):
        if name == "?":
            return str(self.status)
        if name == "#":
            return str(len(self.positional))
        if name in ("@", "*"):
            return " ".join(self.positional)
        if name == "$":
            return str(os.getpid())
        if name == "!":
            return ""
        if name.isdigit():
            index = int(name)
            if index == 0:
                return self.script_name
            return self.positional[index - 1] if index <= len(self.positional) else ""
        if name in self.variables:
            return self.variables[name]
        return os.environ.get(name, "")

    def error(self, message, code=1):
        print(paint(RED, f"pcsh: {message}"), file=sys.stderr)
        return code

    # MARK: Builtins

    def builtin_cd(self, args):
        from . import runtime
        from .shell import expand

        target = expand(args[0]) if args else runtime.WORKSPACE
        if target == "-":
            target = self.variables.get("OLDPWD", os.getcwd())
        try:
            previous = os.getcwd()
            os.chdir(target)
            self.variables["OLDPWD"] = previous
            os.environ["PWD"] = os.getcwd()
            return 0
        except OSError as error:
            return self.error(f"cd: {target}: {error.strerror}")

    def builtin_export(self, args):
        for arg in args:
            name, eq, value = arg.partition("=")
            if eq:
                self.variables[name] = value
            os.environ[name] = self.variables.get(name, os.environ.get(name, ""))
        return 0

    def builtin_unset(self, args):
        for name in args:
            self.variables.pop(name, None)
            os.environ.pop(name, None)
            self.functions.pop(name, None)
        return 0

    def builtin_set(self, args):
        for arg in args:
            if arg in ("-e", "-o errexit"):
                self.errexit = True
            elif arg == "+e":
                self.errexit = False
            elif arg == "--":
                continue
        if args and args[0] == "--":
            self.positional = args[1:]
        return 0

    def builtin_exit(self, args):
        raise ShellExit(int(args[0]) if args else self.status)

    def builtin_return(self, args):
        raise ShellReturn(int(args[0]) if args else self.status)

    def builtin_true(self, args):
        return 0

    def builtin_false(self, args):
        return 1

    def builtin_shift(self, args):
        count = int(args[0]) if args else 1
        self.positional = self.positional[count:]
        return 0

    def builtin_local(self, args):
        for arg in args:
            name, _, value = arg.partition("=")
            self.variables[name] = value
        return 0

    def builtin_eval(self, args):
        return self.run(" ".join(args))

    def builtin_source(self, args):
        if not args:
            return self.error("source: filename argument required", 2)
        from .shell import expand

        with open(expand(args[0]), encoding="utf-8") as f:
            source = f.read()
        saved = self.positional
        self.positional = args[1:] or self.positional
        try:
            return self.execute(parse(source))
        except ShellReturn as ret:
            return ret.code
        finally:
            self.positional = saved

    def builtin_read(self, args):
        names = [a for a in args if not a.startswith("-")]
        prompt = None
        if "-p" in args:
            prompt = args[args.index("-p") + 1]
            names = [n for n in names if n != prompt]
        if prompt:
            sys.stdout.write(prompt)
        line = sys.stdin.readline()
        if not line:
            return 1
        values = line.rstrip("\n").split(None, max(0, len(names) - 1)) if names else [line.rstrip("\n")]
        for i, name in enumerate(names or ["REPLY"]):
            self.variables[name] = values[i] if i < len(values) else ""
        return 0

    def builtin_printf(self, args):
        if not args:
            return 0
        fmt = args[0].encode().decode("unicode_escape")
        values = args[1:]
        count = max(1, len(re.findall(r"%[-+ 0#]*\d*(?:\.\d+)?[sdifxXoc%]", fmt)) - fmt.count("%%"))
        chunks = [values[i : i + count] for i in range(0, max(len(values), 1), count)] or [[]]
        for chunk in chunks:
            converted = []
            specs = [s for s in re.findall(r"%[-+ 0#]*\d*(?:\.\d+)?([sdifxXoc])", fmt)]
            for spec, value in zip(specs, chunk + [""] * (len(specs) - len(chunk))):
                converted.append(int(value or 0) if spec in "dixXoc" else float(value or 0) if spec == "f" else value)
            sys.stdout.write(fmt % tuple(converted))
        return 0

    def builtin_test(self, args):
        if args and args[-1] == "]":
            args = args[:-1]
        try:
            return 0 if evaluate_test(args) else 1
        except (ValueError, IndexError):
            return self.error("test: bad expression", 2)


def split_assignment(word):
    """NAME=value words: returns (name, value word) or None. The value may be quoted: X="a b" or X=$(cmd)."""
    if not word.parts or word.parts[0][0] != "raw":
        return None
    match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=", word.parts[0][1])
    if not match:
        return None
    rest = word.parts[0][1][match.end() :]
    return match.group(1), Word(([("raw", rest)] if rest else []) + word.parts[1:])


def evaluate_test(args):
    if not args:
        return False
    if args[0] == "!":
        return not evaluate_test(args[1:])
    if "-a" in args:
        i = args.index("-a")
        return evaluate_test(args[:i]) and evaluate_test(args[i + 1 :])
    if "-o" in args:
        i = args.index("-o")
        return evaluate_test(args[:i]) or evaluate_test(args[i + 1 :])
    if len(args) == 1:
        return args[0] != ""
    if len(args) == 2:
        op, value = args
        return {
            "-n": lambda: value != "",
            "-z": lambda: value == "",
            "-e": lambda: os.path.exists(value),
            "-f": lambda: os.path.isfile(value),
            "-d": lambda: os.path.isdir(value),
            "-s": lambda: os.path.isfile(value) and os.path.getsize(value) > 0,
            "-r": lambda: os.access(value, os.R_OK),
            "-w": lambda: os.access(value, os.W_OK),
            "-x": lambda: os.access(value, os.X_OK),
        }.get(op, lambda: False)()
    left, op, right = args[0], args[1], args[2]
    if op in ("=", "=="):
        return left == right
    if op == "!=":
        return left != right
    numbers = {"-eq": "__eq__", "-ne": "__ne__", "-lt": "__lt__", "-le": "__le__", "-gt": "__gt__", "-ge": "__ge__"}
    if op in numbers:
        return getattr(int(left), numbers[op])(int(right))
    return False
