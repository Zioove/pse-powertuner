# tests\

Automated test suite for **PSE-PowerTuner**. No Pester, no network, no third-party
modules — just `pwsh` and the PowerShell AST parser.

## Run

```powershell
# from the repo root
pwsh -NoProfile -File tests\Invoke-Tests.ps1
```

Exit code `0` = no failures, `1` = at least one failure. A summary table and a
PASS/FAIL/SKIP count are printed at the end. Typical runtime is **5–10 s**
(static only) or **~10 s** with the runtime group enabled.

### Options

| Switch | Effect |
|---|---|
| *(none)* | Static tests always run. Runtime tests run only when elevated. |
| `-NoRuntime` | Skip the runtime group entirely (pure static run, usable on any machine). |
| `-ForceRuntime` | Run the runtime group even when not elevated. The active scheme is still never touched. |

### Elevation

The runtime group is gated on elevation and **skips loudly** when not elevated:

```
── RUNTIME (needs admin; never touches the active scheme) ─────────────
  !! RUNTIME GROUP SKIPPED: 未提权 / not elevated (re-run from an elevated pwsh, or pass -ForceRuntime)
  SKIP  [R01] Get-Value reads every setting on the active scheme (read-only)
  SKIP  [R02] Write/read-back/restore round trip on a throwaway duplicated scheme
```

A SKIP is never counted as a pass — the total line reports it separately, so a
suite that silently skipped its only write test is visibly different from a
suite that ran it.

### Execution policy

The shipped `.psm1`/`.ps1` files carry a Mark-of-the-Web `Zone.Identifier` (the
repo was extracted from a download) and are unsigned, so on a default
`RemoteSigned` machine `Import-Module` is refused. The runner detects this and
relaxes **`Process` scope only** for its own run; nothing persistent is changed.
If that fails, the module-dependent tests report SKIP with the reason instead of
producing false failures.

---

## What is covered

### Static group — no admin, no system mutation

| ID | Test | What it catches |
|---|---|---|
| `S01` | Every `.ps1`/`.psm1` parses with zero syntax errors | syntax errors, unbalanced braces/strings |
| `S02` | No call to an undefined function | **calls to functions that do not exist** — resolved against local definitions, the imported module's exports, and `Get-Command`; reports "defined elsewhere but not in scope" as a hint |
| `S03` | No call passes an undeclared parameter name | **typo'd / invented parameters** — resolves `FunctionDefinitionAst` param blocks, honours PowerShell prefix matching and common parameters, and flags ambiguous prefixes |
| `S04` | No script-scope call to a function defined later in the same file | use-before-definition in top-level script flow |
| `S05` | Module exports exactly the intended function set | accidental exports, silently dropped exports |
| `S06` | `Set-StrictMode -Version 3.0` smoke test on every read-only getter | uninitialized variables, missing hashtable keys, `.Property` on `$null`; also runs one getter in a clean child `pwsh` |
| `S07` | `$Script:Settings` schema: fields, group membership, status enum | missing/empty `Guid`/`Group`/`Desc`/`V`, unknown `Group`, and **`V` disagreeing with `$Script:Writable`** |
| `S08` | Every GUID in `Settings`/`SubGroup`/`Scheme` is a valid GUID | malformed GUIDs, all-zero GUIDs |
| `S09` | No two setting names share a GUID | copy-paste GUID duplication |
| `S10` | Every profile key exists in `$Script:Settings` | profile references to unknown settings |
| `S11` | Every profile key is in `$Script:Writable` | profiles writing settings the platform rejected |
| `S12` | Each profile's AC/DC key sets match, or the difference is listed | undocumented AC-only/DC-only asymmetry |
| `S13` | Every profile value is numeric and inside the documented range | out-of-range values, values that are not integers |
| `S14` | `Get-ProfileList` and every `ValidateSet` agree with `$Script:Profiles` | adding a profile but forgetting a `ValidateSet` (or vice versa) |
| `S15` | GUIDs in `_ref\Test-PwrApi.ps1` agree with `$Script:Settings` | **GUID drift between the probe tool and the module** |
| `S16` | GUIDs and counts in `_ref\writable-test.csv` agree with the module | CSV/module drift, whitelist entries missing from the CSV |
| `S17` | Every module GUID appears in `_ref\processor-settings.csv` | settings invented from thin air |
| `S18` | Range table covers every setting and matches the OS registry bounds | stale/incomplete range data; cross-checks `ValueMin`/`ValueMax` under `HKLM\…\PowerSettings\<subgroup>\<guid>` where Windows publishes them |
| `S19` | README numeric claims match the code and reference data | **documentation numbers that drifted from reality**, plus internal self-consistency of the claim breakdown; verifies the "powercfg only shows N items" claim by actually running `powercfg /query` |
| `S20` | README "三档差异" table numbers match the profile tables | per-cell table drift against `$Script:Profiles` |
| `S21` | All exported functions use an approved verb | `Import-Module` warnings on every import |
| `S22` | Unknown setting names are rejected without touching the system | `Get-Value`/`Set-Value` failing open on a typo'd name |
| `S23` | Shipped scripts contain no hardcoded absolute local paths | machine-specific paths that break on another box |
| `S24` | No scriptblock is cast to a thread/delegate type | `[Threading.ThreadStart]{…}` — kills the process with an uncatchable `PSInvalidOperationException` ("no runspace available in this thread") |

