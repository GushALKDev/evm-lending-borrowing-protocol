# Static Analysis (Phase 8)

**Tools:** Slither 0.11.3 · Aderyn 0.6.8
**Covers:** roadmap item 8.8 (static analysis with no criticals) · [Guide 6](../06-security.md)
**Config:** [`slither.config.json`](../../slither.config.json) · run scoped to `src/` (deps, tests, and scripts filtered out)

---

> Both tools were run against `src/`. Neither found a real vulnerability. Slither reported 51 results and Aderyn 2 High + 12 Low; every one is either genuine dead code (now removed) or a documented false positive inherent to the oracle-push architecture. After remediation Slither reports **0 results**. This page is the triage: what was fixed, and why each remaining flag is not a defect.

## Running

```bash
slither .                       # uses slither.config.json
aderyn --src src                # writes report.md (gitignored)
```

Slither reads `slither.config.json` (path filters + the intentional-detector exclusions justified below). Aderyn has no inline-suppression mechanism, so its two High findings persist on each run; they are the same false positives triaged here.

## Fixed: genuine dead code

| Item | Location | Action |
| :--- | :------- | :----- |
| `PRICE_SCALE` constant, never read | `PythChainlinkOracle` | Removed (Slither `unused-state-variable`, Aderyn L-12) |
| `InsufficientBalance` error, never used | `ILendingMarket` | Removed (Aderyn L-10) |
| `NotImplementedYet` error, leftover scaffold | `ILendingMarket` | Removed (Aderyn L-10) |

## False positives, and why

### Reentrancy (Slither `reentrancy-eth`/`-no-eth`/`-events`, Aderyn H-2)

Flagged on `absorb`, `_withdrawBase`, `_withdrawCollateral` (and, for Aderyn, the constructor). The "external call" is `ORACLE.updateAndGetPrice` / `getPrice` — the **immutable** oracle the protocol deploys, not an attacker-controlled address — and every external entry point carries `nonReentrant`. The flagged state writes and events after the call therefore cannot be re-entered. Suppressed inline at each site with a justification comment (`slither-disable-next-line`), keeping the detectors globally active so a genuinely unguarded new site would still surface. Aderyn's constructor instance is a non-issue by definition: no reentrancy is possible before the contract exists, and the flagged "external calls" are `decimals()` / `MAX_CONFIDENCE_BPS()` reads.

### ETH sent to arbitrary user (Slither `arbitrary-send-eth`, Aderyn H-1)

`_refundExcessValue` and the oracle's refund send ETH to `msg.sender`. That is the intended recipient: the refund returns the caller's own unspent `msg.value`. Suppressed inline with a comment.

### Pyth confidence not checked (Slither `pyth-unchecked-confidence`)

The detector flags `getPriceUnsafe` because it does not find a confidence check adjacent to that call. The check exists a few lines below (`confBps` against `MAX_CONFIDENCE_BPS`, after normalization). Suppressed inline where the check is documented.

### Unused return values (Slither `unused-return`)

The market discards the return of `updateAndGetPrice` (it re-reads the freshly stored price through `getPrice`) and discards the `conf` half of `getPrice` where only the mid price is needed. Both are intentional and documented in NatSpec. Excluded via `slither.config.json` rather than annotated at each of the ~9 sites.

### Intentional style / environment detectors

Excluded in `slither.config.json`, each intentional by design:

| Detector | Why excluded |
| :------- | :----------- |
| `naming-convention` | UPPER_CASE immutables are the repo's deliberate convention |
| `timestamp` | The oracle's staleness/heartbeat checks must compare against `block.timestamp` |
| `low-level-calls` | The ETH refund `.call{value:}` is the correct pattern for a value transfer |
| `calls-loop` | The constructor loops over a bounded collateral list; `_pushPrices` over a bounded held-asset set |
| `cyclomatic-complexity` | Constructor validation is inherently branchy (INV-12/INV-13 checks) |
| `solc-version` / `pragma` | Solidity `0.8.26` is pinned on purpose |

## A note on the Slither parsing error

Slither prints `ERROR:ContractSolcParsing: Impossible to generate IR for LendingMarket._accrue`. This is a Slither internal IR-generation limitation on the `fullMulDiv(...).toUint64()` chain in `_accrue`, not a contract defect: Slither still analyzes all 23 contracts and runs all detectors to completion. No action required.

## Outcome

No criticals, no highs, no real medium/low defects remain. Roadmap 8.8 satisfied.
