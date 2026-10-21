"""Writes tests/fixtures/pairing_codes.json: pairing codes in DIDSA-CAD's encoding, for tests/pairing_payload.gd.
DIDSA-CAD writes `didsa-vr:1?n=<name>&u=<url>&k=<key>` with Dart's Uri.encodeQueryComponent, which keeps A-Z a-z 0-9 - . _ ~ and writes a space as '+'
(everything else, UTF-8 percent-encoded). Python's urllib.parse.quote_plus(safe='') is the same function, so these are what the flat app would show.
Not produced by a Dart build: regenerate with `python3 -I tests/fixtures/make_pairing_codes.py` (seeded, so the file is stable)."""
import json
import random
import sys
from urllib.parse import quote_plus

random.seed(20261020)
ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -._~!*'()+&=?#/:@%éüñ日本語😀"
HOSTS = ["cad.example.net", "192.168.1.9:8000", "workshop-pc.local:8443", "machine.tail1234.ts.net", "10.0.0.5", "cad.example.net:8443/api"]


def rand(n):
    return "".join(random.choice(ALPHABET) for _ in range(n)).strip() or "x"


out = []
for i in range(60):
    scheme = "https" if i % 3 else random.choice(["http", "https"])
    host = random.choice(HOSTS)
    if scheme == "http" and host == "cad.example.net" or host == "cad.example.net:8443/api" and scheme == "http":
        scheme = "https"
    url = "%s://%s" % (scheme, host)
    name = rand(random.randint(1, 30))
    key = rand(random.randint(1, 60))
    code = "didsa-vr:1?n=%s&u=%s&k=%s" % (quote_plus(name, safe=""), quote_plus(url, safe=""), quote_plus(key, safe=""))
    out.append({"code": code, "name": name, "url": url, "key": key})
json.dump(out, open(sys.argv[1] if len(sys.argv) > 1 else "tests/fixtures/pairing_codes.json", "w"), ensure_ascii=False, indent=1)
