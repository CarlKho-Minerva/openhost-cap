#!/usr/bin/env node
// Tiny dependency-free S3 round trip against the bundled MinIO: PUT, GET (byte
// compare), DELETE of one ~40-byte object in the real `cap` bucket.
//
// Why this exists: on 2026-09-15 the container's bind of the JuiceFS archive went
// stale ("Transport endpoint is not connected"). MinIO stayed up and kept answering
// /minio/health/live with 200 while every real upload got a 503, and the old
// static /_healthz stayed green for about six days. A liveness ping cannot see
// that. A write that actually has to reach the archive can.
//
// Signs SigV4 by hand with node's builtin crypto so there is nothing to install
// and nothing that can rot. Exits 0 on success, 1 with a one-line reason on stderr.
//
// Env: CAP_AWS_ACCESS_KEY, CAP_AWS_SECRET_KEY, CAP_AWS_BUCKET, CAP_AWS_REGION,
//      S3_INTERNAL_ENDPOINT (all already exported by entrypoint.sh).

const crypto = require("node:crypto");

const ENDPOINT = process.env.S3_INTERNAL_ENDPOINT || "http://127.0.0.1:9000";
const BUCKET = process.env.CAP_AWS_BUCKET || "cap";
const REGION = process.env.CAP_AWS_REGION || "us-east-1";
const AK = process.env.CAP_AWS_ACCESS_KEY || "";
const SK = process.env.CAP_AWS_SECRET_KEY || "";
const TIMEOUT_MS = Number(process.env.CAP_HEALTH_S3_TIMEOUT_MS || 8000);

const KEY = `.openhost-healthz/probe-${process.pid}`;
const BODY = `openhost-cap healthz ${new Date().toISOString()}`;

const sha256hex = (s) => crypto.createHash("sha256").update(s).digest("hex");
const hmac = (k, s) => crypto.createHmac("sha256", k).update(s).digest();

function sign(method, path, payload, host) {
	const now = new Date();
	const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
	const dateStamp = amzDate.slice(0, 8);
	const payloadHash = sha256hex(payload);

	const canonicalHeaders =
		`host:${host}\n` +
		`x-amz-content-sha256:${payloadHash}\n` +
		`x-amz-date:${amzDate}\n`;
	const signedHeaders = "host;x-amz-content-sha256;x-amz-date";
	const canonicalRequest = [
		method,
		path,
		"",
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	].join("\n");

	const scope = `${dateStamp}/${REGION}/s3/aws4_request`;
	const stringToSign = [
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256hex(canonicalRequest),
	].join("\n");

	let k = hmac(`AWS4${SK}`, dateStamp);
	k = hmac(k, REGION);
	k = hmac(k, "s3");
	k = hmac(k, "aws4_request");
	const signature = hmac(k, stringToSign).toString("hex");

	return {
		Authorization:
			`AWS4-HMAC-SHA256 Credential=${AK}/${scope}, ` +
			`SignedHeaders=${signedHeaders}, Signature=${signature}`,
		"x-amz-content-sha256": payloadHash,
		"x-amz-date": amzDate,
	};
}

// Each request gets its own hard timeout, so a hung MinIO fails the check
// instead of wedging the health loop forever.
async function call(method, payload) {
	const url = new URL(`${ENDPOINT}/${BUCKET}/${KEY}`);
	// Path-style bucket addressing; the path is already free of characters that
	// would need extra URI-encoding for the canonical request.
	const headers = sign(method, url.pathname, payload ?? "", url.host);
	const res = await fetch(url, {
		method,
		headers,
		body: method === "PUT" ? payload : undefined,
		signal: AbortSignal.timeout(TIMEOUT_MS),
	});
	return res;
}

async function main() {
	if (!AK || !SK) {
		throw new Error("CAP_AWS_ACCESS_KEY/CAP_AWS_SECRET_KEY not set");
	}

	const put = await call("PUT", BODY);
	if (!put.ok) throw new Error(`PUT ${put.status}`);

	const get = await call("GET", "");
	if (!get.ok) throw new Error(`GET ${get.status}`);
	const back = await get.text();
	if (back !== BODY) throw new Error("GET returned different bytes than PUT");

	const del = await call("DELETE", "");
	// MinIO answers 204 for a delete; treat any 2xx as done.
	if (!del.ok) throw new Error(`DELETE ${del.status}`);
}

main()
	.then(() => process.exit(0))
	.catch(async (e) => {
		// Best effort: never leave a probe object behind if a later step failed.
		try {
			await call("DELETE", "");
		} catch {
			/* ignore */
		}
		process.stderr.write(`s3 round trip failed: ${e && e.message ? e.message : e}\n`);
		process.exit(1);
	});
