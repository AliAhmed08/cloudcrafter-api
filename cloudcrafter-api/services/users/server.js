const express = require("express");
const jwt = require("jsonwebtoken");
const fs = require("fs");
const path = require("path");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

// In Kubernetes, JWT_KEYS_DIR points at a mounted Secret volume (see k8s/users-deployment.yaml).
// For local (non-container) development without a cluster, it falls back to a directory
// named by JWT_KEYS_DIR or, failing that, to ./keys (which is gitignored — see .gitignore).
// The keys are never read from a path inside the committed source tree.
const KEYS_DIR = process.env.JWT_KEYS_DIR || path.join(__dirname, "keys");

function readKey(fileName) {
  const keyPath = path.join(KEYS_DIR, fileName);
  try {
    return fs.readFileSync(keyPath, "utf8");
  } catch (err) {
    throw new Error(
      `Unable to read ${fileName} from ${KEYS_DIR}. Set JWT_KEYS_DIR to a directory containing ` +
      `private.key and public.key (mounted from a Kubernetes Secret in-cluster, or a local ` +
      `gitignored directory for standalone dev). Original error: ${err.message}`
    );
  }
}

const PRIVATE_KEY = readKey("private.key");
const PUBLIC_KEY = readKey("public.key");

// Demo user store — CloudCrafter is a learning project, this is intentionally in-memory.
const USERS = [
  { id: 1, username: "demo", password: "demo123", name: "Demo User" }
];

app.get("/health", (_req, res) => res.json({ status: "ok", service: "users" }));

app.get("/users", (_req, res) => {
  res.json(USERS.map(({ id, username, name }) => ({ id, username, name })));
});

// Issues a JWT signed with the current private key
app.post("/login", (req, res) => {
  const { username, password } = req.body || {};
  const user = USERS.find(u => u.username === username && u.password === password);
  if (!user) return res.status(401).json({ error: "invalid credentials" });

  const token = jwt.sign(
    { sub: user.id, username: user.username },
    PRIVATE_KEY,
    { algorithm: "RS256", expiresIn: "1h" }
  );
  res.json({ token });
});

// Verifies a JWT against the current public key — used to prove key rotation worked
app.get("/protected", (req, res) => {
  const authHeader = req.headers.authorization || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
  if (!token) return res.status(401).json({ error: "missing token" });

  try {
    const payload = jwt.verify(token, PUBLIC_KEY, { algorithms: ["RS256"] });
    res.json({ message: "access granted", user: payload });
  } catch (err) {
    res.status(403).json({ error: "invalid or expired token", details: err.message });
  }
});

app.listen(PORT, () => console.log(`Users service listening on port ${PORT}`));
