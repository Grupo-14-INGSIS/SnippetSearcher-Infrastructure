// Carga sobre la API con un usuario real. Solo lectura: no crea ni modifica snippets.
// Uso: k6 run -e BASE_URL=https://snippet26dev.duckdns.org -e TOKEN=<token> [-e SNIPPET_ID=<id>] load-tests/api-autenticada.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'https://snippet26dev.duckdns.org';
const TOKEN = __ENV.TOKEN;
const SNIPPET_ID = __ENV.SNIPPET_ID;

export const options = {
  stages: [
    { duration: '1m', target: 5 },
    { duration: '3m', target: 10 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<3000'],
  },
};

export function setup() {
  if (!TOKEN) {
    throw new Error('Falta TOKEN: pasalo con -e TOKEN=<token> (ver load-tests/README.md)');
  }
}

function params() {
  // X-Request-Id propio: permite buscar cada request en New Relic (Documentación/NEW_RELIC.md, sección 8)
  return { headers: { Authorization: `Bearer ${TOKEN}`, 'X-Request-Id': `k6-${uuidv4()}` } };
}

export default function () {
  const list = http.get(`${BASE_URL}/api/v1/snippets`, params());
  check(list, { 'lista 200': (r) => r.status === 200 });

  if (SNIPPET_ID) {
    const one = http.get(`${BASE_URL}/api/v1/snippets/${SNIPPET_ID}`, params());
    check(one, { 'snippet 200': (r) => r.status === 200 });
  }
  sleep(1);
}
