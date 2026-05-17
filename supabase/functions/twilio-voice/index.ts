// =========================================================================
// Crocs & Clicks CRM — Twilio Voice edge function
// One Supabase Edge Function with path-based routing for every Twilio
// webhook + the browser-side token endpoint.
//
// Routes (all under /functions/v1/twilio-voice):
//   POST /token                   -> Twilio Voice access token for the browser
//   POST /voice                   -> TwiML for outbound (set on TwiML App)
//   POST /inbound                 -> TwiML for inbound  (set on each of the 3 numbers)
//   POST /status                  -> Call status callback
//   POST /recording-complete      -> Voicemail recording finished
//   POST /transcription-complete  -> Voicemail transcription finished
//
// Env vars (set via `supabase secrets set` — NEVER hardcode):
//   TWILIO_ACCOUNT_SID
//   TWILIO_AUTH_TOKEN              (for webhook signature verification)
//   TWILIO_API_KEY_SID
//   TWILIO_API_KEY_SECRET
//   TWILIO_TWIML_APP_SID
//   TWILIO_NUMBERS                 (comma-separated E.164, exactly 3)
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//   RESEND_API_KEY
//   EMAIL_FROM                     (e.g. "Crocs & Clicks CRM <notifications@crocsandclicks.com>")
//   EMAIL_FALLBACK_TO              (e.g. "ben@crocsandclicks.com")
//   PUBLIC_FUNCTION_URL            (the deployed function URL, used for TwiML action attrs)
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---- env -----------------------------------------------------------------
const env = (k: string, required = true): string => {
  const v = Deno.env.get(k);
  if (required && !v) throw new Error(`Missing env var: ${k}`);
  return v ?? "";
};

const ACCOUNT_SID  = env("TWILIO_ACCOUNT_SID");
const AUTH_TOKEN   = env("TWILIO_AUTH_TOKEN");
const API_KEY_SID  = env("TWILIO_API_KEY_SID");
const API_KEY_SEC  = env("TWILIO_API_KEY_SECRET");
const APP_SID      = env("TWILIO_TWIML_APP_SID");
const NUMBERS      = env("TWILIO_NUMBERS").split(",").map(s => s.trim()).filter(Boolean);
const SUPA_URL     = env("SUPABASE_URL");
const SERVICE_KEY  = env("SUPABASE_SERVICE_ROLE_KEY");
const RESEND_KEY   = env("RESEND_API_KEY");
const EMAIL_FROM   = env("EMAIL_FROM");
const EMAIL_FALLBACK_TO = env("EMAIL_FALLBACK_TO");
const PUBLIC_URL   = env("PUBLIC_FUNCTION_URL");

if (NUMBERS.length !== 3) {
  console.warn(`TWILIO_NUMBERS should contain exactly 3 numbers; got ${NUMBERS.length}`);
}

