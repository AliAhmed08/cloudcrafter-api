const express = require("express");
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

// Demo ticket store — in-memory, intentionally simple for the capstone starter.
let TICKETS = [];
let nextId = 1;

app.get("/health", (_req, res) => res.json({ status: "ok", service: "tickets" }));

app.get("/tickets", (_req, res) => res.json(TICKETS));

// Books a ticket for an event and returns a receipt.
// The receipt payload is what Task 1 Part B (serverless notification) simulates uploading to S3.
app.post("/tickets", (req, res) => {
  const { eventId, userId } = req.body || {};
  if (!eventId || !userId) {
    return res.status(400).json({ error: "eventId and userId are required" });
  }
  const ticket = {
    id: nextId++,
    eventId,
    userId,
    issuedAt: new Date().toISOString(),
    receiptId: `receipt-${Date.now()}`
  };
  TICKETS.push(ticket);
  res.status(201).json(ticket);
});

app.listen(PORT, () => console.log(`Tickets service listening on port ${PORT}`));
