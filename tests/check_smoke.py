#!/usr/bin/env python3
"""Machine-check a captured test run.

The tests print assertions as `SMOKE <what>: <bool>` lines and exit 0 regardless, so a run only means
something if somebody reads the lines. This reads the log (tests/run_all.sh output: a `== <test>` header,
then that test's SMOKE lines) and fails when:

  * a SMOKE line ends in `false` (or its value is `false`) and is not listed in the baseline file,
  * a `SCRIPT ERROR` / `Parse Error` / `FAIL <test>` line appears,
  * a test printed no SMOKE lines at all (unless it is listed in --no-smoke),
  * (--fail-on-skipped) a line says `SMOKE SKIPPED`.

A baseline line is `<test> | <key>`; `#` lines are comments. The key is the SMOKE text up to the first
": " (the whole line when there is none). Baseline entries that no longer print false, or whose test
vanished, are reported as warnings (stale), never failures: update the file when you see them.

Usage: check_smoke.py LOG [--baseline FILE] [--no-smoke FILE] [--fail-on-skipped]
Stdlib only. Exit 0 = ok, 1 = failures, 2 = bad usage.
"""
import argparse
import re
import sys

ERROR_RE = re.compile(r"SCRIPT ERROR|Parse Error|^FAIL |^SOME FAILED")
HEADER_RE = re.compile(r"^== (\S+)")
# tests with these headers print no SMOKE lines by design
NON_TESTS = {"parse"}


def norm(text):
    return " ".join(text.split())


def smoke_key(line):
    """Key of a SMOKE line (the "SMOKE" prefix included): its text up to the first ': ' (whole line without one),
    whitespace collapsed."""
    head, sep, _ = line.partition(": ")
    return norm(head if sep else line)


def is_false(line):
    """True when the line asserts false: it ends in `false`, or the value after the first ': ' starts with it."""
    text = line.rstrip()
    if text.endswith("false"):
        return True
    _, sep, value = text.partition(": ")
    return bool(sep) and re.match(r"false\b", value) is not None


def read_list(path):
    entries = set()
    if not path:
        return entries
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            test, sep, key = line.partition(" | ")
            entries.add((test.strip(), norm(key)) if sep else (line.strip(), None))
    return entries


def check(log_lines, baseline, no_smoke, fail_on_skipped=False):
    """Returns (failures, warnings) as lists of strings."""
    failures, warnings = [], []
    counts = {}      # test -> number of SMOKE lines
    seen_false = set()
    test = "?"
    for raw in log_lines:
        line = raw.rstrip("\n")
        m = HEADER_RE.match(line)
        if m:
            test = m.group(1)
            if test not in NON_TESTS:
                counts.setdefault(test, 0)
            continue
        if line.startswith("ALL RAN WITHOUT SCRIPT ERRORS"):   # run_all.sh's own summary line
            continue
        if ERROR_RE.search(line):
            failures.append(f"{test}: {line.strip()[:200]}")
            continue
        if not line.startswith("SMOKE"):
            continue
        counts[test] = counts.get(test, 0) + 1
        if fail_on_skipped and line.startswith("SMOKE SKIPPED"):
            failures.append(f"{test}: skipped: {line[:200]}")
        if is_false(line):
            key = smoke_key(line)
            seen_false.add((test, key))
            if (test, key) not in baseline:
                failures.append(f"{test}: unexpected false: {line[:200]}")
    for t, n in counts.items():
        if n == 0 and (t, None) not in no_smoke:
            failures.append(f"{t}: printed no SMOKE lines (list it in the no-smoke file if that is intended)")
    for entry in sorted(e for e in baseline if e[1] is not None):
        if entry not in seen_false:
            warnings.append(f"stale baseline entry (no longer false, or test not run): {entry[0]} | {entry[1]}")
    for t, key in sorted(no_smoke):
        if key is None and counts.get(t, 0) > 0:
            warnings.append(f"stale no-smoke entry (it prints SMOKE lines now): {t}")
    return failures, warnings


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--baseline")
    ap.add_argument("--no-smoke")
    ap.add_argument("--fail-on-skipped", action="store_true")
    args = ap.parse_args(argv)
    try:
        with open(args.log, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        baseline = read_list(args.baseline)
        no_smoke = read_list(args.no_smoke)
    except OSError as e:
        print(f"check_smoke: {e}", file=sys.stderr)
        return 2
    failures, warnings = check(lines, baseline, no_smoke, args.fail_on_skipped)
    n_smoke = sum(1 for l in lines if l.startswith("SMOKE"))
    for w in warnings:
        print("WARNING " + w)
    for fl in failures:
        print("FAILURE " + fl)
    print(f"check_smoke: {n_smoke} SMOKE lines, {len(failures)} failure(s), {len(warnings)} warning(s)")
    if n_smoke == 0:
        print("FAILURE no SMOKE lines at all (did the run crash before printing anything?)")
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
