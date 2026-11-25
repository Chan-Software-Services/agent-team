// The clock shim tests/run bats --clock-ahead loads into every process of a run with LD_PRELOAD,
// so a test that will fail on a later date fails today: with CLOCKSHIFT_SECONDS=<n> (a whole
// number, unset or empty for 0), a process reads the wall clock <n> seconds later.
//
// It moves the wall clock as the C library hands it out: time(), gettimeofday() and
// clock_gettime() on CLOCK_REALTIME and CLOCK_REALTIME_COARSE, so date, bash's $EPOCHSECONDS and
// printf %(...)T, a dynamically linked jq's now, Python's time.time() and Node's Date.now() all
// read the moved clock.
//
// It does not move:
// - the times the kernel writes on files (a file's mtime is the real clock's, so a test comparing
//   a file's age with now reads the file a year old), which is what a test tagged
//   "# bats test_tags=wall-clock" rests on;
// - a statically linked binary, which never loads it: the jq release binary is one, so CI's
//   future-clock job builds its jq from source, and tests/run checks jq's now moves;
// - a process started with an emptied environment (env -i), which drops LD_PRELOAD;
// - the clocks that measure durations (CLOCK_MONOTONIC, CLOCK_BOOTTIME), so timeouts and sleeps
//   run as they would.
//
// Build: cc -shared -fPIC -O2 -o clockshift.so clockshift.c -ldl
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

static long shift(void) {
  const char *s = getenv("CLOCKSHIFT_SECONDS");
  return s ? atol(s) : 0;
}

int clock_gettime(clockid_t id, struct timespec *ts) {
  static int (*real)(clockid_t, struct timespec *);
  if (!real) real = dlsym(RTLD_NEXT, "clock_gettime");
  int r = real(id, ts);
  if (r == 0 && (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE)) ts->tv_sec += shift();
  return r;
}

int gettimeofday(struct timeval *restrict tv, void *restrict tz) {
  static int (*real)(struct timeval *restrict, void *restrict);
  if (!real) real = dlsym(RTLD_NEXT, "gettimeofday");
  int r = real(tv, tz);
  if (r == 0 && tv) tv->tv_sec += shift();
  return r;
}

time_t time(time_t *t) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  if (t) *t = ts.tv_sec;
  return ts.tv_sec;
}
