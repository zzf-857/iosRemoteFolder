# iosRemoteFolder Optimization Plan

> Date: 2026-08-30
>
> Baseline branch: `main`
>
> Baseline commit before this plan: `a8e92e2`
>
> Progress tracker: [`TODO.md`](../TODO.md)

## 1. Purpose

This plan turns the 2026-08-30 architecture review into an executable delivery program. The order is deliberate:

1. Close release-blocking transport security gaps.
2. Add measurements before changing the loading pipeline.
3. Remove duplicated requests and whole-file work from the critical path.
4. Make format detection and system fallback truthful and extensible.
5. Add bounded caches, a real offline model, and large-file support.
6. Finish with device, weak-network, accessibility, and release gates.

The tracker uses stable task IDs. A task is complete only after its acceptance criteria and relevant tests pass; landing code alone is not completion.

## 2. Current Baseline

- The app supports local files, WebDAV/Alist adapters, HTTP resource sessions, typed metadata, previews, PDF/text/image viewers, AVFoundation playback, indexing, recent items, and revision-aware content caching.
- The simulator suite passes `180/180` tests on iPhone 17 Pro / iOS 26.5.
- Static analysis exits successfully, but `PDFKit` coordinator callbacks emit Swift concurrency isolation warnings.
- There are no performance baselines, signposts, MetricKit collection, UI tests, or automated weak-network tests.
- Real Alist coverage is environment-dependent and currently returns successfully when its environment variables are absent instead of reporting a skipped test.
- The working tree contains a pre-existing scheme edit. It is not part of this optimization program unless separately reviewed.
- The repository README records that development resumed on 2026-08-13, and the owner explicitly authorized this plan, its GitHub baseline push, and implementation on 2026-08-30.

## 3. Product And Engineering Goals

### 3.1 Loading

- A previously visited directory must appear immediately while freshness is checked in the background.
- A WebDAV item should reuse directory metadata and avoid resource-level discovery requests when the snapshot is still valid.
- Previews should use server thumbnails, prefixes, ranges, downsampling, or file-backed APIs instead of downloading the whole source whenever possible.
- Opening content should publish the viewer before non-critical cache persistence and offline-index refresh work.
- Remote media with Range support should stream early. Viewer safety budgets such as the current 50 MiB cap must not double as streaming policy; any small-file fast path uses a separate measured threshold.

### 3.2 Format Compatibility

- Type resolution must combine UTType, MIME, extension, and bounded signature sniffing with explicit confidence instead of hard-rejecting every disagreement.
- Viewer selection and preview selection must use the same resolved type.
- Quick Look, Share, and Open In must be real fallback paths for Office, iWork, archives, and other system-supported files.
- Unknown-length responses must be materialized through a bounded temporary file when a whole-file consumer needs them.
- Text decoding must cover declared MIME charset plus common Chinese and Japanese encodings without silently treating arbitrary binary as text.

### 3.3 Security And Reliability

- Authenticated HTTP must never transmit credentials in clear text.
- ATS exceptions, cookies, credential storage, redirects, and sensitive headers must be narrowly controlled.
- No production startup path may terminate with `fatalError` for recoverable persistence damage.
- Content and preview caches must have hard limits, deterministic eviction, and recoverable manifests.
- Offline downloads must be durable user-owned state, not an incidental projection of the system cache directory.

## 4. Target Loading Architecture

```text
source selection
  -> lazy connection for the selected source
  -> directory snapshot cache (immediate stale display)
  -> one background conditional refresh
  -> shared resolved metadata/type snapshot
  -> viewport-aware preview scheduler
       -> server thumbnail / range prefix / file-backed Quick Look
       -> decode and downsample off the main actor
  -> viewer becomes visible
  -> cache persistence and offline projection update asynchronously
```

Cross-cutting rules:

- Keys include source identity, logical path, and revision whenever a revision is known.
- Identical in-flight metadata, preview, body, and range requests are coalesced.
- Deterministic unsupported/oversized preview results may be negatively cached; transient failures may not.
- Cancellation must propagate to the network and file system layers promptly.
- Every cache has a documented byte/count budget and an invalidation owner.

## 5. Workstreams

