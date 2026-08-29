const express = require("express");
const jwt = require("jsonwebtoken");
const fs = require("fs");
const path = require("path");
const { register, metricsMiddleware } = require("./metrics");

const app = express();
app.use(express.json());
app.use(metricsMiddleware);

const PORT = process.env.PORT || 3000;

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

// In Kubernetes, JWT_KEYS_DIR points at a mounted Secret volume (see
// k8s/users-deployment.yaml). For local (non-container) development without
// a cluster, it falls back to a directory named by JWT_KEYS_DIR or, failing
// that, to ./keys (gitignored — see .gitignore). Keys are never read from a
// path inside the committed source tree.
//
// Key rotation support: the Secret/directory can contain up to two key
// pairs, each identified by a "kid" (key ID):
//   current-private.key, current-public.key, current-kid   (required)
//   previous-public.key, previous-kid                       (optional)
//
// New tokens are always signed with the CURRENT private key and carry its
// kid in the JWT header. /protected looks at the token's kid to decide
// which public key to verify against, so a token signed with the previous
// key remains valid for as long as previous-public.key/previous-kid stay
// mounted — see docs/jwt-key-rotation.md for the zero-downtime rollout
// procedure that adds/retires the previous slot without ever invalidating
// a not-yet-expired token mid-rotation.
const KEYS_DIR = process.env.JWT_KEYS_DIR || path.join(__dirname, "keys");

function readKey(fileName) {
  const keyPath = path.join(KEYS_DIR, fileName);
  try {
    return fs.readFileSync(keyPath, "utf8");
  } catch (err) {
    throw new Error(
      `Unable to read ${fileName} from ${KEYS_DIR}. Set JWT_KEYS_DIR to a directory containing ` +
      `current-private.key, current-public.key, and current-kid (mounted from a Kubernetes ` +
      `Secret in-cluster, or a local gitignored directory for standalone dev). ` +
      `Original error: ${err.message}`
    );
  }
}

function readKeyOptional(fileName) {
  const keyPath = path.join(KEYS_DIR, fileName);
  return fs.existsSync(keyPath) ? fs.readFileSync(keyPath, "utf8").trim() : null;
}

const PRIVATE_KEY = readKey("current-private.key");
const CURRENT_KID = (readKeyOptional("current-kid")) || "current";
const CURRENT_PUBLIC_KEY = readKey("current-public.key");

// Only present during an active rotation's grace period — see
// docs/jwt-key-rotation.md. Absent by default (fresh install / after a
// rotation is fully retired), which is the normal, non-rotating state.
const PREVIOUS_PUBLIC_KEY = readKeyOptional("previous-public.key");
const PREVIOUS_KID = PREVIOUS_PUBLIC_KEY ? (readKeyOptional("previous-kid") || "previous") : null;

function publicKeyForKid(kid) {
  // No kid (or kid === current) -> current key. This also covers tokens
  // issued before rotation support existed, which never had a kid at all.
  if (!kid || kid === CURRENT_KID) return CURRENT_PUBLIC_KEY;
  if (PREVIOUS_KID && kid === PREVIOUS_KID) return PREVIOUS_PUBLIC_KEY;
  return null;
}

// Demo user store — CloudCrafter is a learning project, this is intentionally in-memory.
const USERS = [
  { id: 1, username: "demo", password: "demo123", name: "Demo User" }
];

app.get("/health", (_req, res) => res.json({ status: "ok", service: "users" }));

app.get("/users", (_req, res) => {
  res.json(USERS.map(({ id, username, name }) => ({ id, username, name })));
});

// Issues a JWT signed with the CURRENT private key, tagged with its kid.
app.post("/login", (req, res) => {
  const { username, password } = req.body || {};
  const user = USERS.find(u => u.username === username && u.password === password);
  if (!user) return res.status(401).json({ error: "invalid credentials" });

  const token = jwt.sign(
    { sub: user.id, username: user.username },
    PRIVATE_KEY,
    { algorithm: "RS256", expiresIn: "1h", keyid: CURRENT_KID }
  );
  res.json({ token });
});

// Verifies a JWT against whichever key its kid points at (current or, during
// a rotation grace period, previous) — see docs/jwt-key-rotation.md.
app.get("/protected", (req, res) => {
  const authHeader = req.headers.authorization || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
  if (!token) return res.status(401).json({ error: "missing token" });

  let kid;
  try {
    const decoded = jwt.decode(token, { complete: true });
    kid = decoded && decoded.header && decoded.header.kid;
  } catch (_err) {
    return res.status(403).json({ error: "invalid or expired token", details: "malformed token" });
  }

  const publicKey = publicKeyForKid(kid);
  if (!publicKey) {
    return res.status(403).json({ error: "invalid or expired token", details: `unknown key id: ${kid}` });
  }

  try {
    const payload = jwt.verify(token, publicKey, { algorithms: ["RS256"] });
    res.json({ message: "access granted", user: payload });
  } catch (err) {
    res.status(403).json({ error: "invalid or expired token", details: err.message });
  }
});

// Exported for testing (see test/users.test.js), which starts its own
// ephemeral listener against this same app instance instead of duplicating
// route logic. Only binds a real port when this file is run directly
// (`npm start` / `node server.js`), not when required by a test.
module.exports = app;
if (require.main === module) {
  app.listen(PORT, () => console.log(`Users service listening on port ${PORT}`));
}
