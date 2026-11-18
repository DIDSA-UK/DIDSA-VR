# QR round trip

`scripts/session/qr_encoder.gd` makes the join QR code (Host Session). Its headless test (`tests/qr_encoder.gd`) checks the structure and the error-correction
maths; this folder checks that an **independent reader** decodes what it draws:

```
godot --headless --path . --script res://tools/qr_roundtrip/dump.gd -- /tmp/qr
python3 -m venv /tmp/qrvenv && /tmp/qrvenv/bin/pip install opencv-python-headless
/tmp/qrvenv/bin/python tools/qr_roundtrip/decode.py /tmp/qr
```

Ten texts, versions 1 to 10 (so the version-information blocks of versions 7 and up are covered). Not part of the test suite (it needs OpenCV). A real headset scanning
a real screen is a separate, unverified step (`docs/live-sessions.md`).