### 5.1 Security (`SEC`)

| ID | Deliverable | Acceptance |
|---|---|---|
| SEC-001A | Block clear-text WebDAV credentials | HTTP WebDAV/Alist endpoints with username, password, or credential reference are rejected in UI, persistence, and adapter layers before an Authorization header can be created. Injected credential-free loopback transports remain testable. |
| SEC-001B | Enforce production anonymous-HTTP policy | HTTPS is the default. Anonymous HTTP is limited to explicitly authorized local-network sources; public HTTP is rejected, and unsafe saved entries have an explicit migration result. |
| SEC-002 | Narrow ATS | Global arbitrary loads are removed; any retained local-network exception is the narrowest platform-supported entitlement and passes archive validation. |
| SEC-003 | Isolate remote sessions | Remote sessions use controlled ephemeral configuration without shared cookies, URL cache, or credential storage. |
| SEC-004 | Protect redirects and headers | HTTPS-to-HTTP downgrade is rejected; cross-origin redirects strip Authorization, Cookie, validators, and sensitive custom headers for PROPFIND/HEAD/GET/Range. |
| SEC-005 | Add privacy manifest and log review | Required Reason APIs are declared; archive validation passes; diagnostics contain no credentials or signed URLs. |
| SEC-006 | Review file and credential protection | Keychain accessibility and cached/downloaded file protection are explicit and covered by lifecycle tests. |

### 5.2 Observability And Performance Gates (`OBS`)

| ID | Deliverable | Acceptance |
|---|---|---|
| OBS-001A | Add directory and preview signposts | Directory list, preview queue, and preview render intervals have balanced success/failure/cancelled outcomes and contain no private paths, IDs, or URLs. |
| OBS-001B | Complete content and viewer signposts | Metadata, body, decode, viewer-ready, media-ready, and seek intervals include duration, outcome, source kind, cache state, and byte count without private paths or URLs. |
| OBS-002 | Capture URLSession task metrics | Tests and diagnostics can report redirect count, request count, TTFB, transferred bytes, and protocol. |
| OBS-003 | Add deterministic performance fixtures | Fixtures model TTFB, bandwidth, chunked responses, jitter, cancellation, HEAD 405, ignored Range, and mid-stream failure. |
| OBS-004 | Establish CI and device baselines | Simulator CI enforces deterministic counts and relative regressions; a recorded reference device enforces Release-mode median/p95, RSS, disk IO, and main-thread stalls. |
| OBS-005 | Add MetricKit ingestion | Version-level hang, launch, CPU, memory, and disk payloads are parsed, privacy-safe, aggregated, and fixture-tested. |

### 5.3 Request And Directory Loading (`LOAD`)

| ID | Deliverable | Acceptance |
|---|---|---|
| LOAD-001 | Connect only the selected source | Entering Browse does not connect or list unselected sources. |
| LOAD-002 | Reuse WebDAV directory metadata | Only authoritative fields from a valid Depth 1 snapshot are reused; missing revision/range evidence is verified. DAV image/PDF/text preview then needs one body GET, identical concurrent probes coalesce, and disk hits use zero requests. |
| LOAD-003 | Add directory snapshot LRU with stale-while-revalidate | Back navigation displays cached items without an empty state. TTL is 30 s, capacity is 20 directories per source and 8 MiB total metadata; fresh hits make no request and stale refresh cannot overwrite a newer path. |
| LOAD-004 | Make preview scheduling viewport-aware | Priority is viewer open > visible preview > prefetch; off-screen work stops within 200 ms with at most 64 KiB residual transfer; cellular preview policy is configurable. |
| LOAD-005 | Start preview deadline after admission | Queue time does not consume the render deadline. Only `responseTooLarge` and `capabilityUnavailable` are negatively cached for five minutes, keyed by revision, with a 512-entry cap. |
| LOAD-006 | Read text preview prefixes | Large range-capable text reads at most 64 KiB and handles BOM/multibyte truncation safely. |
| LOAD-007 | Stream online Range media early | Online, Range-capable media larger than the dedicated 4 MiB fast-path threshold avoids a full body GET before playback; exactly 4 MiB, offline, unknown-size, and non-Range behavior stays unchanged until separately measured. |
| LOAD-008A | Move text decoding off the main actor | Decoding has deterministic encoding/binary tests and creates no >100 ms reference-device stall. |
| LOAD-008B | Move image validation/downsampling off the main actor | Validation decodes once, enforces pixel budget, and creates no >100 ms reference-device stall. |
| LOAD-008C | Move PDF preparation off the main actor | PDF is parsed once through a file-backed payload and creates no >100 ms reference-device stall. |
| LOAD-008D | Move Markdown parsing off the main actor | Attributed parsing is cached per revision and creates no >100 ms reference-device stall. |
| LOAD-009 | Enforce the current PROPFIND safety limit during transfer | As an interim guard, responses over 2 MiB are cancelled during transfer; retained memory is at most the limit plus one transport chunk. `LOAD-010` later removes this compatibility ceiling safely. |
| LOAD-010 | Scale directory and index queries | Local/index results batch and fetch-limit 10,000 entries; WebDAV streams/parses up to 10,000 entries or 16 MiB with bounded memory and an actionable over-limit result. |
| LOAD-011 | Reuse HTTP discovery and propagate revisions | Initial HTTP connect metadata is reused by first preview; trustworthy discovered revisions update current list state and enable cross-session cache hits. |
| LOAD-012 | Share bodies and optimize cached opens | Row preview and viewer share same-revision content; cached online open performs at most one conditional validation and zero body GETs. |