### Runtime group — needs admin, never mutates the active scheme

| ID | Test | Notes |
|---|---|---|
| `R01` | `Get-Value` on every setting, reporting which are readable | pure read; also flags settings whose declared status (`不可用`) contradicts reality |
| `R02` | Write → read-back → restore round trip | operates **only** on a scheme created via `powercfg /duplicatescheme`, deleted in a `finally` block. Hard-asserts that the throwaway GUID differs from the active scheme, asserts the active scheme is unchanged at the end, and asserts the throwaway scheme is gone. Covers AC and DC paths. |

`R02` is the only test that writes to the system, and it writes to a scheme that
did not exist before the test and does not exist after it.

---

## What is intentionally NOT covered

- **`Apply-Profile` / `New-PowerScheme` / `Export-PowerSnapshot` end-to-end.** These
  clone a scheme, activate it, and write to `%ProgramData%`. Exercising them
  would change the active power scheme and leave artefacts behind, which
  violates the "must not permanently change the system" constraint. Their
  building blocks (`Set-Value`, `Get-Value`, `Invoke-PowerCfg`) are covered
  directly.
- **`Install-PowerTuneTask.ps1`.** Registers real scheduled tasks as `SYSTEM`.
  Covered only statically (parse + command/parameter resolution).
- **`Restore-PowerDefaults`.** Runs `powercfg -restoredefaultschemes`, which
  deletes every non-default power scheme on the machine. Never invoked.
- **`Invoke-PowerBench.ps1` benchmark numbers.** Timings are machine- and
  load-dependent; asserting on them would be flaky. The script's *structure* is
  covered statically (S02/S03/S24), which is what surfaces its defects.
- **PSScriptAnalyzer rules.** PSScriptAnalyzer is not installed and nothing is
  fetched from the network, so the analyzer-style checks that mattered here
  (unapproved verbs, undefined commands, undeclared parameters, hardcoded
  paths, StrictMode compatibility) are reimplemented with the AST parser in
  S02/S03/S06/S21/S23.
- **Performance / throughput regression.** Out of scope for a correctness suite.

---

## Files

| File | Purpose |
|---|---|
| `Invoke-Tests.ps1` | The runner. Self-contained; all AST helpers are defined inside it. |
| `Test-Ranges.psd1` | Known-valid min/max (and where relevant, the allowed enumeration) per setting. Consumed by S13 and S18. |
| `Invoke-MutationCheck.ps1` | Proves the suite can fail. Copies the repo to `$env:TEMP`, injects 22 deliberate defects one at a time, and asserts the expected test ID turns red. Never touches the real repo. |
| `README.md` | This file. |

### About `Test-Ranges.psd1`

Ranges come from two places, both recorded in each entry's `Note`:

- where Windows publishes them, `ValueMin`/`ValueMax` under
  `HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-…\<guid>`
  (S18 cross-checks the file against the live registry, so a wrong number here
  fails the build);
- for enumeration-only settings (boost mode, EPP policy, heterogeneous policy)
  the registry has no numeric bounds, so the documented Windows semantics are
  hardcoded with `Allowed = @(...)`.

`MAXFREQ` legitimately maxes at `4294967295`; the range test compares in
`[int64]` so that does not overflow.

---

## Verified by mutation testing

The suite is validated by injecting 22 deliberate defects into a scratch copy of
the repo and confirming each one turns the corresponding test red — a test that
cannot fail is not a test.

```powershell
pwsh -NoProfile -File tests\Invoke-MutationCheck.ps1
# -> CAUGHT 22/22 mutation(s), exit 0
```

Covered mutations: a syntax error, an undefined function, a function defined in
another file but not in scope, an invented parameter, an ambiguous parameter
prefix, a removed export, a status flag disagreeing with the whitelist, a
whitelist entry removed, a malformed GUID, a duplicated GUID, an unknown profile
key, a profile writing a read-only setting, an undocumented DC-only key, an
out-of-range value, a `ValidateSet` drift, a `_ref` GUID drift, a lying range
table, README count drift, README table drift, an unapproved verb, a hardcoded
absolute path, and a scriptblock cast to a thread delegate.

Note that `Invoke-MutationCheck.ps1` is a development aid, not part of the
pass/fail contract of `Invoke-Tests.ps1`: it re-runs the whole suite 22 times and
therefore takes a few minutes.

## Idempotency

The suite was run three times back to back (static, static, `-ForceRuntime`) and
the machine state was snapshotted before and after. Power scheme list, active
scheme, `%ProgramData%\PSE-PowerTuner\backup` and `\reports` were all unchanged,
no `PSE-DRYRUN`/`PSE-*` scheme was left behind, and the exit code was identical
on every run. Runtime is ~6 s static, ~7 s with the runtime group.

