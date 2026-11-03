#!/bin/sh
set -e
SRC="${1:-$(dirname "$0")/../../minnet}"
DST="$(dirname "$0")/../MinnetCam"
cp "$SRC/include/minnet.h" "$SRC/src/minnet.c" "$SRC/src/gemm.c" "$SRC/src/gemm.h" "$DST/Engine/"
cp "$SRC/models/cifar10.mnet" "$SRC/models/cifar10.labels" "$DST/Resources/"
echo "synced from $SRC"
