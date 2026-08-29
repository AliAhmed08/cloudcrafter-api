// Demonstrates the JWT rotation lifecycle end-to-end against the real
// server.js code (not a mock) by rewriting the temp "Secret" directory
// between phases and forcing a fresh require() each time — this mirrors
// what actually happens in Kubernetes when the mounted Secret changes and
// the pod restarts (see docs/jwt-key-rotation.md for the real procedure).
//
// All key material here is generated in-memory per test run via Node's
// built-in crypto module and written to a throwaway temp directory —
// nothing is committed, nothing resembles a real deployed key.
"use strict";

const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const jwt = require("jsonwebtoken");

let tmpKeysDir;
const servers = [];

function generateKeyPair() {
  return crypto.generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
}

function writeCurrent(dir, { privateKey, publicKey }, kid) {
  fs.writeFileSync(path.join(dir, "current-private.key"), privateKey);
  fs.writeFileSync(path.join(dir, "current-public.key"), publicKey);
  fs.writeFileSync(path.join(dir, "current-kid"), kid);
}

function writePrevious(dir, { publicKey }, kid) {
  fs.writeFileSync(path.join(dir, "previous-public.key"), publicKey);
  fs.writeFileSync(path.join(dir, "previous-kid"), kid);
}

function removePrevious(dir) {
  fs.rmSync(path.join(dir, "previous-public.key"), { force: true });
  fs.rmSync(path.join(dir, "previous-kid"), { force: true });
}

// Forces server.js to re-read whatever is currently on disk in tmpKeysDir —
// analogous to a pod restart picking up an updated Secret mount.
function freshServerInstance() {
  delete require.cache[require.resolve("../server")];
  process.env.JWT_KEYS_DIR = tmpKeysDir;
  const app = require("../server");
  const server = app.listen(0);
  servers.push(server);
  const { port } = server.address();
  return { app, server, baseUrl: `http://127.0.0.1:${port}` };
}

async function login(baseUrl) {
  const res = await fetch(`${baseUrl}/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "demo", password: "demo123" }),
  });
  const { token } = await res.json();
  return token;
}

async function checkProtected(baseUrl, token) {
  const res = await fetch(`${baseUrl}/protected`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return res.status;
}

before(() => {
  tmpKeysDir = fs.mkdtempSync(path.join(os.tmpdir(), "cloudcrafter-jwt-rotation-test-"));
});

after(() => {
  for (const s of servers) s.close();
  fs.rmSync(tmpKeysDir, { recursive: true, force: true });
});

test("JWT rotation: full lifecycle (pre-rotation -> grace period -> retired)", async () => {
  // --- Phase 0: pre-rotation. Only "keyA" exists. ---
  const keyA = generateKeyPair();
  writeCurrent(tmpKeysDir, keyA, "key-a");

  const instance0 = freshServerInstance();
  const tokenSignedByA = await login(instance0.baseUrl);
  assert.equal(
    await checkProtected(instance0.baseUrl, tokenSignedByA),
    200,
    "a token signed by the only existing key must verify"
  );

  // --- Phase 2 cutover: keyB becomes current, keyA becomes previous
  //     (this is the state the rollout reaches after docs/jwt-key-rotation.md's
  //     phase 1 + phase 2 steps have both been applied). ---
  const keyB = generateKeyPair();
  writeCurrent(tmpKeysDir, keyB, "key-b");
  writePrevious(tmpKeysDir, keyA, "key-a");

  const instance1 = freshServerInstance();

  // The OLD token (signed by keyA, before rotation) must STILL be valid —
  // this is the "existing tokens signed by the old key remain valid during
  // the grace period" requirement.
  assert.equal(
    await checkProtected(instance1.baseUrl, tokenSignedByA),
    200,
    "a token signed by the previous key must still verify during the grace period"
  );

  // A brand-new login now gets a token signed by the NEW key.
  const tokenSignedByB = await login(instance1.baseUrl);
  const decodedB = jwt.decode(tokenSignedByB, { complete: true });
  assert.equal(decodedB.header.kid, "key-b", "new logins must be signed with the new current key");
  assert.equal(
    await checkProtected(instance1.baseUrl, tokenSignedByB),
    200,
    "a token signed by the new current key must verify"
  );

  // --- Phase 3: retire the old key entirely (grace period over). ---
  removePrevious(tmpKeysDir);
  const instance2 = freshServerInstance();

  // The OLD token must now be REJECTED.
  assert.equal(
    await checkProtected(instance2.baseUrl, tokenSignedByA),
    403,
    "a token signed by a retired key must be rejected once the previous key is removed"
  );

  // The token signed by the (still current) new key must keep working.
  assert.equal(
    await checkProtected(instance2.baseUrl, tokenSignedByB),
    200,
    "a token signed by the still-current key must keep verifying after the old key is retired"
  );
});

test("A token with an unrecognized kid is rejected even if otherwise well-formed", async () => {
  const keyA = generateKeyPair();
  writeCurrent(tmpKeysDir, keyA, "key-a");
  removePrevious(tmpKeysDir);
  const instance = freshServerInstance();

  const unknownKeyPair = generateKeyPair();
  const strangerToken = jwt.sign({ sub: 1, username: "demo" }, unknownKeyPair.privateKey, {
    algorithm: "RS256",
    expiresIn: "1h",
    keyid: "some-key-nobody-mounted",
  });

  assert.equal(await checkProtected(instance.baseUrl, strangerToken), 403);
});
