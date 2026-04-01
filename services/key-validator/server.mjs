import { createServer } from "node:http";

const PORT = parseInt(process.env.PORT || "3000", 10);
const REQUIRE_CLIENT_AUTH = process.env.REQUIRE_CLIENT_AUTH === "true";

let allowedClients = [];
if (REQUIRE_CLIENT_AUTH && process.env.ALLOWED_CLIENTS) {
  try {
    allowedClients = JSON.parse(process.env.ALLOWED_CLIENTS);
  } catch {
    console.error("ALLOWED_CLIENTS is not valid JSON");
    process.exit(1);
  }
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

function validateEd25519Key(authKey) {
  if (typeof authKey !== "string") return { ok: false, reason: "auth_key must be a string" };

  const parts = authKey.trim().split(/\s+/);
  if (parts.length < 2) return { ok: false, reason: "invalid key format" };

  const keyType = parts[0];
  const keyData = parts[1];

  if (keyType !== "ssh-ed25519") {
    return { ok: false, reason: `unsupported key type: ${keyType}` };
  }

  // Validate base64 portion
  try {
    const decoded = Buffer.from(keyData, "base64");
    if (decoded.length === 0) return { ok: false, reason: "empty key data" };
  } catch {
    return { ok: false, reason: "invalid base64 in key data" };
  }

  return { ok: true, keyType };
}

const server = createServer(async (req, res) => {
  // Health check
  if (req.url === "/health" && req.method === "GET") {
    return json(res, 200, { status: "ok" });
  }

  // Key validation endpoint
  if (req.url === "/validate" && req.method === "POST") {
    // Client auth check
    if (REQUIRE_CLIENT_AUTH) {
      const clientId = req.headers["x-client-id"];
      const clientSecret = req.headers["x-client-secret"];
      const match = allowedClients.find(
        (c) => c.id === clientId && c.secret === clientSecret
      );
      if (!match) {
        return json(res, 401, { status: "denied", reason: "invalid client credentials" });
      }
    }

    let body;
    try {
      body = await parseBody(req);
    } catch {
      return json(res, 400, { status: "denied", reason: "invalid JSON body" });
    }

    const { auth_key, user, remote_addr } = body;
    const result = validateEd25519Key(auth_key);

    if (result.ok) {
      console.log(`approved: user=${user} type=${result.keyType} remote=${remote_addr}`);
      return json(res, 200, {
        status: "approved",
        user: user || "anonymous",
        key_type: result.keyType,
      });
    }

    console.log(`denied: user=${user} reason=${result.reason} remote=${remote_addr}`);
    return json(res, 403, { status: "denied", reason: result.reason });
  }

  json(res, 404, { error: "not found" });
});

server.listen(PORT, () => {
  console.log(`key-validator listening on :${PORT}`);
});
