#!/usr/bin/env bash
#
# Compile a brainfuck program with this compiler and benchmark the resulting
# binary's runtime.
#
# Usage: bench/bench.sh [BF_FILE] [OPTIMIZE] [RUNS]
#   BF_FILE   brainfuck program to compile   (default: bench/mandelbrot.bf)
#   OPTIMIZE  zig optimize mode              (default: ReleaseFast)
#             one of Debug | ReleaseSafe | ReleaseFast | ReleaseSmall
#   RUNS      number of timed runs           (default: 5)
#
# If a "<BF_FILE without .bf>.sha256" file exists next to the program, the
# compiled binary's output is checked against it before timing.
#
# Compare optimization levels, e.g.:
#   bench/bench.sh bench/mandelbrot.bf Debug
#   bench/bench.sh bench/mandelbrot.bf ReleaseFast
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bf="${1:-bench/mandelbrot.bf}"
optimize="${2:-ReleaseFast}"
runs="${3:-5}"

name="$(basename "$bf")"
exe="zig-out/bin/$name"

echo "==> compiling $bf  (-Doptimize=$optimize)"
BF_FILE_PATH="$bf" zig build "-Doptimize=$optimize"

# Optional correctness check against a committed expected-output hash.
hashfile="${bf%.bf}.sha256"
if [[ -f "$hashfile" ]]; then
  got="$("$exe" < /dev/null | sha256sum | cut -d' ' -f1)"
  exp="$(cut -d' ' -f1 < "$hashfile")"
  if [[ "$got" == "$exp" ]]; then
    echo "==> output OK ($got)"
  else
    echo "==> OUTPUT MISMATCH: got $got, expected $exp" >&2
    exit 1
  fi
fi

echo "==> timing $exe (best of $runs)"
times=()
for _ in $(seq "$runs"); do
  t="$( { TIMEFORMAT='%R'; time "$exe" > /dev/null < /dev/null; } 2>&1 )"
  times+=("$t")
  echo "    ${t}s"
done
best="$(printf '%s\n' "${times[@]}" | sort -g | head -n1)"
echo "==> best of $runs: ${best}s  ($optimize)"
