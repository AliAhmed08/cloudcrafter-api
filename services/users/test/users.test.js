// Lightweight tests using only Node's built-in test runner (node:test),
// assert (node:assert), and the global fetch (stable in Node 18+) — no
// extra test framework or HTTP client dependency required.
//
// A fresh RSA key pair is generated in-memory for every test run (via
// Node's built-in crypto module) and written to a throwaway temp directory.
// This is NEVER committed anywhere — it exists only for the duration of this
// process and is deleted in the `after` hook. It has no relationship to any
// real JWT key used in any deployed environment.
"use strict";

const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");

let app;
let server;
let baseUrl;
let tmpKeysDir;

before(() => {
  tmpKeysDir = fs.mkdtempSync(path.join(os.tmpdir(), "cloudcrafter-users-test-"));
  const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  fs.writeFileSync(path.join(tmpKeysDir, "private.key"), privateKey);
  fs.writeFileSync(path.join(tmpKeysDir, "public.key"), publicKey);

  // Must be set BEFORE requiring server.js, since it reads keys at module load.
  process.env.JWT_KEYS_DIR = tmpKeysDir;
  // eslint-disable-next-line global-require
  app = require("../server");

  server = app.listen(0);
  const { port } = server.address();
  baseUrl = `http://127.0.0.1:${port}`;
});

after(() => {
  server.close();
  fs.rmSync(tmpKeysDir, { recursive: true, force: true });
});

test("GET /health returns 200 and service identity", async () => {
  const res = await fetch(`${baseUrl}/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, "ok");
  assert.equal(body.service, "users");
});

test("POST /login with valid credentials returns a token", async () => {
  const res = await fetch(`${baseUrl}/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "demo", password: "demo123" }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(typeof body.token, "string");
  assert.ok(body.token.length > 0);
});

test("POST /login with invalid credentials returns 401", async () => {
  const res = await fetch(`${baseUrl}/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "demo", password: "wrong-password" }),
  });
  assert.equal(res.status, 401);
  const body = await res.json();
  assert.equal(body.error, "invalid credentials");
});

test("GET /protected with a valid token grants access", async () => {
  const loginRes = await fetch(`${baseUrl}/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "demo", password: "demo123" }),
  });
  const { token } = await loginRes.json();

  const res = await fetch(`${baseUrl}/protected`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.message, "access granted");
  assert.equal(body.user.username, "demo");
});

test("GET /protected without a token returns 401", async () => {
  const res = await fetch(`${baseUrl}/protected`);
  assert.equal(res.status, 401);
  const body = await res.json();
  assert.equal(body.error, "missing token");
});

test("GET /protected with an invalid token returns 403", async () => {
  const res = await fetch(`${baseUrl}/protected`, {
    headers: { Authorization: "Bearer this.is.not.a.valid.jwt" },
  });
  assert.equal(res.status, 403);
  const body = await res.json();
  assert.equal(body.error, "invalid or expired token");
});