### 5.4 Format Resolution And Viewers (`FMT`)

| ID | Deliverable | Acceptance |
|---|---|---|
| FMT-001 | Introduce one `ResolvedContentType` service | Sources, filters, previews, and viewers consume one resolution result with evidence and confidence. |
| FMT-002 | Add bounded signature sniffing | Incorrect generic MIME does not hide a strong extension/signature; suspicious conflicts remain safe and diagnosable. |
| FMT-003 | Implement Quick Look, Share, and Open In | Office, iWork, archives, and supported unknown files open through a real system fallback; every visible action works. |
| FMT-004 | Support unknown-length bounded materialization | Chunked/Files Provider resources stream to a size-limited temporary file with <=8 MiB working memory, disk-space preflight, cancellation cleanup, and zero orphan files. |
| FMT-005 | Improve text encoding detection | MIME charset, UTF BOMs, GB18030/GBK, Big5, Shift-JIS, and binary rejection have fixtures and consistent preview/full decoding. |
| FMT-006 | Validate container and codec support | Unsupported MKV/codec combinations fail before presenting playback controls and offer Open In. |
| FMT-007 | Use file-backed PDF and image pipelines | A 1,000-page PDF opens without a whole-file `Data`; a 48 MP image preview adds <=64 MiB RSS and reads/transfers <=8 MiB where the source supports ranges or thumbnails. |

### 5.5 Cache, Range, And Offline (`CACHE`)

| ID | Deliverable | Acceptance |
|---|---|---|
| CACHE-001 | Add content-cache hard quota and LRU | Initial defaults are 1 GiB total and 512 MiB per source, configurable downward; size accounting is incremental and users can inspect/delete entries. |
| CACHE-002 | Batch preview manifest access updates | A cache hit does not synchronously rewrite the full manifest; one viewport causes at most one batched persistence update. |
| CACHE-003 | Publish viewer before persistence | Cache writes and offline projection refresh do not block first visible content. |
| CACHE-004 | Add session range cache and coalescing | Overlapping requests share 1 MiB aligned memory blocks and in-flight work; duplicate transferred bytes remain below 5%; disk format is deferred until measured. |
| CACHE-005 | Add read-ahead with network awareness | Sequential playback prefetches bounded blocks and stops promptly on cancellation or constrained networks. |
| CACHE-006 | Build a durable offline download model | Downloads use Application Support, full metadata, checksum, explicit status, quota, retry, and background transfer semantics. |
| CACHE-007 | Make cache startup and offline projection incremental | 10,000 manifest entries restore in <=150 ms on the reference device without startup-path per-file `stat`; open does not rescan all offline candidates. |

### 5.6 App Quality And Release (`QUAL`)

