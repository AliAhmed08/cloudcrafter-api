const express = require("express");
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

// Demo notification log — in-memory, intentionally simple for the capstone starter.
// In Task 1 Part B, a serverless (LocalStack) trigger simulates calling this
// service automatically whenever a ticket receipt is generated.
let NOTIFICATIONS = [];

app.get("/health", (_req, res) => res.json({ status: "ok", service: "notifications" }));

app.get("/notifications", (_req, res) => res.json(NOTIFICATIONS));

app.post("/notify", (req, res) => {
  const { message, userId } = req.body || {};
  if (!message) return res.status(400).json({ error: "message is required" });

  const notification = { id: NOTIFICATIONS.length + 1, message, userId: userId || null, sentAt: new Date().toISOString() };
  NOTIFICATIONS.push(notification);
  console.log("Notification sent:", notification);
  res.status(201).json(notification);
});

app.listen(PORT, () => console.log(`Notifications service listening on port ${PORT}`));
