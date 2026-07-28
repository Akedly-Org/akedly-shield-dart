# AGENTS.md — akedly-shield-dart

Flutter/Dart client SDK for Akedly's **V1.2 secure REST API**. Three independent pieces under
`lib/src/`, re-exported from `lib/akedly_shield.dart`:

| File | What it does |
|---|---|
| `solver.dart` | Proof-of-work solver — finds a nonce whose `sha256(challenge + ":" + nonce)` has N leading zeros |
| `turnstile.dart` | Cloudflare Turnstile helper |
| `passkey.dart` | Hosted V1.2 passkey ceremony at `auth.akedly.io/pk` |

Backend lives in a separate repo (`Akedly`). This SDK never talks to Akedly directly on the
customer's behalf — the customer's own backend proxies, holding the API key.

## Build and test

```bash
dart test          # test/
dart analyze
```

There is **no CI in this repo**. Never claim a build or test run you did not actually see succeed.

## Conventions

- No code comments **except** doc comments (`///`). This is a public SDK — the doc comment on every
  public symbol is the contract customers read, so it is load-bearing. Change behaviour and you
  change the doc comment in the same edit. Inline `//` comments exist only to explain a non-obvious
  *why* — match that bar or omit.
- Results are immutable `const` constructors. Keep them const-constructible.
- Parsers are fed hostile external input (a callback URL). They must **never** throw — return a
  failed result instead. There are already five separate `catch` sites returning
  `reason: 'failed'`; that repetition is deliberate, not sloppiness.

## The browser requirement (non-negotiable, all platforms)

The ceremony runs via **`flutter_web_auth_2`**, which delegates to the right native surface on each
platform: **`ASWebAuthenticationSession` on iOS, a Chrome Custom Tab on Android**. Never run the
ceremony in a `WebView` — platform passkeys will not work there. The sibling SDKs are bound by the
same rule directly (`akedly-shield-swift` uses `ASWebAuthenticationSession`; `akedly-shield-kotlin`
must use Custom Tabs).

## The cross-SDK contract (identical in kotlin / swift / js — do not diverge)

1. **A verified result MUST carry a `resultToken`** (`passkey.dart:138`). A claimed-verified callback
   with no token is reported `verified: false`, `reason: 'no_proof'` — never as a trusted success.
   **Fail closed. This is the whole security property of the relayed result**, since the callback
   arrives over a custom scheme that cannot be trusted on its own.
2. **The relayed signal is not authoritative.** The customer confirms a sign-in by sending
   `resultToken` to their own backend, which verifies it **offline** by recomputing an HMAC with
   their Akedly API key. No polling, no server-to-server callback needed.
3. **`reason` vocabulary:** `null` when verified, else `'closed'` (user dismissed — `flutter_web_auth_2`
   throws code `CANCELED`), `'start_failed'`, `'no_proof'`, `'failed'` (unparseable callback), or a
   server `code`.

## Decided items

- **`ineligible` — ✅ FIXED 2026-07-28.** `lib/src/passkey.dart:24` documented a `"reason"` value that
  **nothing in this repo, any sibling SDK, or the backend could ever emit** (verified: it appeared
  nowhere else in kotlin, swift, the JS SDK, or the backend). It has been removed from the doc comment.
  Do not reintroduce it, and do not add code to produce it — the value has no meaning in the ceremony
  contract.
- **`flutter_web_auth_2: ^3.0.0` stays pinned — ✅ DEFERRED 2026-07-28 (OI-H).** 5.x supersedes it, but
  the upgrade changes the very component that owns the browser handoff, the user-cancel signal, and the
  callback capture — the three things this SDK cannot verify without **real-device QA on both iOS and
  Android**, which is not available here. A blind bump would trade a known-working integration for an
  unverified one on the exact path that matters most. Leave the pin alone until someone can run that QA.
  **Do not bump it because a tool flags the version as outdated** — that is the whole reason this note
  exists.

## Gotchas

- `flutter_web_auth_2` throws a `PlatformException` with code `CANCELED` on user dismissal; any other
  code is an integration failure. `passkey.dart:86-91` makes exactly that distinction — an
  integration bug must never be reported as "the user changed their mind". Preserve it.
- The ceremony origin is injectable so tests and QA can point at a local Auth-Gateway rather than
  production. Keep it injectable.
