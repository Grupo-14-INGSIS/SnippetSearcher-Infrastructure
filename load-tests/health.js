// Carga sobre el chequeo de salud: cada request pasa por nginx, App, Runner y AccessManager.
// No necesita login. Uso: k6 run -e BASE_URL=https://snippet26dev.duckdns.org load-tests/health.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://snippet26dev.duckdns.org';

export const options = {
  stages: [
    { duration: '1m', target: 10 },
    { duration: '3m', target: 20 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<2000'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/api/actuator/health`);
  check(res, {
    'status 200': (r) => r.status === 200,
    'backend UP': (r) => r.body !== null && r.body.includes('"status":"UP"'),
  });
  sleep(1);
}
