const express = require("express");
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

// Demo event store — in-memory, intentionally simple for the capstone starter.
let EVENTS = [
  { id: 1, name: "CloudCrafter Launch Night", date: "2026-09-12", venue: "Cairo Opera House" },
  { id: 2, name: "DevOps Summit", date: "2026-10-03", venue: "New Capital Conference Center" }
];
let nextId = 3;

app.get("/health", (_req, res) => res.json({ status: "ok", service: "events" }));

app.get("/events", (_req, res) => res.json(EVENTS));

app.get("/events/:id", (req, res) => {
  const event = EVENTS.find(e => e.id === Number(req.params.id));
  if (!event) return res.status(404).json({ error: "event not found" });
  res.json(event);
});

app.post("/events", (req, res) => {
  const { name, date, venue } = req.body || {};
  if (!name || !date || !venue) {
    return res.status(400).json({ error: "name, date, and venue are required" });
  }
  const event = { id: nextId++, name, date, venue };
  EVENTS.push(event);
  res.status(201).json(event);
});

app.listen(PORT, () => console.log(`Events service listening on port ${PORT}`));
