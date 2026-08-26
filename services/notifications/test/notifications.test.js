"use strict";

const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");

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
  assert.equal(body.service, "notifications");
});

test("GET /notifications starts empty for a fresh instance", async () => {
  const res = await fetch(`${baseUrl}/notifications`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(Array.isArray(body));
  assert.equal(body.length, 0);
});

test("POST /notify creates a notification and it appears in GET /notifications", async () => {
  // This is what the Lambda calls automatically in the Task 1 event flow —
  // tested here directly against the Notifications API, independent of
  // LocalStack/Lambda, which is the correct boundary for a unit-level test.
  const payload = { message: "Your ticket receipt receipt-12345 has been generated.", userId: 1 };
  const postRes = await fetch(`${baseUrl}/notify`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  assert.equal(postRes.status, 201);
  const created = await postRes.json();
  assert.equal(created.message, payload.message);
  assert.equal(created.userId, payload.userId);
  assert.equal(typeof created.sentAt, "string");

  const listRes = await fetch(`${baseUrl}/notifications`);
  const list = await listRes.json();
  assert.ok(list.some((n) => n.id === created.id && n.message === payload.message));
});

test("POST /notify without a message returns 400", async () => {
  const res = await fetch(`${baseUrl}/notify`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ userId: 1 }),
  });
  assert.equal(res.status, 400);
});