const admin = createClient(SUPA_URL, SERVICE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// ---- helpers -------------------------------------------------------------
const te = new TextEncoder();
const td = new TextDecoder();

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function hmacSha256(key: string, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", te.encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, te.encode(data));
  return new Uint8Array(sig);
}

async function hmacSha1Base64(key: string, data: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", te.encode(key),
    { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, te.encode(data));
  let s = "";
  for (const b of new Uint8Array(sig)) s += String.fromCharCode(b);
  return btoa(s);
}

function digitsOnly(s: string | null | undefined): string {
  return (s || "").replace(/\D/g, "");
}

function toE164US(raw: string | null | undefined): string | null {
  const d = digitsOnly(raw);
  if (!d) return null;
  if (d.length === 11 && d.startsWith("1")) return "+" + d;
  if (d.length === 10) return "+1" + d;
  if (raw && raw.startsWith("+")) return raw;
  return null;
}

function xmlEscape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
          .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

function corsHeaders(): HeadersInit {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
}

function xmlResponse(body: string, status = 200): Response {
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>${body}`, {
    status,
    headers: { "content-type": "text/xml" },
  });
}

// ---- Twilio webhook signature verification -------------------------------
// https://www.twilio.com/docs/usage/security#validating-requests
async function verifyTwilioSignature(req: Request, params: URLSearchParams): Promise<boolean> {
  const sig = req.headers.get("x-twilio-signature");
  if (!sig) return false;
  const url = req.url;
  const sortedKeys = [...params.keys()].sort();
  let payload = url;
  for (const k of sortedKeys) payload += k + params.get(k);
  const expected = await hmacSha1Base64(AUTH_TOKEN, payload);
  return expected === sig;
}

async function readForm(req: Request): Promise<URLSearchParams> {
  const text = await req.text();
  return new URLSearchParams(text);
}

// ---- Twilio Voice access token (JWT) -------------------------------------
async function issueAccessToken(identity: string, ttlSec = 3600): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "HS256", typ: "JWT", cty: "twilio-fpa;v=1" };
  const payload = {
    jti: `${API_KEY_SID}-${now}`,
    iss: API_KEY_SID,
    sub: ACCOUNT_SID,
    iat: now,
    exp: now + ttlSec,
    grants: {
      identity,
      voice: {
        incoming: { allow: true },
        outgoing: { application_sid: APP_SID },
      },
    },
  };
  const headerB64 = b64url(te.encode(JSON.stringify(header)));
  const payloadB64 = b64url(te.encode(JSON.stringify(payload)));
  const signingInput = `${headerB64}.${payloadB64}`;
  const sig = await hmacSha256(API_KEY_SEC, signingInput);
  return `${signingInput}.${b64url(sig)}`;
}

// ---- caller-ID assignment -----------------------------------------------
async function getOrAssignCallerId(accountId: string | null): Promise<string> {
  if (!accountId) return NUMBERS[0];

  const { data: acct } = await admin
    .from("accounts").select("caller_id_number").eq("id", accountId).single();
  if (acct?.caller_id_number) return acct.caller_id_number;

  // Atomically advance the rotation counter.
  const { data: idx, error: rpcErr } = await admin.rpc("next_caller_id_index");
  if (rpcErr || idx === null) {
    console.error("next_caller_id_index RPC failed", rpcErr);
    return NUMBERS[0];
  }
  const number = NUMBERS[Number(idx) % NUMBERS.length];

  await admin.from("accounts").update({ caller_id_number: number }).eq("id", accountId);
  return number;
}

async function lookupAccountByPhone(e164: string): Promise<{ accountId: string | null; contactId: string | null; ownerEmail: string | null }> {
  const last10 = digitsOnly(e164).slice(-10);
  if (!last10) return { accountId: null, contactId: null, ownerEmail: null };

  // Try contacts first (phone or mobile match).
  const { data: contact } = await admin
    .from("contacts")
    .select("id, account_id")
    .or(`phone.ilike.%${last10},mobile.ilike.%${last10}`)
    .limit(1).maybeSingle();

  let accountId: string | null = contact?.account_id ?? null;
  const contactId: string | null = contact?.id ?? null;

  // Fall back to accounts.phone.
  if (!accountId) {
    const { data: acct } = await admin
      .from("accounts").select("id").ilike("phone", `%${last10}%`).limit(1).maybeSingle();
    accountId = acct?.id ?? null;
  }

  let ownerEmail: string | null = null;
  if (accountId) {
    const { data: row } = await admin
      .from("accounts")
      .select("owner:profiles!accounts_owner_id_fkey(id)")
      .eq("id", accountId).single();
    const ownerId = (row as any)?.owner?.id;
    if (ownerId) {
      // profiles doesn't store email directly — read from auth.users.
      const { data: u } = await admin.auth.admin.getUserById(ownerId);
      ownerEmail = u?.user?.email ?? null;
    }
  }

  return { accountId, contactId, ownerEmail };
}

// ---- Resend email --------------------------------------------------------
async function sendEmail(to: string, subject: string, html: string): Promise<void> {
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from: EMAIL_FROM, to: [to], subject, html }),
    });
    if (!res.ok) {
      console.error("Resend send failed", res.status, await res.text());
    }
  } catch (e) {
    console.error("Resend send error", e);
  }
}

// ---- status mapping ------------------------------------------------------
function mapTwilioStatus(s: string | null): string | null {
  if (!s) return null;
  const v = s.toLowerCase().replace(/-/g, "_");
  const allowed = new Set([
    "queued", "ringing", "in_progress", "completed",
    "no_answer", "busy", "failed", "voicemail", "canceled",
  ]);
  return allowed.has(v) ? v : null;
}

// =========================================================================
// ROUTE HANDLERS
// =========================================================================

// POST /token — browser asks for a Voice access token. Authed via supabase JWT.
async function handleToken(req: Request): Promise<Response> {
  const authHeader = req.headers.get("authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return jsonResponse({ error: "Missing auth" }, 401);

  const { data: { user }, error } = await admin.auth.getUser(jwt);
  if (error || !user) return jsonResponse({ error: "Invalid auth" }, 401);

  const token = await issueAccessToken(user.id);
  return jsonResponse({ token, identity: user.id, ttl: 3600 });
}

// POST /voice — TwiML for outbound. Twilio calls this after Device.connect().
// Browser passes customParams: To, accountId, contactId, userId.
async function handleVoice(req: Request): Promise<Response> {
  const params = await readForm(req);
  if (!(await verifyTwilioSignature(req, params))) {
    return xmlResponse(`<Response><Reject/></Response>`, 403);
  }
  const to = toE164US(params.get("To"));
  const accountId = params.get("accountId") || null;
  const contactId = params.get("contactId") || null;
  const userId    = params.get("userId")    || null;
  const callSid   = params.get("CallSid")   || null;

  if (!to) {
    return xmlResponse(`<Response><Say>Missing destination.</Say><Hangup/></Response>`);
  }

  const callerId = await getOrAssignCallerId(accountId);

  if (callSid) {
    await admin.from("calls").insert({
      twilio_call_sid: callSid,
      account_id: accountId,
      contact_id: contactId,
      user_id: userId,
      direction: "outbound",
      from_number: callerId,
      to_number: to,
      status: "queued",
    });
  }

  const statusUrl = `${PUBLIC_URL}/status`;
  const twiml = `<Response>
    <Dial callerId="${xmlEscape(callerId)}" answerOnBridge="true">
      <Number statusCallback="${xmlEscape(statusUrl)}" statusCallbackEvent="initiated ringing answered completed" statusCallbackMethod="POST">${xmlEscape(to)}</Number>
    </Dial>
  </Response>`;
  return xmlResponse(twiml);
}

// POST /inbound — TwiML for inbound. Plays greeting, records voicemail.
async function handleInbound(req: Request): Promise<Response> {
  const params = await readForm(req);
  if (!(await verifyTwilioSignature(req, params))) {
    return xmlResponse(`<Response><Reject/></Response>`, 403);
  }
  const from = toE164US(params.get("From"));
  const to   = toE164US(params.get("To"));
  const callSid = params.get("CallSid");

  if (callSid && from && to) {
    const { accountId, contactId } = await lookupAccountByPhone(from);
    await admin.from("calls").insert({
      twilio_call_sid: callSid,
      account_id: accountId,
      contact_id: contactId,
      user_id: null,
      direction: "inbound",
      from_number: from,
      to_number: to,
      status: "ringing",
    });
  }

  const recAction      = `${PUBLIC_URL}/recording-complete`;
  const transcribeCb   = `${PUBLIC_URL}/transcription-complete`;
  const twiml = `<Response>
    <Say voice="alice">Thanks for calling Crocs and Clicks. Please leave a message after the tone, and we will get back to you shortly.</Say>
    <Record action="${xmlEscape(recAction)}" method="POST" maxLength="180" timeout="5" playBeep="true" trim="trim-silence" transcribe="true" transcribeCallback="${xmlEscape(transcribeCb)}"/>
    <Say>We did not receive a recording. Goodbye.</Say>
    <Hangup/>
  </Response>`;
  return xmlResponse(twiml);
}

// POST /status — generic status callback for outbound + inbound legs.
async function handleStatus(req: Request): Promise<Response> {
  const params = await readForm(req);
  if (!(await verifyTwilioSignature(req, params))) {
    return new Response("forbidden", { status: 403 });
  }
  const callSid = params.get("CallSid");
  if (!callSid) return new Response("ok");

  const status   = mapTwilioStatus(params.get("CallStatus"));
  const duration = parseInt(params.get("CallDuration") || "", 10);
  const patch: Record<string, unknown> = {};
  if (status) patch.status = status;
  if (!isNaN(duration)) patch.duration_seconds = duration;
  if (status === "completed" || status === "no_answer" || status === "busy" ||
      status === "failed" || status === "canceled") {
    patch.ended_at = new Date().toISOString();
  }
  if (Object.keys(patch).length) {
    await admin.from("calls").update(patch).eq("twilio_call_sid", callSid);
  }
  return new Response("ok");
}

// POST /recording-complete — voicemail audio is ready. Update row + send email.
async function handleRecordingComplete(req: Request): Promise<Response> {
  const params = await readForm(req);
  if (!(await verifyTwilioSignature(req, params))) {
    return new Response("forbidden", { status: 403 });
  }
  const callSid     = params.get("CallSid");
  const recUrl      = params.get("RecordingUrl");
  const recDuration = parseInt(params.get("RecordingDuration") || "", 10);
  const from        = toE164US(params.get("From"));

  if (!callSid) return new Response("ok");

  const playableUrl = recUrl ? `${recUrl}.mp3` : null;
  const patch: Record<string, unknown> = {
    status: "voicemail",
    voicemail_url: playableUrl,
    ended_at: new Date().toISOString(),
  };
  if (!isNaN(recDuration)) patch.voicemail_duration_seconds = recDuration;

  const { data: row } = await admin.from("calls")
    .update(patch).eq("twilio_call_sid", callSid)
    .select("id, account_id, from_number").single();

  // Resolve recipient email.
  let recipient = EMAIL_FALLBACK_TO;
  let accountName: string | null = null;
  if (row?.account_id) {
    const { data: acct } = await admin.from("accounts")
      .select("name, owner_id").eq("id", row.account_id).single();
    accountName = acct?.name ?? null;
    if (acct?.owner_id) {
      const { data: u } = await admin.auth.admin.getUserById(acct.owner_id);
      if (u?.user?.email) recipient = u.user.email;
    }
  }

  const subject = accountName
    ? `New voicemail from ${accountName} (${from || "unknown"})`
    : `New voicemail from unknown caller (${from || "unknown"})`;
  const html = `
    <p>You have a new voicemail.</p>
    <ul>
      <li><b>From:</b> ${xmlEscape(from || "unknown")}</li>
      ${accountName ? `<li><b>Account:</b> ${xmlEscape(accountName)}</li>` : ""}
      ${!isNaN(recDuration) ? `<li><b>Duration:</b> ${recDuration}s</li>` : ""}
    </ul>
    ${playableUrl ? `<p><a href="${xmlEscape(playableUrl)}">Listen to voicemail</a></p>` : ""}
    <p>Transcription will be sent in a follow-up email when ready.</p>
  `;
  await sendEmail(recipient, subject, html);

  return new Response("ok");
}

// POST /transcription-complete — Twilio finished transcribing the voicemail.
async function handleTranscriptionComplete(req: Request): Promise<Response> {
  const params = await readForm(req);
  if (!(await verifyTwilioSignature(req, params))) {
    return new Response("forbidden", { status: 403 });
  }
  const callSid       = params.get("CallSid");
  const transcription = params.get("TranscriptionText") || "";
  if (!callSid) return new Response("ok");

  await admin.from("calls")
    .update({ voicemail_transcription: transcription })
    .eq("twilio_call_sid", callSid);

  return new Response("ok");
}

// =========================================================================
// ENTRYPOINT
// =========================================================================
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders() });
  }

  // Supabase forwards the request with /twilio-voice/<subpath> in the path;
  // the /functions/v1 prefix is sometimes also present (e.g. local dev).
  const url = new URL(req.url);
  const path = url.pathname
    .replace(/^(\/functions\/v1)?\/twilio-voice/, "")
    .replace(/\/+$/, "") || "/";

  try {
    if (req.method === "POST" && path === "/token")                  return await handleToken(req);
    if (req.method === "POST" && path === "/voice")                  return await handleVoice(req);
    if (req.method === "POST" && path === "/inbound")                return await handleInbound(req);
    if (req.method === "POST" && path === "/status")                 return await handleStatus(req);
    if (req.method === "POST" && path === "/recording-complete")     return await handleRecordingComplete(req);
    if (req.method === "POST" && path === "/transcription-complete") return await handleTranscriptionComplete(req);

    if (req.method === "GET" && path === "/health") {
      return jsonResponse({ ok: true, numbers: NUMBERS.length });
    }
  } catch (e) {
    console.error("twilio-voice error", e);
    return jsonResponse({ error: (e as Error).message }, 500);
  }

  return jsonResponse({ error: "not found", path }, 404);
});
