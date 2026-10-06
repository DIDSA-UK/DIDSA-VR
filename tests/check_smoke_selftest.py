#!/usr/bin/env python3
"""Self-test for tests/check_smoke.py: a tiny fake log with one expected false, one unexpected false and one
stale baseline entry, plus the other failure kinds. Run in CI before the real suite. Stdlib only."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "check_smoke.py")

LOG = """== parse check
== alpha
SMOKE fine: true
SMOKE intended off: false
SMOKE state line -> open=false
SMOKE info only: true (pressed=false)
== beta
SMOKE broken thing: false
== gamma
SMOKE good: true
== delta
"""
BASELINE = """# comment
alpha | SMOKE intended off
alpha | SMOKE state line -> open=false
alpha | SMOKE was false once
"""


def run(log, baseline, *extra):
    with tempfile.TemporaryDirectory() as d:
        paths = {}
        for name, text in (("log", log), ("baseline", baseline), ("nosmoke", "")):
            paths[name] = os.path.join(d, name)
            with open(paths[name], "w") as f:
                f.write(text)
        p = subprocess.run([sys.executable, "-I", CHECKER, paths["log"], "--baseline", paths["baseline"],
                            "--no-smoke", paths["nosmoke"], *extra], capture_output=True, text=True)
        return p.returncode, p.stdout


def expect(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    return cond


def main():
    ok = True
    rc, out = run(LOG, BASELINE)
    ok &= expect(rc == 1, "unexpected false makes the run fail")
    ok &= expect("beta: unexpected false: SMOKE broken thing: false" in out, "names the unexpected false")
    ok &= expect("alpha: unexpected" not in out, "expected falses (with or without ': ') pass")
    ok &= expect("stale baseline entry" in out and "was false once" in out, "stale baseline entry is a warning")
    ok &= expect("delta: printed no SMOKE lines" in out, "a test with no SMOKE lines fails")
    ok &= expect("parse" not in out.replace("parse check", ""), "the parse header is not a test")

    clean = LOG.replace("SMOKE broken thing: false", "SMOKE broken thing: true").replace("== delta\n", "")
    rc, out = run(clean, BASELINE)
    ok &= expect(rc == 0, "clean log passes, stale entry is only a warning")
    ok &= expect("WARNING stale" in out, "...and is reported")

    rc, out = run(clean + "SCRIPT ERROR: Parse Error: boom\n", BASELINE)
    ok &= expect(rc == 1 and "SCRIPT ERROR" in out, "SCRIPT ERROR fails")
    rc, out = run(clean + "SMOKE SKIPPED: no backend\n", BASELINE)
    ok &= expect(rc == 0, "SKIPPED passes by default")
    rc, out = run(clean + "SMOKE SKIPPED: no backend\n", BASELINE, "--fail-on-skipped")
    ok &= expect(rc == 1, "SKIPPED fails with --fail-on-skipped")
    rc, out = run("== alpha\n", BASELINE)
    ok &= expect(rc == 1, "a log with no SMOKE lines at all fails")
    print("selftest " + ("passed" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
