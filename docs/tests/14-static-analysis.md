# Static Analysis (Phase 8)

**Tools:** Slither 0.11.6 · Aderyn 0.6.8
**Covers:** roadmap item 8.8 (static analysis with no criticals) · [Guide 6](../06-security.md)
**Config:** [`slither.config.json`](../../slither.config.json) · run scoped to `src/` (deps, tests, and scripts filtered out)

---

> Both tools were run against `src/`. Neither found a real vulnerability. Slither reported 51 results and Aderyn 2 High + 12 Low; every one is either genuine dead code (now removed) or a documented false positive inherent to the oracle-push architecture. After remediation Slither reports **0 results**. The current Aderyn run flags **12 detector categories** (2 High, 10 Low, 27 instances), all triaged below: 4 are false positives (the detector's premise does not hold here) and 8 are accurate observations of intended design, style, or an accepted gas cost. None is a vulnerability. This page is the triage: what was fixed, and why each remaining flag is not a defect.

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

Slither flagged `absorb`, `_withdrawBase`, and `_withdrawCollateral`; the current Aderyn run flags only the constructor (3 instances). The "external call" is `ORACLE.updateAndGetPrice` / `getPrice` (the **immutable** oracle the protocol deploys, not an attacker-controlled address), and every external entry point carries `nonReentrant`. The flagged state writes and events after the call therefore cannot be re-entered. Suppressed inline at each site with a justification comment (`slither-disable-next-line`), keeping the detectors globally active so a genuinely unguarded new site would still surface. Aderyn's constructor instance is a non-issue by definition: no reentrancy is possible before the contract exists, and the flagged "external calls" are `decimals()` / `MAX_CONFIDENCE_BPS()` reads.

### ETH sent to arbitrary user (Slither `arbitrary-send-eth`, Aderyn H-1)

`_refundExcessValue` and the oracle's refund send ETH to `msg.sender` (the current Aderyn run flags only the oracle's `updateAndGetPrice`, 1 instance). That is the intended recipient: the refund returns the caller's own unspent `msg.value`. Suppressed inline with a comment.

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

## Aderyn Low findings, current run

Numbering is Aderyn's own for this run (`aderyn --src src`); the High findings are H-1 and H-2 above.

| Finding | Instances | Verdict | Why |
| :------ | --------: | :------ | :-- |
| L-1 Centralization risk | 2 | Intended design | `LendingMarket` is `Ownable2Step` and `withdrawReserves` is `onlyOwner`. The owner is a documented, bounded role: reserves and pause flags only, no parameter or code access ([Guide 6, rows 15 and 16](../06-security.md#3-attack-vectors-and-mitigations)) |
| L-2 Costly operations inside loop | 1 | Accepted (gas) | Accurate: each iteration of the `_seizeCollateral` loop clears one bit of the account's `assetsIn` slot through `_clearAssetIn`, which could be written once after the loop. The loop runs at most once per listed collateral and only inside `absorb`, so the saving does not justify a second code path |
| L-3 Empty block | 1 | Style | The owner branch of `setPauseFlags` is intentionally empty (the owner may set or clear any flag); it keeps the owner, guardian, and stranger cases side by side |
| L-4 Large numeric literal | 2 | Style | `FACTOR_SCALE = 10_000` and `BPS_SCALE = 10_000` are basis-point scales; `10_000` reads as that more clearly than `1e4` |
| L-5 Literal instead of constant | 10 | Style | `10 ** decimals` and the `18` in the oracle's normalization derive a scale from a per-asset value; a named constant would not add meaning |
| L-6 `nonReentrant` is not the first modifier | 1 | False positive | On `withdrawReserves` the modifier before it is `onlyOwner`, which makes no external call, so the order cannot open a reentrancy window |
| L-7 Loop contains `require`/`revert` | 1 | Intended design | In `_seizeCollateral` a price that fails validation must revert the whole absorb; skipping the asset would seize an account at an unverified price ([Guide 6, S2](../06-security.md#s2-oracle-outage-during-a-drawdown)) |
| L-8 State change without event | 1 | Intended design | `accrue()` only advances the indexes; the new values are readable through `getMarketState()`, and every balance-changing action already emits its own event |
| L-9 Unchecked return | 2 | False positive | `_requireListed(asset)` is called for its revert on an unlisted asset; the returned config is not needed at those two sites |
| L-10 Public function not used internally | 2 | Style | `getSupplyRate` and `borrowBalanceOf` are part of the public interface; `public` versus `external` changes nothing for callers |

## A note on the Slither parsing error

Slither prints `ERROR:ContractSolcParsing: Impossible to generate IR for LendingMarket._accrue`. This is a Slither internal IR-generation limitation on the `fullMulDiv(...).toUint64()` chain in `_accrue`, not a contract defect: Slither still analyzes all 23 contracts and runs all detectors to completion. No action required.

## Outcome

No criticals, no highs, no real medium/low defects remain. Roadmap 8.8 satisfied.
