"use strict";

/**
 * CloudCrafter Task 1 Lambda: notify-on-receipt
 *
 * Trigger: S3 ObjectCreated event on the ticket-receipts bucket
 * (see localstack/deploy-lambda.sh for the S3 -> Lambda event source wiring).
 *
 * Flow:
 *   1. Receive the S3 event (one or more records).
 *   2. For each record, fetch the receipt JSON object from S3.
 *   3. Extract ticket/receipt info from the object body.
 *   4. POST to the Notifications service's /notify endpoint.
 *
 * Configuration (environment variables, set at Lambda creation time by
 * deploy-lambda.sh — never hardcoded):
 *   NOTIFICATIONS_URL - full base URL of the notifications Service,
 *                        e.g. http://host.minikube.internal:PORT or a NodePort URL.
 *   AWS_ENDPOINT_URL  - LocalStack edge endpoint, injected automatically by
 *                        LocalStack's Lambda runtime; falls back to
 *                        http://localhost:4566 for safety.
 */

const https = require("http"); // notifications runs over plain HTTP inside the cluster
const { S3Client, GetObjectCommand } = require("@aws-sdk/client-s3");

const NOTIFICATIONS_URL = process.env.NOTIFICATIONS_URL;
const S3_ENDPOINT = process.env.AWS_ENDPOINT_URL || "http://localhost:4566";

const s3 = new S3Client({
  region: process.env.AWS_REGION || "us-east-1",
  endpoint: S3_ENDPOINT,
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID || "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || "test",
  },
});

function streamToString(stream) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    stream.on("data", (chunk) => chunks.push(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

function postNotification(payload) {
  return new Promise((resolve, reject) => {
    if (!NOTIFICATIONS_URL) {
      return reject(new Error("NOTIFICATIONS_URL environment variable is not set"));
    }
    const url = new URL("/notify", NOTIFICATIONS_URL);
    const body = JSON.stringify(payload);

    const req = https.request(
      {
        hostname: url.hostname,
        port: url.port || 80,
        path: url.pathname,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(JSON.parse(data));
          } else {
            reject(new Error(`Notifications service returned ${res.statusCode}: ${data}`));
          }
        });
      }
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

exports.handler = async (event) => {
  const results = [];

  for (const record of event.Records || []) {
    const bucket = record.s3.bucket.name;
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    console.log(`Processing S3 object s3://${bucket}/${key}`);

    const getCmd = new GetObjectCommand({ Bucket: bucket, Key: key });
    const s3Object = await s3.send(getCmd);
    const bodyText = await streamToString(s3Object.Body);
    const receipt = JSON.parse(bodyText);

    const notificationPayload = {
      userId: receipt.userId,
      message:
        `Your ticket receipt ${receipt.receiptId} for event ${receipt.eventId} ` +
        `has been generated (ticket #${receipt.id}, issued ${receipt.issuedAt}).`,
    };

    const result = await postNotification(notificationPayload);
    console.log("Notification created:", result);
    results.push(result);
  }

  return { statusCode: 200, processed: results.length, results };
};
