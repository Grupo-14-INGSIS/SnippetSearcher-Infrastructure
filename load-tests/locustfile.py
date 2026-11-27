"""Load test for asset-service (PUT / GET / DELETE on /v1/asset/{container}/{key}).

Each simulated user owns its keys, so users never step on each other, and every
response is validated against the status codes the service documents.

Settings (environment variables):
  ASSET_CONTAINER  blob container used for the test (default: loadtest)
  PAYLOAD_KB       size of the uploaded payload in KiB (default: 4)
"""
import os
import random
import uuid

from locust import HttpUser, between, task

CONTAINER = os.getenv("ASSET_CONTAINER", "loadtest")
PAYLOAD = ("println(\"load test\");\n" * 1024)[: int(os.getenv("PAYLOAD_KB", "4")) * 1024]

BASE = f"/v1/asset/{CONTAINER}"
NAME = f"{BASE}/[key]"  # groups all keys under one entry in the stats


class AssetUser(HttpUser):
    wait_time = between(float(os.getenv("WAIT_MIN", "0.1")), float(os.getenv("WAIT_MAX", "1")))

    def on_start(self):
        self.keys: list[str] = []

    def _new_key(self) -> str:
        return f"{uuid.uuid4().hex}.ps"

    @task(3)
    def create_asset(self):
        key = self._new_key()
        with self.client.put(
            f"{BASE}/{key}", data=PAYLOAD, name=f"PUT {NAME}", catch_response=True
        ) as resp:
            if resp.status_code == 201:
                self.keys.append(key)
                resp.success()
            else:
                resp.failure(f"expected 201, got {resp.status_code}")

    @task(2)
    def update_asset(self):
        if not self.keys:
            return
        key = random.choice(self.keys)
        with self.client.put(
            f"{BASE}/{key}", data=PAYLOAD, name=f"PUT (update) {NAME}", catch_response=True
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            else:
                resp.failure(f"expected 200, got {resp.status_code}")

    @task(6)
    def get_asset(self):
        if not self.keys:
            return
        key = random.choice(self.keys)
        with self.client.get(
            f"{BASE}/{key}", name=f"GET {NAME}", catch_response=True
        ) as resp:
            if resp.status_code == 200 and resp.text == PAYLOAD:
                resp.success()
            else:
                resp.failure(f"expected 200 with the uploaded body, got {resp.status_code}")

    @task(1)
    def get_missing_asset(self):
        with self.client.get(
            f"{BASE}/{self._new_key()}", name=f"GET (missing) {NAME}", catch_response=True
        ) as resp:
            if resp.status_code == 404:
                resp.success()
            else:
                resp.failure(f"expected 404, got {resp.status_code}")

    @task(2)
    def delete_asset(self):
        if not self.keys:
            return
        key = self.keys.pop(random.randrange(len(self.keys)))
        with self.client.delete(
            f"{BASE}/{key}", name=f"DELETE {NAME}", catch_response=True
        ) as resp:
            if resp.status_code == 204:
                resp.success()
            else:
                resp.failure(f"expected 204, got {resp.status_code}")

    @task(1)
    def delete_missing_asset(self):
        with self.client.delete(
            f"{BASE}/{self._new_key()}", name=f"DELETE (missing) {NAME}", catch_response=True
        ) as resp:
            if resp.status_code == 404:
                resp.success()
            else:
                resp.failure(f"expected 404, got {resp.status_code}")

    def on_stop(self):
        # leave the storage clean
        for key in self.keys:
            self.client.delete(f"{BASE}/{key}", name=f"DELETE (cleanup) {NAME}")
