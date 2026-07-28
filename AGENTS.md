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

## The cross-SDK contract (kotlin / swift / js)

**Clauses 1–2 are identical across all four SDKs — do not diverge.** Clause 3's `reason`
vocabulary is deliberately **per-platform** and is NOT expected to match: Swift carries seven
values, Dart five, and Kotlin two, because a Custom Tab cannot signal a user cancel at all.
Aligning them would mean inventing values a platform cannot actually produce.

**`ceremonyOrigin` must be a bare origin** — `scheme://host[:port]`, no path, no trailing slash.
The four SDKs normalize it differently (JS reduces to a true origin because it reuses the value in
the `event.origin` equality check; the natives only prefix a URL), so a path-carrying or
multi-slash value behaves differently per platform. It fails visibly — the ceremony 404s — so this
is a documented input contract, not a code divergence to "fix".

1. **A verified result MUST carry a `resultToken`** (`passkey.dart:132`). A claimed-verified callback
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

- **`ineligible` — ✅ REMOVED FROM THE DOCS 2026-07-28.** `lib/src/passkey.dart:24` documented it as a
  `"reason"` value; it is not one, and it has been removed from the doc comment. Do not reintroduce it.
  **Two things an earlier version of this note got wrong — do not re-plant them:**
  - It was **not** Dart-only. `akedly-shield-swift`'s README carried it too, and so did the JS SDK's
    docs. That false "this repo is clean" claim is why the Swift repo was nearly skipped in the sweep.
  - The SDK **can** surface it, by server-`code` passthrough (`passkey.dart:138`, asserted in
    `test/passkey_test.dart:29-32`). It is unreachable only because **no server sends that code** —
    not because the code path refuses it. "Nothing could ever emit it" was wrong on both halves.

  The real server-side set is `NO_PASSKEY`, `PASSKEY_DISABLED`, `INSUFFICIENT_QUOTA`,
  `BILLING_FAILED`, `CANCELLED`, `FAILED`.
- **`flutter_web_auth_2: ^3.0.0` stays pinned — ✅ DEFERRED 2026-07-28 (OI-H).** 5.x supersedes it, but
  the upgrade changes the very component that owns the browser handoff, the user-cancel signal, and the
  callback capture — the three things this SDK cannot verify without **real-device QA on both iOS and
  Android**, which is not available here. A blind bump would trade a known-working integration for an
  unverified one on the exact path that matters most. Leave the pin alone until someone can run that QA.
  **Do not bump it because a tool flags the version as outdated** — that is the whole reason this note
  exists.

  **What the pin costs while it stands (checked 2026-07-28):** `akedly_shield` is **not published on
  pub.dev**, so the pin blocks no customer today. But `flutter_web_auth_2` is at 5.0.3, and any app
  already depending on `>=4` cannot co-depend on this SDK — not even as a git dependency — because
  pub version-solving rejects it outright. README.md:9 nonetheless tells customers to install
  `akedly_shield: ^1.1.0` as if it were on pub. **Publishing to pub.dev is the trigger to revisit the
  pin: do not publish with `^3.0.0` without reopening OI-H.**

## Gotchas

- `flutter_web_auth_2` throws a `PlatformException` with code `CANCELED` on user dismissal; any other
  code is an integration failure. `passkey.dart:85-91` makes exactly that distinction — an
  integration bug must never be reported as "the user changed their mind". Preserve it.
- The ceremony origin is injectable so tests and QA can point at a local Auth-Gateway rather than
  production. Keep it injectable.
