# Swift security analysis

The `Swift security analysis` job builds and analyzes the iOS app, its widget,
the embedded watch app, and its complication. The `Swift security` workflow runs
only by manual dispatch and is not a required merge check. Automatic PR, `main`
push, and scheduled runs are disabled while
[issue #325](https://github.com/HemSoft/codexbar-ios/issues/325) evaluates CI runtime
and reliability.

## Run and review manually

Select the reviewed branch in Actions > Swift security > Run workflow, or run:

```sh
gh workflow run security-analysis.yml --repo HemSoft/codexbar-ios --ref <reviewed-branch>
```

Run this analysis when reviewing authentication, networking, credential storage,
security tooling or toolchain changes, and during release preparation. The
maintainer requesting the run owns reviewing its findings and the
`swift-security-<run-id>-<attempt>` artifact. Record the analyzed commit, extraction
coverage, reviewed and blocking findings, and the final job result in the related
issue or PR. A timeout or missing report is incomplete evidence.

The manual job still fails on incomplete extraction, stale reviewed baselines,
or unreviewed high-severity findings. Removing it from branch protection does
not change those checks or mark earlier cancelled analyses as passing. Follow
`Maintaining reviewed findings` below when production source changes.

## Analyzer and source reach

The workflow pins CodeQL Action 4.37.9 to a commit and the CodeQL bundle to
2.26.4. That bundle includes `codeql/swift-queries` 1.3.9 and `codeql/swift-all`
6.8.2. It runs the `security-extended` suite, including the default security
queries. No security queries or production paths are excluded.

The job sets `CODEQL_ACTION_DIFF_INFORMED_QUERIES=false`. The pinned Action
[enables diff-informed queries by default](https://github.com/github/codeql-action/blob/cdf488f595d80d6e07e03d4674febd5ab45fa938/src/feature-flags.ts#L240)
on pull requests and limits their results to changed lines. That is unsuitable
for this full-source baseline gate: the same source tree previously returned
zero findings on a PR and three on `main`. Keeping the feature disabled preserves
full-source analysis if PR triggers are restored. Verify the hosted analysis log contains no
`--extension-packs=codeql-action/pr-diff-range` option after Action upgrades.
File extraction counts alone cannot detect result filtering.

The [CodeQL support matrix](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/)
covers Swift 5.4-6.3. [CodeQL 2.26.2 added Swift 6.3.3 extraction](https://codeql.github.com/docs/codeql-overview/codeql-changelog/codeql-cli-2.26.2/),
which matches this repository's Xcode 26.6 compiler at setup. The check records
the actual Xcode, Swift, and CodeQL versions on every run; an unsupported upgrade
needs working manual extraction evidence before its analyzer support is claimed.

Swift requires a [traced build](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages).
`scripts/security-analysis/build.sh` uses a new Derived Data directory and the
`CodexBarIOS` scheme with the Debug simulator configuration and one architecture.
The scheme builds all four production targets. This includes authentication,
provider networking, credential and history persistence, and `CodexBarIOS/Shared`.
Debug also includes the isolated UI-test fixture support in the app source tree.

Only this analysis build sets `SWIFT_ENABLE_EXPLICIT_MODULES=NO`, using Apple's
[documented opt-out](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes).
The first run found precompiled SDK modules from Xcode's Clang incompatible with
the CodeQL Swift compiler. Implicit modules let each compiler build its own
compatible modules. The second hosted run removed the SDK module errors but
still reported 12 compiler errors in two app views. Both use StoreKit's
`requestReview` environment value, which comes from the StoreKit/SwiftUI
cross-import overlay.

The analysis build also passes `-Xfrontend -enable-cross-import-overlays`.
[Swift's frontend defaults this option to false](https://github.com/swiftlang/swift/blob/2d17dddbfb0dca8cdf66d12918e4068a878d8ab2/include/swift/Basic/LangOptions.h#L257),
whereas Xcode enables overlays. [CodeQL's pinned extractor](https://github.com/github/codeql/blob/codeql-cli/v2.26.4/swift/extractor/main.cpp)
invokes that frontend without changing the option. A minimal `requestReview` view reproduces the
reported initializer and key-path errors with overlays disabled and compiles
with them enabled. The [third hosted run](https://github.com/HemSoft/codexbar-ios/actions/runs/34003751678)
confirmed complete extraction with no compiler or extraction errors. The job
allows 60 minutes after the first traced build took about 39 minutes.

An evidence-only CodeQL query counts extracted syntax nodes and compiler errors
for each Swift file. The gate requires syntax for every tracked `.swift` file in
`CodexBarIOS`, `CodexBarIOSWidget`, `CodexBarWatch`, and `CodexBarWatchWidget`.
Adding a file without adding it to a build target fails this coverage check.
Compiler errors also fail even if the rest of the file extracted. SARIF Swift
extraction diagnostics fail regardless of their reported level, including errors
in SDK files outside the repository. The CSV is
included in the run artifact. A source archive alone is not coverage evidence.

Unit tests, UI test targets, the smoke executable, and development scripts are
outside the production scope; they are covered by the normal CI checks. Imported
SDK/dependency declarations may appear in the database but are not counted as
repository production files. Conditional branches inactive for the selected
simulator platforms are not analyzed. These file counts do not prove that every
possible data flow, platform branch, or runtime vulnerability was checked.

## Findings and analysis gate

The check uploads SARIF to the repository's **Security > Code scanning** page
under category `swift-production`, waits for processing, and retains SARIF,
compiler versions, extracted-source counts, and `gate.json` as an Actions
artifact for 14 days. The job has only `contents: read` and
`security-events: write`; checkout does not persist credentials. Manual runs
use `workflow_dispatch`, never privileged `pull_request_target` execution.

`scripts/security-analysis/gate.py` fails on any security severity of 7.0 or
higher unless it exactly matches a reviewed non-actionable finding in
`scripts/security-analysis/reviewed-baseline.json`. Lower-severity findings are
still published for triage. Missing, failed, or malformed analysis, empty query
metadata, incomplete source reach, and extraction errors also fail the job.
GitHub alert dismissals and SARIF suppressions do not grant an exception.

The raw SARIF remains intact and is uploaded before the gate. `gate.json`
separately reports all `findings`, `accepted_findings` with their review rationale,
and `blocking_findings`. A passing analysis with three reviewed findings means
three findings and zero actionable high-severity findings, never a clean scan
with zero findings. No baseline is refreshed automatically.

The default-branch ruleset requires only automatic `SwiftLint`, with strict
branch freshness, as documented in [CI-POLICY.md](CI-POLICY.md). The full manual
gate retains all five quality workloads for releases or on-demand validation.
`Swift security analysis` is not required by that ruleset. Its manual job still fails on the findings and extraction rules
above. The workflow file does not configure repository rules; verify both when
changing policy so a removed trigger does not leave a required status pending.

## Initial baseline

Before [issue #309](https://github.com/HemSoft/codexbar-ios/issues/309), the
code-scanning API returned `no analysis found`. The
[first hosted run](https://github.com/HemSoft/codexbar-ios/actions/runs/33998745093)
found the temporary TLS fixture at severity 7.5 and no other findings, but 422
extraction diagnostics included incompatible SDK modules and app compiler
errors. Its required job failed on grouped SARIF metadata handling. The
[second hosted run](https://github.com/HemSoft/codexbar-ios/actions/runs/34000819436)
removed the SDK errors but retained 12 extraction diagnostics. The corrected
gate rejected them. Neither run established a complete baseline or the intended
severity-driven failure proof.

The [third hosted run](https://github.com/HemSoft/codexbar-ios/actions/runs/34003751678)
published analysis `1730704365` at 9:56 PM EDT on September 5, 2026 for test merge
commit `3019a50d3deabaac0899d0bbc4cb1035baf58ed0`, combining base `99cc12a` and PR
head `1f5bd75`. CodeQL 2.26.4 extracted syntax from all 84 tracked production
Swift files, with zero compiler errors and zero extraction diagnostics. Its
only finding was `swift/insecure-tls`, severity 7.5, at line 7 of the temporary
fixture. All analysis steps succeeded, and the required severity gate failed
with exit code 1 solely because of that finding. Replaying the downloaded SARIF
and source-reach CSV produced the same gate result. No other findings appeared
in that PR analysis. It used diff-informed queries, so its zero production
finding count did not establish a full production baseline.

The fixture was removed after that proof. The final PR analysis extracted all
87 production files and reported zero findings, but its diff-informed result
filter omitted unchanged code. The [first merged `main` run](https://github.com/HemSoft/codexbar-ios/actions/runs/34008831770)
analyzed commit `3395ee6094ce8e4199577f7ede493e3a50ee1269`, the same source tree
as the PR test merge, and failed on three severity-7.5 findings. That failure
invalidated the proposed zero-finding baseline and reopened
[issue #309](https://github.com/HemSoft/codexbar-ios/issues/309).

The [next full `main` analysis](https://github.com/HemSoft/codexbar-ios/actions/runs/34019023090)
for `cbc0d0031a0e07d4f3ed3f6e588bf578928690cc`, analysis `1731293117`, confirmed
all 87 production files extracted, no extraction errors, and the same three
findings. Review found these specific contexts non-actionable:

| Finding | Reviewed evidence and boundary |
| --- | --- |
| [#2, weak password hashing](https://github.com/HemSoft/codexbar-ios/security/code-scanning/2) | `OpenCodeZenUsageProvider.cacheIdentity` hashes the workspace and session values for ephemeral cache equality in `UsageRefreshService`. `ProviderUsageResult` is not Codable. The digest is neither persisted nor used as a password verifier. Persisting, exposing, or authenticating with it requires another review. |
| [#3, cleartext preference storage](https://github.com/HemSoft/codexbar-ios/security/code-scanning/3) | `saveCollapsedDashboardAccountIDs` writes collapsed-state identifiers already present in saved configurations. Account IDs are local provider names or provider-plus-UUID values. The updater rejects IDs absent from configurations. These IDs are not credentials or provider account identities. |
| [#4, cleartext preference storage](https://github.com/HemSoft/codexbar-ios/security/code-scanning/4) | The private `UITestSecretStore` rejects every value except the literal `ui-test-credential`. Its DEBUG simulator launch contract uses a UUID-isolated defaults suite and blocks provider networking. The stored marker has no authentication authority. |

This rollout predates the manual-only policy. The old filtered PR results and
local SARIF replay do not establish a current hosted baseline. To report a new
baseline as passing, manually analyze the reviewed branch and record its commit,
complete source reach, extraction errors, reviewed findings, blocking findings
and final job result. Dispatch against `main` when default-branch evidence is
needed; a merge no longer starts that analysis automatically.

## Review for the six Google quota choices

For [#319](https://github.com/HemSoft/codexbar-ios/issues/319), the
[full hosted analysis](https://github.com/HemSoft/codexbar-ios/actions/runs/34046485826)
analyzed test merge `cc4e381faeb9f96a66e2841cabb3a67736e7b5cd`, containing PR head
`ecd331d10cae0c35635f137f41c72c827ed607c5`. Analysis `1732313795` reported the
same three findings, complete source reach, and no extraction errors. The gate
rejected the changed production snapshot as designed.

Re-review of that head confirmed the existing boundaries: `cacheIdentity` is
still used only for in-memory cache equality, `ProviderUsageResult` remains
non-Codable, and collapsed-state IDs remain configuration-validated local IDs.
The new Google UI fixtures save only the same literal `ui-test-credential`.
Their DEBUG simulator guard, isolated defaults suite, network blocker and
private secret-store validation remain intact. The fixture diagnostic moved
from line 162 to 209; its current raw SARIF was reviewed before updating its
exact identity. The other two diagnostic identities are unchanged.

The reviewed baseline pins that source snapshot. Replaying its hosted SARIF
and source-reach CSV accepted exactly those three findings and reported zero
blocking findings. Later Google fixture changes moved the diagnostic again and
changed the source snapshot. The subsequent extraction build timed out, so the
current source still needs a fresh manual analysis and baseline review under
issue #325. The older replay is not a passing analysis of the current tree.

## Release re-review for 1.4.0

The [October 1 full analysis](https://github.com/HemSoft/codexbar-ios/actions/runs/36823093844)
examined merged source `7d466be0e507435168c3474e6f19e8fd2b973f3a`. CodeQL 2.26.4
and the unchanged Swift query pack extracted all 103 tracked production files
with zero compiler/reach errors and no SARIF extraction diagnostics. The job
failed because the old baseline's production snapshot was stale, as intended.
Its raw SARIF still reports exactly three severity-7.5 findings, not zero.

Under [release issue #373](https://github.com/HemSoft/codexbar-ios/issues/373),
the raw diagnostics, their locations/data flows, and current consumers were
reviewed before renewing the exact identities:

- OpenCode's SHA256 digest still identifies the workspace and session pair for
  in-memory cache equality. The result remains non-Codable, and History,
  widgets, and Watch snapshots do not retain that field. The newer Grok plan
  verification consumer checks `.grok` on both result and configuration before
  comparing a Grok subject digest; it cannot authenticate using an OpenCode
  cache digest. The diagnostic is now at OpenCode line 134.
- Collapsed dashboard preferences still store configuration-validated local
  IDs, never provider credentials or account identities. New accounts still
  use provider-plus-UUID IDs. The diagnostic is now at store line 2372.
- The private UI-test secret store now permits the literal fixture marker,
  the parsed fixed synthetic coding credential, and the exact two synthetic
  personal/work Codex strings. It rejects other parsed credentials. The
  simulator-only DEBUG guard, required UUID defaults namespace, and network
  blocker remain intact. These fixtures grant no provider access. The earlier
  literal-only rationale is no longer sufficient; the renewed entry describes
  the actual guard. The diagnostic is now at fixture line 980.

The reviewed source commit is
`ba2cb11306ab94c238b93cba3174a7bc44616ca5`, including the additional DEBUG-only
storefront routing and data preparation. Extended History seeding is restricted
to its explicit screenshot scene. That restriction does not change the three
finding sites, accepted synthetic values, launch guards, or cache-digest consumers. The baseline binds all production
sources to snapshot
`03da988048ac3e4d9976df750a7f8113d385b866087a4e4a418e7ccfffb158b1`.
No analyzer pin, severity threshold, matching rule, extraction requirement, or
exclusion changes. Local replay of the fresh merged-source diagnostics checks
these identities; it is not fresh hosted extraction of the preparation branch.
A full manual hosted run must pass on that branch before this renewed baseline
is described as passing, and the eventual merged candidate needs its own run.

## Maintaining reviewed findings

Each exception pins the exact rule, severity, message, primary location, and a
SHA256 of the full SARIF diagnostic, including data flows, related locations,
and fingerprints. Only rule-table and artifact-table positions are omitted
because they can reorder between runs. A changed diagnostic, duplicate match,
missing reviewed finding, or changed CodeQL/query-pack version fails the gate.
An additional high-severity finding always blocks, including one in unchanged
source or on another line of a reviewed file.

The baseline also pins the names and contents of **every tracked production
Swift file**. This intentionally requires re-review after any production Swift
change, including new downstream consumers outside the original finding files.
It avoids carrying a false-positive classification forward after the security
context changes. Editing only the workflow, gate tests, or documentation does
not change that source snapshot.

When the snapshot changes, review each finding's source and consumers against
the boundaries above. Fix actionable findings. If the contexts remain
non-actionable, update the reviewed commit and source digest in the issue-linked
PR, explain the review, and dispatch the full hosted analysis manually. A
successful result is needed before reporting the updated baseline as passing;
this is not a required merge check. Update exact diagnostic identities only
after reviewing the newly produced raw SARIF.
Remove entries for resolved findings through review; their disappearance is
not silently accepted. A new exception needs its own explicit finding,
evidence, and rationale. Never add path-wide or rule-wide exclusions.

This read-only helper prints the source digest for a reviewed checkout. It does
not edit the baseline or classify findings:

```sh
python3 - <<'PYCODE'
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("security_gate", "scripts/security-analysis/gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
print(gate.source_snapshot(Path.cwd()))
PYCODE
```

To inspect a completed analysis, use both APIs, checking its analyzed commit and
`error` field before interpreting an empty alert list:

```sh
gh api 'repos/HemSoft/codexbar-ios/code-scanning/analyses?per_page=20'
gh api 'repos/HemSoft/codexbar-ios/code-scanning/alerts?state=open'
```

Manual analysis records the selected ref's resolved commit. Check the run's
`headSha` and the analysis commit before associating findings with a PR.
Historical pull-request analyses normally recorded GitHub's test merge SHA and
`refs/pull/<number>/merge`. Match those records to the corresponding run instead
of treating a test merge as the branch head.

## Review for the opt-in Codex credits pool

The [manual analysis](https://github.com/HemSoft/codexbar-ios/actions/runs/36983494276)
finished on October 2, 2026 at 4:59 AM EDT for production commit
`ace90929a3babcbc25b3b2a54d2438168b986e0b`. It extracted all 103 production
Swift files with no compiler or extraction errors. Its three severity-7.5
findings match the existing reviewed contexts. The final job failed because
the baseline's source snapshot was stale, not because extraction failed.

The production tree is identical at reviewed commit
`7c4eb9fd11c8eb2a3e5497ee7268a7e9534c2f06`. Review confirmed that the OpenCode
hash remains an ephemeral cache-equality value, collapsed IDs remain local
configuration IDs, and the private UI-test store accepts only fixed synthetic
credentials behind the simulator-only, UUID-isolated, network-blocked launch
contract. The credits fixtures do not change those boundaries.

Subsequent copy-layout and history-eligibility fixes were reviewed at
`f8ef6d2c482bbc8242790564f3215cf23e19bf61`. They change no credential boundary
or consumer involved in these three findings. The baseline binds that production
snapshot and the exact updated SARIF identities. Its three exceptions,
rationales, severity threshold, analyzer versions and source-reach requirements
are unchanged. Replaying the retained evidence accepts the three known findings
with zero blocking findings. This replay is not a new analysis of changed files
and does not make the failed hosted job pass. Fresh hosted analysis remains
pending.

## October 6 release source review

Release issue [#373](https://github.com/HemSoft/codexbar-ios/issues/373) resumes
from product commit
[`34eab95`](https://github.com/HemSoft/codexbar-ios/commit/34eab950d15451a7dd5706d484cc564d2796c4d2).
Its 109 tracked production Swift files have source snapshot
`1821c3d0521a7bebd41803e0a57ee14652665fd1020d7614c6c17199bdb77b78`.
The previous passing analysis covered an older source snapshot and cannot
validate the new Cursor and Greptile authorization paths.

The [fresh diagnostic run](https://github.com/HemSoft/codexbar-ios/actions/runs/37446684582)
uses the unchanged manual hosted workflow. It completed on October 6 at
6:31 AM EDT, extracting all 109 production files with zero compiler/reach
errors and no SARIF extraction diagnostics. It reports the same three
severity-7.5 findings. The job failed on the stale production-source baseline;
that failure is preserved, and replay does not make the hosted run pass.

Current review of the existing finding contexts confirms:

- OpenCode's SHA256 value still serves ephemeral workspace/session cache
  equality in `UsageRefreshService`. All `cacheIdentity` consumers were reviewed;
  `ProviderUsageResult` remains non-Codable. Other providers' identities are
  independent cache keys. The OpenCode digest is not persisted, published to
  companion snapshots, or used as a password verifier.
- Collapsed dashboard IDs remain configured local provider or provider-plus-UUID
  IDs. The collapse updater rejects unknown IDs, and credentials are stored
  separately through `SecretStore`.
- The private `UITestSecretStore` now accepts additional exact synthetic Cursor
  credentials (both fixed-expiry variants) and the parsed fixed Greptile session,
  alongside the prior literal, coding and Codex values. Cursor uses an unsigned
  fixture token with a synthetic signature. Greptile uses `synthetic-user`,
  `synthetic-org` and `synthetic-cookie`; these values grant no provider access.
  Arbitrary credentials are rejected before the preferences write. Fixture
  activation still requires DEBUG, a simulator and a UUID-isolated defaults
  namespace. The network blocker permits only synthetic Greptile responses at
  `greptile-fixture.invalid` and rejects other destinations. The prior rationale,
  which omitted these new accepted values, must not be carried forward unchanged.

The baseline now binds this reviewed product commit and source snapshot. Its
three exceptions use the fresh raw SARIF identities: OpenCode remains at line
134 with an unchanged diagnostic; collapsed IDs moved to line 2369 and the
private fixture write to line 1205. The latter rationale now includes Cursor
and Greptile synthetic values and their current guards. Replaying the retained
SARIF/source-reach CSV accepts exactly three findings with zero blockers and
full 109/109 reach. No analyzer pin, severity threshold, matching rule or
production path changes.
This preparation changes no production Swift source. A replay against the
renewed baseline must be identified as replay, not a successful hosted run.
The eventual merged release candidate still needs its own complete passing
hosted result; this diagnostic is not the final-candidate release gate.

## Reproduce the positive test

The positive test uses `scripts/security-analysis/fixtures/Positive.swift` to
configure TLS 1.0 in an uncalled function. It creates no network request and uses
no credentials. The fixture is absent from the final tree. `build.sh` compiles
it separately when it exists; it never links the fixture into a production
target. CodeQL's
[`swift/insecure-tls`](https://codeql.github.com/codeql-query-help/swift/swift-insecure-tls/)
query has security severity 7.5 and must fail the same manual analysis job.

For future analyzer upgrades, create that path on an issue branch with the
following contents, dispatch the workflow on that branch, and observe the
authentic finding and failed `Swift security analysis` status. Then remove the
fixture, dispatch again and require the next analysis to pass:

```swift
import Foundation

func insecureTLSPositiveFixture() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
    return configuration
}
```

Gate parser failure tests run with:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_security_analysis.py' -v
```

Those tests use synthetic parser inputs. They do not replace the real CodeQL
positive test or prove analyzer reach.

For local extraction with the pinned CodeQL bundle on a supported Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SECURITY_DERIVED_DATA="$(mktemp -d)/DerivedData"
codeql database create /tmp/codexbar-security-db --language=swift \
  --source-root=. --command=./scripts/security-analysis/build.sh
codeql database analyze /tmp/codexbar-security-db \
  codeql/swift-queries:codeql-suites/swift-security-extended.qls \
  --format=sarif-latest --sarif-group-rules-by-pack \
  --output=/tmp/codexbar-security.sarif
codeql query run scripts/security-analysis/queries/source-reach.ql \
  --database=/tmp/codexbar-security-db --output=/tmp/codexbar-reach.bqrs
codeql bqrs decode /tmp/codexbar-reach.bqrs --format=csv --output=/tmp/codexbar-reach.csv
python3 scripts/security-analysis/gate.py --sarif /tmp/codexbar-security.sarif \
  --reach /tmp/codexbar-reach.csv --output /tmp/codexbar-security-gate.json \
  --baseline scripts/security-analysis/reviewed-baseline.json
```

Use unused database/build paths. Some local Macs cannot execute the tracer's
copied system shell; `Bad CPU type in executable` is an extraction failure, not
a finding-free scan. Use the manual hosted workflow to obtain extraction
evidence when the local tracer cannot run.

The CLI's [rule-grouping option](https://docs.github.com/en/code-security/reference/code-scanning/codeql/codeql-cli-manual/database-analyze#--no-sarif-group-rules-by-pack)
retains the pack metadata required by the baseline. Local CLI findings can still
have different diagnostic details or fingerprints from the Action's SARIF;
those differences correctly require review and may fail exact matching. Do
not loosen the matching contract to make local output pass. To replay an
existing hosted baseline exactly, download its `swift-security-*` artifact
and pass the original `sarif/swift.sarif` and `source-reach.csv` to the gate
from a checkout whose production snapshot matches the reviewed source.

## October 8 Claude reset source review

Issue [#420](https://github.com/hemsoft-dev/codexbar-ios/issues/420) adds
account-specific saved-reset inventory and an explicitly confirmed provider
mutation. Reviewed production source
[`c36ddf7`](https://github.com/hemsoft-dev/codexbar-ios/commit/c36ddf76e8039b1f2cfeebfbe9af838408102353)
contains 113 tracked production Swift files with snapshot
`d408551a9430b13aa001bd5095eec66c98b5ccba0b5aa2dd8ba2fb95e8fe4252`.
The exact originally confirmed grant and credential binding travel unchanged
through the card, orchestrator, service and provider to the client's fresh
comparison. Changed cached terms are rejected before reset preflight or POST.
Reset inventory remains transient; ambiguous-request receipts persist only
hashed account, organization and grant identity with count/time, with file
protection and backup exclusion. Credentials and raw grants are not exported to
history, widget/watch snapshots, configuration backups or diagnostics.

Manual analysis
[37759320889](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37759320889)
analyzed earlier product source `700c9afbc9e1730a6fd0e6b78cc512701a5534bd`
with CodeQL 2.26.4 and Swift query pack
`1.3.9+1d123a2caa0e4e6256a49d963bfcbd51a01617e8`.
It extracted 113/113 production Swift files and returned exactly three
severity-7.5 findings. The job failed because the reviewed production snapshot
was stale. Complete raw diagnostics, related locations/data flows and current
consumers were reviewed before renewing the baseline:

- OpenCode's SHA256 cache identity at line134 has unchanged diagnostic
  `5f1496c65fc30d9560b382010124317c39ab181e30f19c854ccc92e29e9b3b0a`.
  It remains an ephemeral cache comparison, never a persisted password verifier.
- Collapsed local configuration IDs at line2371 have diagnostic
  `a283b8ef3e8e280df73624ba73ebb4acdf7b4df58d11a137b189ff3d30fb43e5`.
  The updater rejects unknown IDs; provider credentials remain separate.
- The simulator-only fixture preference writer at line1296 has diagnostic
  `7a76b8617fb1d68689fa36aa3d4844ff07a284e8c8c75c492398e9a1630e9e13`.
  Its exact accepted synthetic values now include the plan-pill Grok subject
  and access/refresh token fixtures. Arbitrary credentials are rejected. DEBUG,
  simulator, UUID-isolation and provider-network blocking guards remain intact.
  Claude reset fixtures use only `ui-test-credential` and the isolated fake
  provider; they cannot consume a live reset.

No additional reset finding appeared. Replaying the retained raw SARIF and
source-reach CSV against the renewed exact baseline accepts those three
findings with zero blockers and complete source reach. Severity thresholds,
diagnostic matching, extraction requirements and exclusions are unchanged.
Replay is not a passing hosted analysis of the repaired source.

Fresh hosted analysis
[37768114114](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37768114114)
passed at `80649e18cf5f224588029431912a9881c055d8c7`, which adds the renewed
baseline to that reviewed production source. The pinned Xcode 26.6 / Swift 6.3.3
build, CodeQL 2.26.4 and Swift query pack
`1.3.9+1d123a2caa0e4e6256a49d963bfcbd51a01617e8` extracted all 113
production Swift files with no extraction errors.
The gate accepts exactly the three reviewed diagnostics above and reports zero
blocking findings. The retained raw SARIF, source-reach CSV and gate report
verify the successful result without changing thresholds or exclusions.

The subsequent grant-boundary/cooldown review at
`c2c54bc6256130c2495182a80a4d12a6883b487d` binds the same 113 production
Swift filenames to source snapshot
`4ff4bbf03167efc3c1ceacb7433c64b50535058f2b691e1592a21eb9ab34d68c`.
The new time-dependent reset display and cooldown labels add no credential persistence,
provider mutation, export or cache consumer. New dashboard/cooldown scenarios
still accept only the existing synthetic credential and block provider networking.
The three finding sources, locations and complete retained diagnostic/data-flow
identities are unchanged; the reviewer renewed their source/consumer assessment
without changing diagnostic identities, thresholds or exclusions. The earlier
hosted result remains evidence for its analyzed source. Fresh hosted analysis of
the boundary repair is required before reporting this renewed baseline as passing.

Native checks subsequently rejected the explicit dashboard schedule at1455ace:
both families retained two resets past expiry. The bounded local periodic-display
repair at `2ee959433c9217ca4e4ce0ffe87dcb61e2e06e1b` passes untouched-dashboard expiry/start and cooldown transitions
on both families with zero reset requests (iPad116.496s, iPhone117.280s).
The source snapshot is `9aadd2257e81c45686d7ecf2da925bc3f80ff5dc907217967c66ae29b41168c6` with the same113 files.
The grant model returns to its previously reviewed implementation; the visible
reset section now uses the existing one-second timeline pattern. This changes
no credential consumer, persistence or provider request. Exact retained finding
identities remain unchanged after source/consumer re-review. The stale-source
1455ace hosted extraction was intentionally canceled; a fresh analysis must
verify this final source before its renewed baseline is reported as passing.

## Claude Fable identity review, October 8

Manual run [37795032431](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/37795032431)
analyzed `ecd05b51c670054d9dc72255eee0b31c5d302ec5` with Xcode 26.6,
Swift 6.3.3, CodeQL 2.26.4 and the pinned Swift query pack
`1.3.9+1d123a2caa0e4e6256a49d963bfcbd51a01617e8`. The build and analysis
succeeded. All 115 tracked production Swift files had extracted syntax, with
zero extraction errors. The hosted gate failed because the prior 113-file
production snapshot was stale.

The complete raw SARIF contains exactly the same three severity-7.5 contexts.
Their locations, related locations, data flows and consumers were reviewed
before renewing the exact diagnostic identities:

- `OpenCodeZenUsageProvider.swift:134` is unchanged. Its digest remains an
  ephemeral cache identity, neither a password verifier nor persisted data.
- `ProviderConfigurationStore.swift:2375` stores local collapse-state IDs.
  The Fable migration changes metric choices, not account-ID generation or
  secret storage. Unknown collapsed IDs remain rejected.
- `UITestFixtures.swift:1329` accepts only the existing fixed synthetic
  credentials. Fable fixtures add usage payloads, not accepted credentials.
  DEBUG, simulator, UUID storage and provider-network guards remain intact.

Reviewed production commit `07711d0467d276b1dc0717a5ea6c262c38a6311b`
has identical production bytes to the analyzed commit. Its 115-file digest is
`544189229dbf2ff3e600d3e456a495a3eb4bb2bd40ced53c4b48402d7a605039`.
Local replay of that hosted SARIF and source-reach CSV against the renewed
baseline passes with three accepted findings and zero blockers. No severity
threshold, query selection or exclusion changed.

This is a reviewed local replay, not a successful hosted baseline-renewal run.
The hosted result remains failed on its old baseline. Do not report the renewed
baseline as hosted passing until a full manual analysis succeeds on the reviewed
branch or release candidate. That is not an ordinary-PR merge status. The raw
analysis is not repeated solely for baseline and documentation metadata.

## October 18 Cursor history tie-break review

Issue [#490](https://github.com/hemsoft-dev/codexbar-ios/issues/490) changes one
production function. `UsageHistoryStore.cursorPrimaryUsageSeries` now orders the
snapshots sharing a timestamp by ID before choosing a point. Reviewed production
commit `4e653a754eaa248334491e822b791250b530dbc4` has the same 157 production Swift
files with source snapshot
`308dc5fc7825e6bcab870fac93645461f90b5b16922c406d1f055389173c2e6e`.
The change reads in-memory history only. It adds no persistence, credential,
network or export path, and none of the four reviewed finding files or their
consumers changed. The four exact diagnostic identities from
[run 39137060109](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39137060109)
remain the accepted findings. Local replay of that SARIF and source-reach CSV
against this baseline is a replay, not a hosted pass; the release candidate
still needs its own successful hosted analysis.

[Run 39154682983](https://github.com/hemsoft-dev/codexbar-ios/actions/runs/39154682983)
passed on the hosted analyzer for that baseline at `4aff1f1`.

`StoreKitProCatalog.load()` then gained one guard: an empty StoreKit product
lookup throws `catalogUnavailable` instead of returning an empty catalog. It
touches no credential, persistence or network boundary. Reviewed commit
`cedd7a74ef51b104969052d3a65141d801e04677` binds source snapshot
`694c0669b8bf840138a6dffbc0856e5f60a87560fac17059450fe69409b22ad4`
with the same 157 files and the same four accepted diagnostics.

## October 19 iPad dashboard layout review

Issue [#496](https://github.com/hemsoft-dev/codexbar-ios/issues/496) changes only
`CodexBarIOS/ContentView.swift`. iPad lays out dashboard cards eagerly in a custom
`DashboardCardColumnsLayout` instead of a lazy grid, which froze while scrolling on
iOS 26. Reviewed commit `10d784c781e6f7870b4a510e0fa1416620e4a98a` binds source snapshot
`4b82d0db9d273ae396db008236f18737e822d615cc4e09cfa87f0539bde55e52`
with the same 157 production files. The change is view layout only. It adds no
credential, persistence, network or export path, and touches none of the four
accepted finding files or their consumers, so the accepted diagnostics are unchanged.
The release candidate still needs its own hosted analysis.

## October 19 Release preview guard review

Issue [#504](https://github.com/hemsoft-dev/codexbar-ios/issues/504) moves the
`ContentView` `#Preview` inside its existing `#if DEBUG` region. Release builds no
longer contain the preview, and Debug builds are unchanged. Reviewed commit
`ffa05c0b901970dc261463f1a44e798cb9b3f1ae` binds source snapshot
`b26f29f5189641a72e179f39fc48ca2aac32283bba5c283e49992fd7bfb25398`
with the same 157 production files and the same four accepted diagnostics.
