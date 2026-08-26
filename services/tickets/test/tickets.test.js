"use strict";

const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");

// Explicitly unset S3_ENDPOINT so this test exercises the Tickets service's
// well-defined "S3 not configured" opt-out path (see services/tickets/server.js)
// rather than trying to reach a real or LocalStack S3 endpoint. This is
// deliberate: it tests real behavior of the actual code path (ticket
// creation still succeeds, and honestly reports s3.uploaded=false) without
// needing LocalStack running or any AWS credentials in CI.
delete process.env.S3_ENDPOINT;

const app = require("../server");

let server;
let baseUrl;

before(() => {
  server = app.listen(0);
  const { port } = server.address();
  baseUrl = `http://127.0.0.1:${port}`;
});

after(() => {
  server.close();
});

test("GET /health returns 200 and service identity", async () => {
  const res = await fetch(`${baseUrl}/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, "ok");
  assert.equal(body.service, "tickets");
});

test("POST /tickets creates a ticket and reports s3.uploaded=false when S3_ENDPOINT is not configured", async () => {
  const res = await fetch(`${baseUrl}/tickets`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ eventId: 1, userId: 1 }),
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.equal(body.eventId, 1);
  assert.equal(body.userId, 1);
  assert.equal(typeof body.receiptId, "string");
  assert.ok(body.receiptId.startsWith("receipt-"));
  // This is the real, current behavior of the code (see services/tickets/server.js) —
  // not a mocked assumption. When LocalStack is actually configured
  // (S3_ENDPOINT set — see k8s/tickets-deployment.yaml / Helm values), the
  // real upload path applies instead, which is covered by
  // test/verify-task1.sh against a real cluster + LocalStack, not here.
  assert.equal(body.s3.uploaded, false);
});

test("POST /tickets with a missing field returns 400", async () => {
  const res = await fetch(`${baseUrl}/tickets`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ eventId: 1 }),
  });
  assert.equal(res.status, 400);
});

test("GET /tickets lists previously created tickets", async () => {
  const res = await fetch(`${baseUrl}/tickets`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(Array.isArray(body));
  assert.ok(body.length >= 1);
});
