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
  assert.equal(body.service, "events");
});

test("GET /events returns the seeded events", async () => {
  const res = await fetch(`${baseUrl}/events`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(Array.isArray(body));
  assert.ok(body.length >= 2);
  assert.ok(body.every((e) => "id" in e && "name" in e && "date" in e && "venue" in e));
});

test("GET /events/:id returns a single existing event", async () => {
  const res = await fetch(`${baseUrl}/events/1`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.id, 1);
});

test("GET /events/:id with an unknown id returns 404", async () => {
  const res = await fetch(`${baseUrl}/events/999999`);
  assert.equal(res.status, 404);
});

test("POST /events creates a new event and it becomes retrievable", async () => {
  const newEvent = { name: "Test Conference", date: "2027-01-01", venue: "Test Hall" };
  const createRes = await fetch(`${baseUrl}/events`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(newEvent),
  });
  assert.equal(createRes.status, 201);
  const created = await createRes.json();
  assert.equal(created.name, newEvent.name);
  assert.equal(typeof created.id, "number");

  const getRes = await fetch(`${baseUrl}/events/${created.id}`);
  assert.equal(getRes.status, 200);
  const fetched = await getRes.json();
  assert.deepEqual(fetched, created);
});

test("POST /events with missing fields returns 400", async () => {
  const res = await fetch(`${baseUrl}/events`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "Incomplete Event" }),
  });
  assert.equal(res.status, 400);
});
