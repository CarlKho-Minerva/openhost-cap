// Owner sign-in probe: through Caddy (adds the proxy secret) must yield a session;
// straight to Next (no secret) must not. Cookies handled by hand because NextAuth
// marks them Secure and the probe speaks plain HTTP inside the container.
const host = process.env.CAP_PUBLIC_HOST;
async function probe(target, extra = {}) {
  const jar = new Map();
  const keep = (res) => {
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [kv] = c.split(";"); const i = kv.indexOf("=");
      jar.set(kv.slice(0, i), kv.slice(i + 1));
    }
  };
  const cookie = () => [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
  const base = { Host: host, "x-forwarded-proto": "https" };
  const r1 = await fetch(`http://${target}/api/auth/csrf`, { headers: base });
  keep(r1);
  const { csrfToken } = await r1.json();
  const r2 = await fetch(`http://${target}/api/auth/callback/trusted-proxy`, {
    method: "POST", redirect: "manual",
    headers: { ...base, ...extra, "x-openhost-is-owner": "true", cookie: cookie(),
      "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ csrfToken, json: "true" }),
  });
  keep(r2);
  const session = [...jar.keys()].some((k) => k.includes("session-token"));
  const loc = r2.headers.get("location") || "";
  return `${r2.status} session=${session} ${loc.replace(/^https?:\/\/[^/]+/, "")}`;
}
(async () => {
  console.log("via caddy :8080           ", await probe("127.0.0.1:8080"));
  console.log("direct next :3000, no secret", await probe("127.0.0.1:3000"));
  console.log("direct next :3000, forged  ", await probe("127.0.0.1:3000", { "x-trusted-proxy-secret": "forged" }));
})().catch((e) => { console.error("probe failed:", e); process.exit(1); });
