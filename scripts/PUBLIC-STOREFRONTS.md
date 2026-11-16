# Public storefront observations

This manual command reads public Apple app pages. It does not open an app,
use an account, access App Store Connect, buy anything or modify pricing.
It runs one request at a time and does not retry. A failure stops the batch,
retains successful raw pages and writes an incomplete receipt. Existing output
or raw-response destinations are refused.

```sh
python3 scripts/check-public-storefronts.py \
  --territories docs/evidence/2026-11-15-storefront-territories.json \
  --output /new/evidence/storefronts.json \
  --raw-dir /new/evidence/pages
```

The output parent must already exist; output and raw-directory names must be
new. Keep raw responses outside tracked source. Do not repeat a failed batch
without diagnosing the failure and following its owner's transport-recovery
instruction. The November 15 collection stopped on a UAE timeout and has no
scheduled retry. A future scoped batch can use an explicit subset manifest,
with its intended territory set recorded; it cannot certify the full inventory.

The mapping keys reproduce all 175 entries in the committed October 29
inventory. Values come from the pinned Unicode CLDR source recorded in the
mapping, except Apple's `XKS` identifier maps to CLDR `XKK` / `xk`. Storefront
URLs and canonical app identity are checked on every fetched page. An alias or
redirect to another country never counts as a pass.

The checker requires one SoftwareApplication offer, this app's numeric ID and
developer identity, a currency, and an explicit finite nonnegative price. It
preserves paid offers as paid. Missing, malformed, redirected and failed data
never become Free. `complete` means every requested page was observed;
`freeCount` separately counts explicit zero-price offers. Exit zero requires
both complete coverage and every requested offer to be Free.

The [November 15 receipt](../docs/evidence/2026-11-15-public-storefront-observations.json)
was collected with the initial working checker. Its four successful raw pages
were replayed offline through the final parser; the original timeout receipt
was retained unchanged. Later changes add manifest hashing and protect the
primary error if receipt writing also fails. No network fetch was repeated to
validate those changes. Raw HTML remains in the mission owner's local evidence;
the committed receipt includes response sizes, SHA-256 hashes, exact URLs,
observed offer values and per-request UTC times.

Run focused checks locally; these tests are outside automatic PR CI:

```sh
python3 -m unittest discover -s scripts/tests/manual -p test_public_storefronts.py -v
```

The receipt establishes current public download offers only. It cannot prove
production purchases, trial eligibility, Restore, Family Sharing, private
account settings, exact historical price changes or release qualification.

The separate retained US-page receipt records the exact description phrases,
public privacy label and description privacy link inspected for #469. It uses
the response hash and file timestamp from that earlier anonymous fetch, not
an invented server timestamp. Private ASC fields remain unverified.
