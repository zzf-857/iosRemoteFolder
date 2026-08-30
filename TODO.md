# iosRemoteFolder Optimization TODO

> Plan: [`docs/optimization-plan-2026-08-30.md`](docs/optimization-plan-2026-08-30.md)
>
> Started: 2026-08-30
>
> Rule: check an item only after its acceptance criteria and tests pass.

## Progress Snapshot

- [x] REV-001 Complete architecture, loading, format, quality, and benchmark-gap review.
- [x] PLAN-001 Write the versioned optimization plan.
- [x] PLAN-002 Create this progress tracker with stable task IDs and acceptance gates.
- [x] REL-001 Commit only the plan/tracker and confirm `8db207b` exists on `origin/main`.
- [ ] REL-002 Record the first optimization slice evidence and push its code/tests in a separate commit.

## Phase 1 - Release Blockers And Critical-Path Wins

### Security

- [x] SEC-001A Reject HTTP WebDAV/Alist username, password, and credential references in UI, persistence, and adapter layers while preserving anonymous loopback tests.
- [ ] SEC-001B Limit anonymous HTTP to explicit local-network authorization and migrate/reject unsafe public HTTP entries.
- [ ] SEC-002 Remove global ATS arbitrary loads and validate the narrow local-network policy in Archive.
- [ ] SEC-003 Move remote traffic to controlled ephemeral sessions without shared cookies/cache/credential storage.
- [ ] SEC-004 Implement and test HTTPS downgrade rejection plus cross-origin sensitive-header stripping for PROPFIND/HEAD/GET/Range.

### Measurements

- [x] OBS-001A Add balanced, privacy-safe signposts for directory list, preview queue, and preview render.
- [ ] OBS-001B Add metadata, body, decode, viewer-ready, media-ready, and seek signposts with source/cache/byte dimensions.
- [ ] OBS-002 Capture request count, redirects, TTFB, transferred bytes, protocol, and cache outcome.
- [ ] OBS-003 Extend network fixtures with delay, bandwidth/chunks, cancellation, HEAD 405, ignored Range, and disconnects.
- [ ] OBS-004 Store Release-mode median/p95/RSS/IO baselines and enforce absolute plus 15% regression gates.
- [ ] OBS-005 Add privacy-safe MetricKit payload ingestion and fixture tests.

### Loading

- [ ] LOAD-001 Connect/list only the selected source; unselected sources remain idle.
- [ ] LOAD-002 Reuse only authoritative WebDAV snapshot fields; coalesce probes; enforce DAV body-only preview and zero-request disk-hit budgets.
- [ ] LOAD-003 Add 30 s per-source directory snapshots capped at 20 directories/8 MiB with stale-while-revalidate navigation.
- [ ] LOAD-004 Prioritize viewer/visible/prefetch work; cancel off-screen network within 200 ms and <=64 KiB residual transfer.
- [ ] LOAD-005 Start preview deadline after admission; cache only oversized/unsupported failures for 5 minutes, revision-keyed, capped at 512.
- [ ] LOAD-006 Read at most a 64 KiB range for large text previews with safe truncated-character handling.
- [x] LOAD-007 For online Range media above the dedicated 4 MiB fast path, avoid full GET before player preparation; preserve exact-boundary/offline/unknown/non-Range behavior.
- [ ] LOAD-009 Enforce the interim 2 MiB PROPFIND cap during transfer, bounded to limit plus one chunk.
- [ ] LOAD-011 Reuse HTTP connect discovery and propagate trustworthy revisions into list/cache state.
- [ ] LOAD-012 Share same-revision preview/viewer bodies and make cached online open use <=1 validation and zero body GETs.

### Cache And Quality

- [ ] CACHE-002 Batch preview-manifest access persistence; cache hits do not rewrite the full manifest synchronously.
- [ ] CACHE-003 Publish viewer content before cache storage and offline-projection refresh.
- [ ] CACHE-007 Restore 10,000 cache records in <=150 ms without startup-path per-file stat or per-open offline rescans.
- [ ] QUAL-001 Fix PDFKit actor isolation and make Debug/Release warning-free.
- [ ] QUAL-007 Make missing real Alist configuration report skipped/not-run rather than passed.

### Phase 1 Exit Gate

- [ ] GATE-101 All Phase 1 task IDs listed in the plan are complete, or an owner-approved exception is recorded in the progress log.
- [ ] GATE-102 Full simulator suite passes with no regression from the 180-test baseline.
- [ ] GATE-103 Static analysis and `git diff --check` pass; optimization commits exclude unrelated scheme changes.
- [ ] GATE-104 Request-count, directory, preview, viewer, media, cancellation, and main-thread SLOs have recorded results.

## Phase 2 - Unified Formats And Bounded Storage

### Formats And Viewers

