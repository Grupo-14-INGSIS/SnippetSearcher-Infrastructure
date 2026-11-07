"""Tests de carga para ver tráfico en New Relic. Correrlos solo contra dev (ver load-tests/README.md).

Dos tipos de usuario, se elige uno al lanzar Locust:
- HealthUser: /api/actuator/health, sin login. Pasa por nginx, App, Runner y AccessManager.
- ApiUser: lista snippets (y lee uno, si se indica) con el token propio. Solo lectura.
"""

import os
import uuid

from locust import HttpUser, between, task
from locust.exception import StopUser

TOKEN = os.environ.get("TOKEN")
SNIPPET_ID = os.environ.get("SNIPPET_ID")


def request_id() -> str:
    # X-Request-Id propio: permite buscar cada request en New Relic (Documentación/NEW_RELIC.md, sección 8)
    return f"locust-{uuid.uuid4()}"


class HealthUser(HttpUser):
    wait_time = between(0.5, 1.5)

    @task
    def health(self):
        with self.client.get(
            "/api/actuator/health",
            headers={"X-Request-Id": request_id()},
            catch_response=True,
        ) as response:
            if response.status_code != 200 or '"status":"UP"' not in response.text:
                response.failure(f"backend no está UP: {response.status_code}")


class ApiUser(HttpUser):
    wait_time = between(1, 2)

    def on_start(self):
        if not TOKEN:
            print("Falta la variable TOKEN (ver load-tests/README.md)")
            raise StopUser()

    def headers(self) -> dict:
        return {"Authorization": f"Bearer {TOKEN}", "X-Request-Id": request_id()}

    @task(3)
    def list_snippets(self):
        self.client.get("/api/v1/snippets", headers=self.headers(), name="/api/v1/snippets")

    @task(1)
    def get_snippet(self):
        if SNIPPET_ID:
            self.client.get(
                f"/api/v1/snippets/{SNIPPET_ID}",
                headers=self.headers(),
                name="/api/v1/snippets/[id]",
            )
