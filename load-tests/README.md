# Load test (asset-service)
locustfile.py es el test de carga de la catedra (austral-ingsis/asset-service, load-test/),
con un solo cambio: la espera entre requests se configura con WAIT_MIN / WAIT_MAX.- En dev/prod corre solo como synthetic check: servicio asset-synthetic de docker-stack.yml
  (1 usuario, una request cada 30-60 s, adentro de la red de Swarm).- En local, como test de carga, con docker compose levantado (asset-service en el 19084):
    pip install -r load-tests/requirements.txt
    locust -f load-tests/locustfile.py --host http://localhost:19084
Variables: ASSET_CONTAINER (default loadtest), PAYLOAD_KB (default 4), WAIT_MIN, WAIT_MAX.