| ID | Deliverable | Acceptance |
|---|---|---|
| QUAL-001 | Remove Swift concurrency warnings | Debug and Release build with strict concurrency and warnings-as-errors. |
| QUAL-002 | Replace startup fatal error with recovery | Persistence failure shows a recovery/export/rebuild path; one corrupt record cannot hide other sources. |
| QUAL-003 | Separate application and scene state | Two windows have independent tab, navigation, search, and selected-source state. |
| QUAL-004 | Govern foreground/background work | Directory, preview, and indexing tasks pause/cancel in background while permitted audio playback remains correct. |
| QUAL-005 | Resolve placeholder controls | Every visible control is implemented, clearly disabled, or removed from release UI. |
| QUAL-006 | Add UI and accessibility regression coverage | Core flows pass on iPhone/iPad, large Dynamic Type, VoiceOver, Reduce Motion, rotation, and split view. |
| QUAL-007 | Make external integration tests truthful | Missing real-service configuration reports skipped/not-run rather than passed. |

### 5.7 Task Control Metadata

Priority definitions:

- P0: release or credential blocker (`SEC-001A/001B/002..004`).
- P1: critical loading, format fallback, bounded storage, startup recovery, warnings, and truthful integration tests (`OBS-001A/001B/002..005`, `LOAD-001..012`, `FMT-001..007`, `CACHE-001..004/007`, `QUAL-001/002/004/005/007`).
- P2: durable offline expansion, multi-window, accessibility breadth, and long-horizon release scale (`SEC-005/006`, `CACHE-005/006`, `QUAL-003/006`).

Owner roles and target releases:

| Prefix | Owner role | Target | Required evidence |
|---|---|---|---|
| SEC | Platform/security | Phase 1 for P0; Phase 2 otherwise | Unit/integration tests, archive validation, sanitized request trace |
| OBS | Performance | Phase 1 | `xcresult`, metrics fixture, baseline report |
| LOAD | Sources/performance | Phase 1 except LOAD-008A..D and LOAD-010 | Request ledger, focused tests, before/after metrics |
| FMT | Viewer/compatibility | Phase 2 | Format matrix fixtures, UI/system-preview evidence |
| CACHE | Cache/offline | Phase 2 except CACHE-005/006 | Migration/restart/corruption tests, size and IO evidence |
| QUAL | App/release | Phase 1-3 as listed | Build/analyze/UI/accessibility evidence |

Mandatory dependency graph:

- `OBS-001A/001B/002/003 -> initial baseline -> LOAD/CACHE performance changes -> OBS-004`.
- `SEC-001A -> SEC-001B -> SEC-002/003/004`; security implementation and tests land separately from loading changes.
- `OBS-002/003 -> LOAD-002/004/009/011/012`; `LOAD-003 -> LOAD-010`.
- `FMT-001/002 -> FMT-003..007`; `CACHE-001 -> CACHE-004/006/007`; `CACHE-004 -> CACHE-005`.
- `QUAL-002 + CACHE-001 -> CACHE-006`.

## 6. Delivery Phases

### Phase 0 - Baseline And Governance

- Publish this plan and the task tracker.
- Preserve the passing correctness baseline.
- Add reproducible build/test commands and record the first performance measurements.

### Phase 1 - Release Blockers And Critical-Path Wins (0-2 weeks)

`SEC-001A/001B/002..004`, `OBS-001A/001B/002..005`, `LOAD-001..007/009/011/012`, `CACHE-002..003/007`, and `QUAL-001/007`.

Phase 1 lands as independent, reversible slices rather than one broad PR: security policy/session changes; instrumentation and initial baseline; media strategy; source connection; text prefix preview; bounded PROPFIND; preview deadline/negative cache; directory snapshot; metadata/body reuse. Range disk caching and viewer payload redesign are excluded.

### Phase 2 - Unified Formats And Bounded Storage (3-6 weeks)

`FMT-001..007`, `CACHE-001/004`, `SEC-005..006`, `QUAL-002/004/005`, and the split `LOAD-008A..D` tasks.

### Phase 3 - Durable Offline And Scale (6-12 weeks)

`CACHE-005..006`, `LOAD-010`, `QUAL-003/006`, full device/network matrix, and release validation.

