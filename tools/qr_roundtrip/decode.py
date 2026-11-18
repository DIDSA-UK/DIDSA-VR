"""Reads the PNGs dump.gd wrote with OpenCV's QR reader (an independent decoder) and checks the text is exactly what was encoded.
Needs: pip install opencv-python-headless. Usage: python3 decode.py <folder>   Exit 0 when every code decodes to its text."""
import sys

import cv2

WANT = {
    "a": "HELLO",
    "b": "didsa-join:1?c=K7XQ4M",
    "c": "didsa-join:1?h=wss%3A%2F%2Fsessions.example.net&c=K7XQ4M",
    "d": "didsa-join:1?h=wss%3A%2F%2Fsessions.example.net%3A8300&c=K7XQ4M",
    "e": "didsa-join:1?h=ws%3A%2F%2F192.168.100.200%3A8300&c=K7XQ4M",
    "f": "x" * 40,
    "g": "y" * 100,
    "h": "z" * 150,
    "i": "w" * 200,
    "j": "Mixed 1234 ~!@#$%^&*() end" * 5,
}
detector = cv2.QRCodeDetector()
bad = 0
for key, text in WANT.items():
    image = cv2.imread(f"{sys.argv[1]}/{key}.png", cv2.IMREAD_GRAYSCALE)
    got, _, _ = detector.detectAndDecode(image)
    ok = got == text
    bad += 0 if ok else 1
    print(key, "ok" if ok else f"FAIL (read {got!r})")
print(f"{bad} failure(s)")
sys.exit(1 if bad else 0)
