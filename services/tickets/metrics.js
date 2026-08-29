"use strict";

// Lightweight Prometheus instrumentation, shared shape across all four
// services (each service is still fully self-contained per the existing
// architecture — this file is duplicated per service rather than shared
// via a package, matching how Dockerfile/.dockerignore are already handled).
const client = require("prom-client");

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests received",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

// Records one observation per finished response. Uses req.route.path when
// Express has matched a route (so /events/1 and /events/2 both count as the
// /events/:id route, not as separate high-cardinality label values), falling
// back to req.path for unmatched routes (e.g. 404s).
function metricsMiddleware(req, res, next) {
  const stopTimer = httpRequestDuration.startTimer();
  res.on("finish", () => {
    const route = (req.route && req.route.path) || req.path || "unknown";
    const labels = { method: req.method, route, status_code: res.statusCode };
    httpRequestsTotal.inc(labels);
    stopTimer(labels);
  });
  next();
}

module.exports = { register, metricsMiddleware };
