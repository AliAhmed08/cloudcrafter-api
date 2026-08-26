const express = require("express");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const app = express();
app.use(express.json());

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

// Uploads the receipt JSON to S3. Only called when `s3` is configured
// (S3_ENDPOINT set) — see the S3_ENDPOINT opt-out handling in POST /tickets.
async function uploadReceiptToS3(ticket) {
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

// Books a ticket for an event, uploads its receipt to S3, and returns it.
// The S3 upload is what drives the rest of the event chain
// (S3 -> Lambda -> Notifications) — Tickets does not call Notifications directly.
//
// Reliability: when S3_ENDPOINT is configured (the normal Task 1 in-cluster
// setup — see k8s/tickets-deployment.yaml), a successful receipt upload is
// REQUIRED for a ticket to be considered created. This is deterministic on
// purpose: the whole point of Task 1 is proving that ticket creation always
// produces a notification via the event chain, so "ticket created but the
// event that was supposed to follow silently didn't happen" is treated as a
// failure, not a partial success. If the upload fails, the ticket is not
// added to the in-memory store and the request returns 502.
//
// When S3_ENDPOINT is NOT set at all, this is an explicit opt-out for local,
// non-LocalStack development (e.g. quickly poking at the Tickets API without
// standing up the whole event pipeline) — in that mode only, ticket creation
// still succeeds and reports s3.uploaded=false.
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

  if (!s3) {
    console.warn("S3_ENDPOINT not set — creating ticket without the event flow (local dev opt-out).");
    TICKETS.push(ticket);
    return res.status(201).json({ ...ticket, s3: { uploaded: false, reason: "S3_ENDPOINT not configured" } });
  }

  let s3Result;
  try {
    s3Result = await uploadReceiptToS3(ticket);
  } catch (err) {
    console.error("Failed to upload receipt to S3 — ticket NOT created:", err.message);
    return res.status(502).json({
      error: "Failed to upload ticket receipt to S3; ticket was not created.",
      details: err.message
    });
  }

  TICKETS.push(ticket);
  res.status(201).json({ ...ticket, s3: s3Result });
});

app.listen(PORT, () => console.log(`Tickets service listening on port ${PORT}`));