## 7. Performance Service-Level Objectives

These are initial guardrails, not current measured results. `OBS-004` records the exact reference iPhone model, OS build, build configuration, network profile, and event boundaries in `docs/performance-baseline.md`. Use Release builds, five warmups, and at least fifty latency samples; record median and p95. Error/timeout rates use at least 500 attempts and an explicit confidence interval.

| Scenario | Initial gate |
|---|---|
| Warm/back directory navigation | First visible items p95 <= 100 ms |
| Local 1,000 / 10,000 item directory | p95 <= 250 ms / 1.2 s; RSS increase <= 20 / 60 MiB |
| Connected WebDAV 1,000 item directory, normal Wi-Fi | One PROPFIND; p95 <= 1.0 s |
| Cold first visible preview, normal Wi-Fi | p95 <= 1.2 s; full viewport <= 2.5 s |
| Cold first preview, NET-3 profile | p95 <= 4 s; timeout rate < 1% over >=500 attempts |
| Memory / disk preview hit | p95 <= 16 / 100 ms; zero network requests |
| Small viewer open | Local p95 <= 300 ms; normal remote p95 <= 1.5 s |
| Cached viewer open | p95 <= 250 ms; zero body GET; at most one conditional validation |
| 1 GiB media first frame / 85% seek | Normal p95 <= 2.5 / 1.5 s; weak network <= 6 / 4 s |
| Cancellation | Network and file activity quiesces within 300 ms |
| UI responsiveness | Zero main-thread stalls longer than 100 ms in critical flows |
| Cache | Hard configured limit is never exceeded after an operation settles |

## 8. Required Test Matrix

- Sources: local, Files Provider, HTTP, WebDAV, Alist `/dav/`, signed cross-origin content.
- Networks: NET-0 2 ms/500 Mbps; NET-1 20 ms/100 Mbps; NET-2 80 ms/20 Mbps/0.1% loss; NET-3 250 ms/1.5 Mbps/1% loss/50 ms jitter; offline transition.
- Directories: 100, 1,000, and 10,000 entries; Unicode, long names, deep paths, mixed folders/files; PROPFIND just below and above 2 MiB.
- Files: text 256 KiB/10 MiB, images 12/48 MP and 4/12/50 MiB, PDFs 1/100/1,000 pages, media 50 MiB/1 GiB/10 GiB, Office/iWork/archive, no extension, corrupted/truncated/password-protected samples.
- Protocol faults: chunked/no length, HEAD 405, ignored Range, malformed Content-Range, redirects, stale ETag, mid-stream disconnect, delayed cancellation.
- Cache states: cold, memory hit, disk hit, unknown revision, stale revision, near/over budget, corrupt manifest.
- UI/lifecycle: foreground/background, rapid navigation, rotation, two windows, split view, Dynamic Type, VoiceOver, low-memory warning.

## 9. Change And Release Policy

- Each task or tightly coupled slice lands with tests and updates `TODO.md` in the same commit.
- Security, cache-format, and persistence migrations use feature flags or versioned storage where rollback could strand user data.
- No performance change may weaken path validation, revision checks, redirect stripping, range validation, or cancellation behavior.
- P0 and P1 tasks defined in section 5.7 must be complete before release. Deferred P2 tasks retain the owner role, target phase, and measurable acceptance criteria recorded there and in `TODO.md`.
- Before each push: run focused tests, full simulator tests when shared behavior changed, `xcodebuild analyze`, and `git diff --check`.
- Never include unrelated local workspace or signing changes in optimization commits.

## 10. Definition Of Done

The optimization program is complete when:

- All P0/P1 tracker items are checked with linked tests or measurements.
- Performance SLOs pass on the reference device and weak-network matrix.
- The format matrix records one explicit outcome per case: native, Quick Look, Share/Open In export, intentionally unsupported, or safe recoverable error. Installed third-party app behavior is a device manual check, not an automated guarantee.
- Offline content is durable and bounded, and all caches are inspectable and evictable.
- Debug/Release builds are warning-free; unit, UI, accessibility, lifecycle, and integration gates pass.
- Archive/App Store validation reports no ATS, privacy, entitlement, background mode, signing, or Required Reason API issues.
