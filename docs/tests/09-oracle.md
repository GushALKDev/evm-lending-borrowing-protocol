# Oracle: Pyth + Chainlink (Phase 5)

**Suites:** [`PythChainlinkOracleTest`](../../test/unit/PythChainlinkOracle.t.sol) (28 unit) · [`PythChainlinkOracleFuzzTest`](../../test/fuzz/PythChainlinkOracle.t.sol) (3 fuzz) · [`OracleMarketBorrowTest`](../../test/integration/OracleMarketBorrow.t.sol) (2 integration)
**Covers:** roadmap items 5.1 to 5.10 · [Guide 3, Section 5](../03-architecture.md#5-oracle-system-pyth--chainlink)

---

> The oracle is the most security-critical dependency: an inflated collateral price mints unbacked capacity, a deflated one triggers unfair absorbs. Every test here is about one property — the oracle returns a validated `(price18, conf18)` or it reverts, never a degraded price and never a silent fallback to Chainlink.

## Reference feed

Every test builds on one WETH feed, so the arithmetic stays checkable by hand:

```
Pyth:      price 2000e8, conf 2e8, expo -8   → 2000e18 mid, 2e18 conf (10 bps)
Chainlink: answer 2000e8, decimals 8         → 2000e18 anchor (0 deviation)
MAX_STALENESS 60s · MAX_CONFIDENCE_BPS 200 · MAX_DEVIATION_BPS 300 · heartbeat 3600s
```

The Pyth surface is the SDK's [`MockPyth`](../../lib/pyth-sdk-solidity/MockPyth.sol) (real `createPriceFeedUpdateData` + fee-charging `updatePriceFeeds`), so the fee/refund path is exercised for real rather than stubbed. The anchor is [`MockChainlinkFeed`](../../test/mocks/MockChainlinkFeed.sol), a settable `AggregatorV3` stand-in.

> **MockPyth gotcha:** the mock only stores a strictly *newer* `publishTime`, so re-pushing at the current timestamp is silently a no-op — the old price stays and the test asserts against stale data. The `_repushFresh` helper advances one second before re-pushing. This bit the suite during development.

---

## Normalization to 1e18 (5.6)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_normalizesTo1e18`](../../test/unit/PythChainlinkOracle.t.sol#L79) | Pyth `2000e8`, expo `-8` → `2000e18` price and `2e18` conf |
| [`test_getPrice_positiveExpoScalesUp`](../../test/unit/PythChainlinkOracle.t.sol#L85) | A positive expo scales the mantissa *up*: `20 * 10^2 = 2000` still normalizes to `2000e18` |
| [`test_chainlink_nonEightDecimalsNormalize`](../../test/unit/PythChainlinkOracle.t.sol#L96) | An 18-decimal anchor at `$2000` anchors identically to the 8-decimal one |
| [`test_getPrice_revertsOnAnchorOver18Decimals`](../../test/unit/PythChainlinkOracle.t.sol#L356) | A feed reporting more than 18 decimals cannot be normalized: `InvalidConfiguration("decimals")` |

The positive-expo test exists because the target exponent is `18 + expo`: the common case (`expo = -8`) scales down, but the branch that scales up is only reachable with a positive expo and must be pinned separately.

---

## Staleness (5.3, 5.5)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_revertsOnStalePyth`](../../test/unit/PythChainlinkOracle.t.sol#L116) | A Pyth price older than `MAX_STALENESS` reverts `StalePrice` |
| [`test_getPrice_freshAtExactBoundary`](../../test/unit/PythChainlinkOracle.t.sol#L126) | `publishTime + MAX_STALENESS == block.timestamp` is still fresh (the check is strict-less-than) |
| [`test_getPrice_revertsOnStaleAnchor`](../../test/unit/PythChainlinkOracle.t.sol#L133) | An anchor older than its own heartbeat reverts `StaleAnchor`, even with a fresh Pyth price |

The oracle reads the stored Pyth price with `getPriceUnsafe` and applies its *own* `MAX_STALENESS`, not Pyth's `validTimePeriod`, so lending's looser staleness policy governs both the transactional and view paths identically.

---

## Confidence (5.4)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_revertsOnWideConfidence`](../../test/unit/PythChainlinkOracle.t.sol#L147) | conf `$50` on `$2000` = 250 bps > 200 → `ConfidenceTooWide` |
| [`test_getPrice_acceptsConfidenceAtBoundary`](../../test/unit/PythChainlinkOracle.t.sol#L156) | conf `$40` = exactly 200 bps is accepted (the check is strict-greater-than) |

---

## Deviation anchor (5.5)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_revertsOnDeviation`](../../test/unit/PythChainlinkOracle.t.sol#L167) | Anchor `$2100` vs Pyth `$2000` = 476 bps > 300 → `PriceDeviationTooHigh` |
| [`test_getPrice_acceptsWithinDeviation`](../../test/unit/PythChainlinkOracle.t.sol#L176) | Anchor `$2050` = 243 bps is within band, accepted |

Chainlink is **not** a fallback: it only bounds the Pyth price. When it deviates, the read reverts — the protocol never substitutes the anchor for the primary price.

---

## Non-zero price (5.2)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_revertsOnZeroPyth`](../../test/unit/PythChainlinkOracle.t.sol#L187) | A non-positive Pyth price reverts `ZeroPrice` |
| [`test_getPrice_revertsOnNegativeAnchor`](../../test/unit/PythChainlinkOracle.t.sol#L193) | A non-positive Chainlink answer reverts `ZeroPrice` |
| [`test_getPrice_revertsOnUnknownAsset`](../../test/unit/PythChainlinkOracle.t.sol#L199) | An asset with no configured feed reverts `UnknownAsset` |

---

## Fee accounting and refund (5.2)

| Test | Asserts |
| :--- | :------ |
| [`test_updateAndGetPrice_pushesAndValidates`](../../test/unit/PythChainlinkOracle.t.sol#L208) | A pushed update is stored and its validated price returned |
| [`test_updateAndGetPrice_refundsSurplus`](../../test/unit/PythChainlinkOracle.t.sol#L221) | Only the Pyth fee is consumed; the surplus is refunded, and the oracle holds no ETH |
| [`test_updateAndGetPrice_revertsOnInsufficientFee`](../../test/unit/PythChainlinkOracle.t.sol#L235) | `msg.value` below the fee reverts `InsufficientFee` |

---

## Constructor guards (5.7 · INV-12)

The oracle is immutable policy: no owner, no setters. Every feed is fixed at construction, and each config field is guarded.

| Test | Guard |
| :--- | :---- |
| [`test_constructor_revertsOnZeroPyth`](../../test/unit/PythChainlinkOracle.t.sol#L248) | non-zero Pyth address |
| [`test_constructor_revertsOnLengthMismatch`](../../test/unit/PythChainlinkOracle.t.sol#L255) | `assets.length == configs.length` |
| [`test_constructor_revertsOnZeroFeedId`](../../test/unit/PythChainlinkOracle.t.sol#L263) | non-zero Pyth feed id |
| [`test_constructor_revertsOnDuplicateAsset`](../../test/unit/PythChainlinkOracle.t.sol#L276) | no duplicate asset |
| [`test_constructor_revertsOnZeroStaleness`](../../test/unit/PythChainlinkOracle.t.sol#L302) | `maxStaleness > 0` |
| [`test_constructor_revertsOnConfOutOfRange`](../../test/unit/PythChainlinkOracle.t.sol#L311) | `0 < maxConfidenceBps < 10_000` |
| [`test_constructor_revertsOnDeviationOutOfRange`](../../test/unit/PythChainlinkOracle.t.sol#L320) | `0 < maxDeviationBps < 10_000` |
| [`test_constructor_revertsOnZeroChainlinkFeed`](../../test/unit/PythChainlinkOracle.t.sol#L329) | non-zero anchor address |
| [`test_constructor_revertsOnZeroHeartbeat`](../../test/unit/PythChainlinkOracle.t.sol#L337) | `heartbeat > 0` |
| [`test_constructor_revertsOnZeroAsset`](../../test/unit/PythChainlinkOracle.t.sol#L344) | non-zero asset address |

[`test_getFeedConfig_returnsWiring`](../../test/unit/PythChainlinkOracle.t.sol#L365) confirms the stored wiring is readable.

---

## Fuzz (5.10)

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_normalizesAcrossExpo`](../../test/fuzz/PythChainlinkOracle.t.sol#L52) | For any expo in `[-18, 0]`, a mantissa normalizes to exactly `mantissa * 10^(18+expo)` |
| [`testFuzz_confidenceGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L68) | The confidence gate admits exactly `conf/price <= MAX_CONFIDENCE_BPS` and rejects above |
| [`testFuzz_deviationGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L87) | The deviation gate admits exactly `\|pyth-anchor\|/anchor <= MAX_DEVIATION_BPS` and rejects above |

Each gate fuzz recomputes the threshold independently and asserts accept-or-revert against it, so the boundary is proven inclusive on the accept side and exclusive on the reject side across the whole range.

---

## Market integration (5.8)

The real oracle wired into a real market, proving the payable price path end to end against the real fee/refund logic — not just the mock.

| Test | Asserts |
| :--- | :------ |
| [`test_borrowAgainstRealOracle_succeedsAndRefunds`](../../test/integration/OracleMarketBorrow.t.sol#L114) | A collateralized borrow (10 WETH → 10,000 USDC) pushes both feeds, consumes only `4 wei` of Pyth fee (2 feeds × 2 asset-calls), refunds the surplus, and leaves both the market and the oracle holding no ETH |
| [`test_borrowRevertsWhenUnderfunded`](../../test/integration/OracleMarketBorrow.t.sol#L136) | A borrow with `msg.value = 0` reverts: it cannot cover even the first per-asset Pyth fee |

> **The `receive()` gap.** The market forwards `address(this).balance` to the oracle once per asset; the real oracle consumes only the fee and refunds the surplus *back to the market* for its next per-asset call. The Phase 4 market had no `receive()`, so the refund reverted `RefundFailed` — a latent bug the mock never surfaced because Phase 4 tests sent no ETH and the mock only refunds when `msg.value > 0`. This integration test is what caught it; the fix is a `receive()` on the market. No other market change was needed: the `IPriceOracle` shape is unchanged, so `_pushPrices` and `_refundExcessValue` were already correct.
