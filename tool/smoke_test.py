import json
import time
import urllib.request

BASE = "http://127.0.0.1:18080"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def post(path, body):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


print(post("/navigate", {"tab": 0}))
time.sleep(8)

print("== state ==")
print(get("/state"))

print("== cache stats（缩略图写入情况） ==")
print(get("/cache"))

print("== log ==")
r = get("/log?n=12")
for line in r.get("lines", []):
    print(line)
