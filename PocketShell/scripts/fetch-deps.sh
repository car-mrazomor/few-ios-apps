#!/bin/sh
# Downloads the vendored runtime into Vendor/ (git-ignored):
#   Vendor/Python.xcframework  - CPython 3.13 for iOS (BeeWare Python-Apple-support)
#   Vendor/app_packages        - pure-Python packages bundled with the app (pip, git via dulwich)
#   Vendor/pyodide             - Pyodide core (notebook kernel); packages are downloaded on demand and cached
#   Vendor/notebook-lib        - CodeMirror 5 (+ vim keymap) and marked for the notebook UI
set -eu
cd "$(dirname "$0")/.."

PYTHON_SUPPORT_TAG=3.13-b13
PIP_PACKAGES="pip==26.2.2 dulwich==1.2.19 urllib3==2.8.0 certifi==2026.10.19"
PYODIDE_VERSION=314.0.7
CODEMIRROR_VERSION=6.65.7  # cdnjs's name for the CodeMirror 5 line
MARKED_VERSION=18.1.1

mkdir -p Vendor
if [ ! -d Vendor/Python.xcframework ]; then
    echo "Downloading Python for iOS ($PYTHON_SUPPORT_TAG)..."
    url="https://github.com/beeware/Python-Apple-support/releases/download/$PYTHON_SUPPORT_TAG/Python-${PYTHON_SUPPORT_TAG%%-*}-iOS-support.${PYTHON_SUPPORT_TAG#*-}.tar.gz"
    tmp=$(mktemp -d)
    curl -fsSL "$url" -o "$tmp/python.tar.gz"
    tar -xzf "$tmp/python.tar.gz" -C "$tmp"
    mv "$tmp/Python.xcframework" Vendor/
    rm -rf "$tmp"
fi

if [ ! -d Vendor/app_packages ]; then
    echo "Downloading bundled Python packages..."
    tmp=$(mktemp -d)
    # Pure-Python wheels only: anything with compiled code can't be loaded unless built and signed for iOS.
    python3 -m pip download --isolated --quiet --no-deps --only-binary=:all: \
        --platform any --implementation py --abi none --python-version 3.13 \
        -d "$tmp" $PIP_PACKAGES
    mkdir -p Vendor/app_packages
    for wheel in "$tmp"/*.whl; do unzip -qo "$wheel" -d Vendor/app_packages; done
    rm -rf Vendor/app_packages/bin "$tmp"
fi
if [ ! -f Vendor/pyodide/pyodide.mjs ]; then
    echo "Downloading Pyodide $PYODIDE_VERSION core..."
    mkdir -p Vendor/pyodide.tmp
    for file in pyodide.js pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json; do
        curl -fsSL "https://cdn.jsdelivr.net/pyodide/v$PYODIDE_VERSION/full/$file" -o "Vendor/pyodide.tmp/$file"
    done
    rm -rf Vendor/pyodide && mv Vendor/pyodide.tmp Vendor/pyodide
fi

if [ ! -f Vendor/notebook-lib/codemirror.min.js ]; then
    echo "Downloading notebook editor libraries..."
    mkdir -p Vendor/notebook-lib.tmp
    base="https://cdnjs.cloudflare.com/ajax/libs/codemirror/$CODEMIRROR_VERSION"
    for file in codemirror.min.js codemirror.min.css keymap/vim.min.js mode/python/python.min.js \
                mode/markdown/markdown.min.js addon/edit/matchbrackets.min.js addon/edit/closebrackets.min.js; do
        curl -fsSL "$base/$file" -o "Vendor/notebook-lib.tmp/$(basename "$file")"
    done
    curl -fsSL "https://cdnjs.cloudflare.com/ajax/libs/marked/$MARKED_VERSION/lib/marked.umd.min.js" -o Vendor/notebook-lib.tmp/marked.min.js
    rm -rf Vendor/notebook-lib && mv Vendor/notebook-lib.tmp Vendor/notebook-lib
fi
echo "PYODIDE_VERSION=$PYODIDE_VERSION" > Vendor/versions.env
echo "Vendor ready."