- [ ] LOAD-008A Move text decoding off the main actor with deterministic encoding/binary tests.
- [ ] LOAD-008B Move image validation/downsampling off the main actor with one decode and a pixel budget.
- [ ] LOAD-008C Move PDF preparation off the main actor with one file-backed parse.
- [ ] LOAD-008D Move Markdown attributed parsing off the main actor and cache it per revision.
- [ ] FMT-001 Introduce a shared `ResolvedContentType` with evidence and confidence.
- [ ] FMT-002 Add bounded magic-byte sniffing and safe conflict resolution.
- [ ] FMT-003 Implement real Quick Look, Share, and Open In fallbacks.
- [ ] FMT-004 Materialize unknown-length whole-file consumers through bounded temporary files.
- [ ] FMT-005 Support MIME charset, GB18030/GBK, Big5, Shift-JIS, and binary-text rejection.
- [ ] FMT-006 Validate AV container/codec capability and offer fallback before showing unusable controls.
- [ ] FMT-007 Use file-backed progressive PDF and pixel-bounded/downsampled image pipelines.

### Cache And Security

- [ ] CACHE-001 Enforce 1 GiB total/512 MiB per-source defaults, configurable quotas, LRU, incremental accounting, and per-item deletion.
- [ ] CACHE-004 Add 1 MiB aligned memory Range blocks, overlap coalescing, in-flight deduplication, and <5% duplicate bytes.
- [ ] SEC-005 Add `PrivacyInfo.xcprivacy`, complete privacy/log review, and pass archive validation.
- [ ] SEC-006 Define Keychain/file protection and test lock/background behavior.

### App Reliability

- [ ] QUAL-002 Replace persistence `fatalError` with recovery/export/rebuild and isolate corrupt records.
- [ ] QUAL-004 Pause/cancel directory, preview, and index tasks in background without breaking audio.
- [ ] QUAL-005 Implement, clearly disable, or remove every placeholder action.

### Phase 2 Exit Gate

- [ ] GATE-200 All Phase 2 task IDs listed in the plan are complete, or an owner-approved exception is recorded in the progress log.
- [ ] GATE-201 Declared format matrix has normal, corrupt, truncated, misleading MIME/extension, and oversized fixtures.
- [ ] GATE-202 Cache limits and migrations survive restart, corruption, low disk space, and revision change.
- [ ] GATE-203 Office/iWork/archive samples open through Quick Look or Open In on supported devices.

## Phase 3 - Durable Offline, Scale, And Release

- [ ] CACHE-005 Add bounded network-aware media read-ahead and cancellation.
- [ ] CACHE-006 Build durable Application Support offline downloads with checksum, quota, status, retry, and background transfers.
- [ ] LOAD-010 Batch/page 10,000+ directories and push index sort/fetch limits into storage.
- [ ] QUAL-003 Separate app-wide services from per-window scene/navigation state.
- [ ] QUAL-006 Add UI, lifecycle, iPad split-view, Dynamic Type, VoiceOver, Reduce Motion, and rotation regression tests.
- [ ] REL-003 Validate minimum/current iOS on small iPhone, reference iPhone, and iPad/multi-window.
- [ ] REL-004 Run real NAS/Alist and full weak-network/redirect/range-failure matrix.
- [ ] REL-005 Pass Archive/App Store checks for ATS, privacy, permissions, background modes, signing, and Required Reason APIs.

## Final Exit Gate

- [ ] GATE-301 All P0/P1 tasks are complete; every deferred P2 has an owner, target release, and measurable acceptance.
- [ ] GATE-302 All performance SLOs pass on the reference device without >15% regression.
- [ ] GATE-303 Debug and Release builds are warning-free; unit/UI/accessibility/integration suites pass.
- [ ] GATE-304 Every declared format has a working native viewer or real system fallback.
- [ ] GATE-305 Offline data is durable and bounded; all cache state is inspectable and recoverable.

## Ownership And Evidence

| Workstream | Priority/target | Owner role | Close-out evidence |
|---|---|---|---|
| SEC-001A/001B/002..004 | P0 / Phase 1 | Platform/security | Tests, archive result, sanitized request trace |
| OBS-001A/001B/002..005 | P1 / Phase 1 | Performance | Metrics fixtures, baseline report, `xcresult` |
| LOAD-001..007/009/011/012 | P1 / Phase 1 | Sources/performance | Request ledger, focused tests, before/after metrics |
| FMT-001..007, LOAD-008A..D | P1 / Phase 2 | Viewer/compatibility | Format fixtures, viewer/system fallback evidence |
| CACHE-001..004/007 | P1 / Phase 1-2 | Cache/offline | Restart/corruption tests, size and IO evidence |
| SEC-005/006, CACHE-005/006, QUAL-003/006 | P2 / Phase 2-3 | Platform/release | Device/lifecycle/archive evidence |

Dependencies: `OBS-001A/001B/002/003 -> baseline -> performance changes -> OBS-004`; `SEC-001A -> SEC-001B -> SEC-002..004`; `OBS-002/003 -> LOAD-002/004/009/011/012`; `FMT-001/002 -> FMT-003..007`; `CACHE-001 -> CACHE-004/006/007`; `CACHE-004 -> CACHE-005`; `QUAL-002 + CACHE-001 -> CACHE-006`.

## Progress Log

| Date | Commit | Completed | Verification | Notes |
|---|---|---|---|---|
| 2026-08-30 | `8db207b` | REV-001, PLAN-001, PLAN-002, REL-001 | 180/180 baseline tests; analyze exit 0; `origin/main` verified | PDFKit isolation warnings remain; real Alist is not configured. |
