# Cursor subscription billing

Cursor renewals reuse the existing guided phone sign-in and its securely saved
credential. No extra billing connection, cookie import, Stripe server key or
manually entered date is required. Supported personal Stripe subscriptions use
the shared Dashboard renewal setting and show exact dates in More Information.
Cancellation shows an access-end date and never a renewal countdown.

## Verified acquisition contract

Checked October 15, 2026 using Cursor's public dashboard JavaScript and a bounded
development read probe. The probe authenticated with an existing native Cursor
session and successfully read an account-bound Stripe portal subscription. It
did not purchase, cancel, resume or change payment details. Sanitized transport
fixtures reproduce its response shapes, not the private account values.

The [Cursor dashboard helper](https://cursor.com/_next/static/immutable/chunks/16lky4w0czq7c.js)
defines `GET /api/auth/stripe` and `POST /api/stripeSession`. Its SHA-256 was
`c2e5b349e3481513dcbe6342a783e6c0c05cb2a785834eae5a929248a5640647`.
The [guided login entry](https://cursor.com/loginDeepControl) references the
dashboard assets. Marketing-page assets alone do not describe this contract.

1. Build the first-party `WorkosCursorSessionToken` cookie from the token's full
   subject, `::` and access token, percent-encoded. The unsigned subject is only
   a routing hint. `GET https://cursor.com/api/auth/me` must authenticate its
   canonical subject and match the saved auth identity when present.
2. Read `GET https://cursor.com/api/auth/stripe`. Require an individual paid
   membership, a Stripe `paymentId`, explicit plan interval and subscription
   state. Team, free, trial, unknown and non-Stripe profiles are unsupported.
3. `POST https://cursor.com/api/stripeSession` creates an ephemeral portal access
   session. Follow only its exact HTTPS `billing.stripe.com/p/session/` URL.
   Do not send the Cursor cookie or bearer to Stripe.
4. Decode the portal's HTML-escaped `preloaded_json`. Its scoped session key,
   portal session ID, merchant and API version stay only in memory. Reject an
   expired or non-live portal. Never execute downloaded JavaScript.
5. Read `GET https://api.stripe.com/v1/billing_portal/sessions/{sessionID}` with
   that scoped key and merchant. Its `customer` must equal Cursor's `paymentId`.
   Read the same path's `/subscriptions` list. No customer-PII endpoint is needed.
6. Recheck the authenticated Cursor owner, profile and saved credential after
   acquisition. Discard observations if any of them changed.

The [Stripe portal client](https://a300.stripecdn.com/customerportal-statics-srv/assets/customer-portal.b0fwag1uylrviiql.js)
defines these session reads and the subscription date/cancellation semantics.
Its SHA-256 was `5d2eb809b040a80ed4cd3433fea66e601bf7d7e9a0c9b48a706515dc5c6c7efc`.
These are private first-party contracts, not a documented public developer API.
Changed responses fail closed and may require a compatibility update.

## Date rules and isolation

One unambiguous personal Cursor recurring subscription must match the profile's
plan and monthly/yearly interval. Its item and subscription `current_period_end`
must agree. `cancel_at_period_end` is a strict Boolean. An explicit cancellation
date or flag wins and produces non-renewing access. Renewal requires active
status, no pending cancellation, failed payment, recovery, pause, trial, scheduled
update or mixed interval. Invoice dates, usage windows and plan names alone are
never evidence of a renewal. Dates are never advanced by calendar arithmetic.

Every request rejects redirects, shared cookies, caches and credential storage.
Cursor cookies go only to `cursor.com`; the scoped Stripe key goes only to
`api.stripe.com`. The optional sequence has a ten-second total budget and at most
three seconds per request. Credentials are checked before and after each read.
Cancellation propagates. Billing failure keeps successful usage, plan and Grok
Bot results; a later failed observation never restores an older renewal date.
No portal capability or renewal observation enters persistent history, widgets
or watch snapshots. Existing disconnect/replacement invalidation also applies.

## Validation and limits

Local `CursorSubscriptionBillingTests` replay the production provider and billing
transport. They cover monthly/annual dates, cancellation, missing and malformed
state, recovery/trial/scheduled changes, account/customer mismatch, credentials
changing during reads, safe hosts, optional failure and cancellation. The native
`cursor-renewals` UI subjourney exercises the same provider through intercepted
synthetic responses on iPhone and iPad, with light/default and dark/accessibility
text, expanded/collapsed cards, exact dates, canceled/unavailable/stale/past states
and persisted hiding. No test makes a real billing change.

The development probe establishes API acquisition compatibility for one personal
Stripe account. It does not establish every subscription variant or prove the
phone's live values. Franz's phone sign-in and live date comparison remain pending.
