#!/usr/bin/env python3
"""
WDA helper for EdgeReturn device testing.

Drives the on-device WebDriverAgent (port 8100, forwarded via
`python -m pymobiledevice3 usbmux forward 8100 8100`) over raw HTTP,
because the pip `wda` package in this environment is a buggy build.

Usage:
  python wda_helper.py status
  python wda_helper.py screenshot [out.png]
  python wda_helper.py tap <x> <y>
  python wda_helper.py swipe <x1> <y1> <x2> <y2> [duration_ms]
  python wda_helper.py find <text-or-name>
  python wda_helper.py launch <bundle-id>
  python wda_helper.py terminate <bundle-id>
  python wda_helper.py source
"""
import json
import sys
import time
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:8100"
SESSION = None


def http(method, path, data=None):
    body = None
    if data is not None:
        body = json.dumps(data).encode()
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}
    except Exception as e:
        return -1, {"error": str(e)}


def session_id():
    global SESSION
    if SESSION:
        return SESSION
    code, body = http("GET", "/status")
    if code != 200:
        print("WDA not reachable:", body)
        sys.exit(1)
    code, body = http("POST", "/session", {"capabilities": {}})
    sid = body.get("sessionId") or (body.get("value") or {}).get("sessionId")
    if not sid:
        print("no session:", body)
        sys.exit(1)
    SESSION = sid
    return sid


def screenshot(out="screen.png"):
    code, body = http("GET", "/screenshot")
    if code == 200 and body.get("value"):
        import base64
        data = base64.b64decode(body["value"])
        with open(out, "wb") as f:
            f.write(data)
        print("saved", out, len(data), "bytes")
    else:
        print("screenshot failed:", code, body)


def tap(x, y):
    sid = session_id()
    code, body = http("POST", f"/session/{sid}/actions", {
        "actions": [{
            "type": "pointer",
            "parameters": {"pointerType": "touch"},
            "duration": 120,
            "steps": [
                {"duration": 0, "x": x, "y": y, "type": "pointerMove"},
                {"duration": 0, "type": "pointerDown", "button": 0},
                {"duration": 100, "type": "pause"},
                {"duration": 0, "type": "pointerUp", "button": 0},
            ],
        }]
    })
    print("tap", x, y, "->", code, body.get("value", body))


def swipe(x1, y1, x2, y2, duration_ms=300):
    sid = session_id()
    steps = [
        {"duration": 0, "x": x1, "y": y1, "type": "pointerMove"},
        {"duration": 0, "type": "pointerDown", "button": 0},
    ]
    n = 8
    for i in range(1, n + 1):
        steps.append({
            "duration": duration_ms // (n + 1),
            "x": x1 + (x2 - x1) * i / n,
            "y": y1 + (y2 - y1) * i / n,
            "type": "pointerMove",
        })
    steps.append({"duration": 0, "type": "pointerUp", "button": 0})
    code, body = http("POST", f"/session/{sid}/actions", {
        "actions": [{
            "type": "pointer",
            "parameters": {"pointerType": "touch"},
            "duration": duration_ms,
            "steps": steps,
        }]
    })
    print("swipe", (x1, y1), "->", (x2, y2), f"({duration_ms}ms)", "->", code)


def find(needle):
    sid = session_id()
    code, body = http("GET", f"/session/{sid}/source")
    xml = body.get("value", "")
    import re
    for m in re.finditer(r'<(\w+)[^>]*>', xml):
        tag = m.group(0)
        if needle.lower() in tag.lower():
            print(tag[:300])


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "status":
        code, body = http("GET", "/status")
        print(code, json.dumps(body, indent=2)[:800])
    elif cmd == "screenshot":
        screenshot(sys.argv[2] if len(sys.argv) > 2 else "screen.png")
    elif cmd == "tap":
        tap(float(sys.argv[2]), float(sys.argv[3]))
    elif cmd == "swipe":
        x1, y1, x2, y2 = map(float, sys.argv[2:6])
        dur = int(sys.argv[6]) if len(sys.argv) > 6 else 300
        swipe(x1, y1, x2, y2, dur)
    elif cmd == "find":
        find(sys.argv[2])
    elif cmd == "launch":
        code, body = http("POST", "/wda/apps/launch",
                         {"bundleId": sys.argv[2], "arguments": [], "environment": {}})
        print(code, body)
    elif cmd == "terminate":
        code, body = http("POST", "/wda/apps/terminate", {"bundleId": sys.argv[2]})
        print(code, body)
    elif cmd == "source":
        sid = session_id()
        code, body = http("GET", f"/session/{sid}/source")
        print(body.get("value", "")[:4000])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
