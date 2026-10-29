#!/usr/bin/env bash
#
# mayhem/build.sh — builds gifsicle's in-tree libFuzzer harnesses (test/fuzz/) and the project's
# own test suite. Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline.
#
#   /mayhem/fuzz-gifsicle-main[-standalone]  free-form `gifsicle ARGS` command lines (fuzz_main.c)
#   /mayhem/fuzz-gifsicle[-standalone]       `gifsicle OPTIONS in.gif -o out.gif` (fuzz_gifsicle.c)
#   src/gifsicle, src/gifdiff                NORMAL-flag build that mayhem/test.sh runs (upstream testie suite)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) NORMAL-flag project + test-suite build (upstream's own configure/make), first, so config.h exists
#    for the sanitized harness compiles below. Only gifsicle and gifdiff are needed by the testie suite.
autoreconf -i
(env -u CFLAGS -u LDFLAGS -u CPPFLAGS ./configure --disable-gifview CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS")
make -j"$MAYHEM_JOBS" -C src gifsicle gifdiff

# 2) Sanitized in-process fuzz targets. The harness sources stay in test/fuzz (upstream's); gifsicle's own
#    sources are compiled with -include inprocess.h so exit()/popen()/stdio are redirected in-process.
FUZZ="$SRC/test/fuzz"
OBJ="$SRC/mayhem/build"
rm -rf "$OBJ"; mkdir -p "$OBJ/lib" "$OBJ/harness"
# gifsicle (kcolor.c) and the harness (runner.c) call qsort(NULL, 0, ...) for empty item lists, which trips
# UBSan nonnull-attribute on valid inputs and halts every run; relax only that check (ASan and the rest of
# UBSan stay halting).
CFLAGS_ALL="-O1 $SANITIZER_FLAGS -fno-sanitize=nonnull-attribute $DEBUG_FLAGS"
CPP="-DHAVE_CONFIG_H -I$SRC -I$SRC/include -I$SRC/src"
INPROC="clp fmalloc giffunc gifread gifunopt gifwrite kcolor merge optimize quantize support xform gifsicle"
for s in $INPROC; do
    $CC $CFLAGS_ALL $CPP -include "$FUZZ/inprocess.h" -c "$SRC/src/$s.c" -o "$OBJ/lib/$s.o"
done
for s in runner gifcheck fuzz_gifsicle fuzz_main; do
    $CC $CFLAGS_ALL $CPP -fsanitize=fuzzer-no-link -c "$FUZZ/$s.c" -o "$OBJ/harness/$s.o"
    $CC $CFLAGS_ALL $CPP -c "$FUZZ/$s.c" -o "$OBJ/harness/$s.standalone.o"
done
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

LIBOBJS=""; for s in $INPROC; do LIBOBJS="$LIBOBJS $OBJ/lib/$s.o"; done
for t in fuzz_gifsicle:fuzz-gifsicle fuzz_main:fuzz-gifsicle-main; do
    src=${t%%:*} name=${t#*:}
    $CC $CFLAGS_ALL $LIB_FUZZING_ENGINE -o "/mayhem/$name" \
        "$OBJ/harness/$src.o" "$OBJ/harness/runner.o" "$OBJ/harness/gifcheck.o" $LIBOBJS "$OBJ/lsan_off.o" -lm -lpthread
    $CC $CFLAGS_ALL -o "/mayhem/$name-standalone" \
        "$OBJ/harness/$src.standalone.o" "$OBJ/harness/runner.standalone.o" "$OBJ/harness/gifcheck.standalone.o" \
        $LIBOBJS "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" -lm -lpthread
done
