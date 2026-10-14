"""Inert fixture run by an installed Python, never compiled into an executable."""
import base64
import sys
import time

if sys.argv[1] == "echo":
    for arg in sys.argv[2:]:
        print(base64.b64encode(arg.encode("utf-8")).decode("ascii"))
elif sys.argv[1] == "fail":
    print("expected failure", file=sys.stderr, flush=True)
    sys.exit(7)
elif sys.argv[1] == "idle":
    print("unrelated process", flush=True)
    time.sleep(60)
