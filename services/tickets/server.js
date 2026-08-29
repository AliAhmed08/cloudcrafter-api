const express = require("express");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { register, metricsMiddleware } = require("./metrics");
const app = express();
app.use(express.json());
app.use(metricsMiddleware);

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

const PORT = process.env.PORT || 3000;

// Demo ticket store — in-memory, intentionally simple for the capstone starter.
let TICKETS = [];
let nextId = 1;

// S3 (LocalStack) configuration — entirely driven by env vars, no hardcoded
// endpoint/bucket/credentials. See k8s/tickets-deployment.yaml for the values
// used in-cluster, and README.md for the LocalStack setup these point at.
const S3_ENDPOINT = process.env.S3_ENDPOINT; // e.g. http://host.minikube.internal:4566
const S3_BUCKET = process.env.S3_BUCKET || "cloudcrafter-ticket-receipts";
const S3_REGION = process.env.S3_REGION || "us-east-1";

const s3 = S3_ENDPOINT
  ? new S3Client({
      region: S3_REGION,
      endpoint: S3_ENDPOINT,
      forcePathStyle: true, // required for LocalStack S3
      credentials: {
        accessKeyId: process.env.AWS_ACCESS_KEY_ID || "test",
        secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || "test",
      },
    })
  : null;

// Uploads the receipt JSON to S3. This is what triggers the Lambda ->
// Notifications event chain — Tickets never calls Notifications directly.
async function uploadReceiptToS3(ticket) {
  if (!s3) {
    console.warn("S3_ENDPOINT not set — skipping receipt upload (event flow disabled).");
    return { uploaded: false };
  }
  const key = `receipts/${ticket.receiptId}.json`;
  await s3.send(
    new PutObjectCommand({
      Bucket: S3_BUCKET,
      Key: key,
      Body: JSON.stringify(ticket),
      ContentType: "application/json",
    })
  );
  return { uploaded: true, bucket: S3_BUCKET, key };
}

app.get("/health", (_req, res) => res.json({ status: "ok", service: "tickets" }));

app.get("/tickets", (_req, res) => res.json(TICKETS));

// Books a ticket for an event, returns a receipt, and uploads the receipt to
// S3. The S3 upload is what drives the rest of the event chain
// (S3 -> Lambda -> Notifications) — Tickets does not call Notifications directly.
app.post("/tickets", async (req, res) => {
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

  let s3Result = { uploaded: false };
  try {
    s3Result = await uploadReceiptToS3(ticket);
  } catch (err) {
    // Ticket creation itself succeeded; the S3 upload is best-effort so a
    // LocalStack outage doesn't block ticket booking. Surface the failure
    // in the response so it's visible during testing.
    console.error("Failed to upload receipt to S3:", err.message);
    s3Result = { uploaded: false, error: err.message };
  }

  res.status(201).json({ ...ticket, s3: s3Result });
});

// Exported for testing (see test/tickets.test.js). Only binds a real port
// when this file is run directly, not when required by a test.
module.exports = app;
if (require.main === module) {
  app.listen(PORT, () => console.log(`Tickets service listening on port ${PORT}`));
}
