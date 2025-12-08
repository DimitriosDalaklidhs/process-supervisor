import time

i = 0
while True:
    print(f"[worker] iteration {i}", flush=True)
    time.sleep(1)
    if i % 10 == 0:
        for _ in range(5_000_000):
            pass
    i += 1
