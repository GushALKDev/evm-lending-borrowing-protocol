# Oracle: Pyth + Chainlink (Phase 5)

**Suites:** [`PythChainlinkOracleTest`](../../test/unit/PythChainlinkOracle.t.sol) (31 unit) · [`PythChainlinkOracleFuzzTest`](../../test/fuzz/PythChainlinkOracle.t.sol) (3 fuzz) · [`OracleMarketBorrowTest`](../../test/integration/OracleMarketBorrow.t.sol) (2 integration) · [`OracleMarketLiquidationTest`](../../test/integration/OracleMarketLiquidation.t.sol) (4 integration) · [`OracleFailureModesTest`](../../test/integration/OracleFailureModes.t.sol) (15 integration) · [`ForcedEthRefundTest`](../../test/integration/ForcedEthRefund.t.sol) (9 integration)
**Covers:** roadmap items 5.1 to 5.10, 8.10 · [Guide 3, Section 5](../03-architecture.md#5-oracle-system-pyth--chainlink)

---

> The oracle is the most security-critical dependency: an inflated collateral price mints unbacked capacity, a deflated one triggers unfair absorbs. Every test here is about one property: the oracle returns a validated `(price18, conf18)` or it reverts, never a degraded price and never a silent fallback to Chainlink.

## Reference feed

Every test builds on one WETH feed, so the arithmetic stays checkable by hand:

```
Pyth:      price 2000e8, conf 2e8, expo -8   → 2000e18 mid, 2e18 conf (10 bps)
Chainlink: answer 2000e8, decimals 8         → 2000e18 anchor (0 deviation)
MAX_STALENESS 60s · MAX_CONFIDENCE_BPS 200 · MAX_DEVIATION_BPS 300 · heartbeat 3600s
```

The Pyth surface is the SDK's [`MockPyth`](../../lib/pyth-sdk-solidity/MockPyth.sol) (real `createPriceFeedUpdateData` + fee-charging `updatePriceFeeds`), so the fee/refund path is exercised for real rather than stubbed. The anchor is [`MockChainlinkFeed`](../../test/mocks/MockChainlinkFeed.sol), a settable `AggregatorV3` stand-in.

> **MockPyth gotcha:** the mock only stores a strictly *newer* `publishTime`, so re-pushing at the current timestamp is silently a no-op: the old price stays and the test asserts against stale data. The `_repushFresh` helper advances one second before re-pushing. This bit the suite during development.

---

## Normalization to 1e18 (5.6)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_normalizesTo1e18`](../../test/unit/PythChainlinkOracle.t.sol#L79) | Pyth `2000e8`, expo `-8` → `2000e18` price and `2e18` conf |
| [`test_getPrice_positiveExpoScalesUp`](../../test/unit/PythChainlinkOracle.t.sol#L85) | A positive expo scales the mantissa *up*: `20 * 10^2 = 2000` still normalizes to `2000e18` |
| [`test_chainlink_nonEightDecimalsNormalize`](../../test/unit/PythChainlinkOracle.t.sol#L96) | An 18-decimal anchor at `$2000` anchors identically to the 8-decimal one |
| [`test_getPrice_revertsOnAnchorOver18Decimals`](../../test/unit/PythChainlinkOracle.t.sol#L389) | A feed reporting more than 18 decimals cannot be normalized: `InvalidConfiguration("decimals")` |

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
| [`test_getPrice_revertsOnConfidenceJustAboveLimit`](../../test/unit/PythChainlinkOracle.t.sol#L163) | conf `$40.10` = 200.5 bps reverts `ConfidenceTooWide(weth, 201, 200)`: half a basis point over the limit is over the limit |

The check rejects when `conf * 10_000 > MAX_CONFIDENCE_BPS * price`, by cross-multiplication with no division, and the reported bps rounds up so it is above the limit whenever the check fires. The previous form compared a floored `conf * 10_000 / price` and let 200.5 bps through a 200 bps limit; `test_getPrice_revertsOnConfidenceJustAboveLimit` fails against it.

---

## Deviation anchor (5.5)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_revertsOnDeviation`](../../test/unit/PythChainlinkOracle.t.sol#L177) | Anchor `$2100` vs Pyth `$2000` = 476.19 bps > 300 → `PriceDeviationTooHigh`, reported rounded up as 477 |
| [`test_getPrice_revertsOnDeviationJustAboveLimit`](../../test/unit/PythChainlinkOracle.t.sol#L186) | Pyth `$2060.10` vs anchor `$2000` = 300.5 bps reverts `PriceDeviationTooHigh(weth, 301, 300)` |
| [`test_getPrice_acceptsDeviationAtBoundary`](../../test/unit/PythChainlinkOracle.t.sol#L198) | Pyth `$2060` vs anchor `$2000` = exactly 300 bps is accepted |
| [`test_getPrice_acceptsWithinDeviation`](../../test/unit/PythChainlinkOracle.t.sol#L207) | Anchor `$2050` = 243 bps is within band, accepted |

The deviation check has the same exact form, rejecting when `|pyth - anchor| * 10_000 > MAX_DEVIATION_BPS * anchor`, with the reported bps rounded up. `test_getPrice_revertsOnDeviationJustAboveLimit` fails against the previous floored form.

Chainlink is **not** a fallback: it only bounds the Pyth price. When it deviates, the read reverts; the protocol never substitutes the anchor for the primary price.

---

## Non-zero price (5.2)

| Test | Asserts |
| :--- | :------ |
| [`test_getPrice_revertsOnZeroPyth`](../../test/unit/PythChainlinkOracle.t.sol#L218) | A non-positive Pyth price reverts `ZeroPrice` |
| [`test_getPrice_revertsOnNegativeAnchor`](../../test/unit/PythChainlinkOracle.t.sol#L224) | A non-positive Chainlink answer reverts `ZeroPrice` |
| [`test_getPrice_revertsOnUnknownAsset`](../../test/unit/PythChainlinkOracle.t.sol#L230) | An asset with no configured feed reverts `UnknownAsset` |

---

## Fee accounting and refund (5.2)

| Test | Asserts |
| :--- | :------ |
| [`test_updateAndGetPrice_pushesAndValidates`](../../test/unit/PythChainlinkOracle.t.sol#L239) | A pushed update is stored and its validated price returned |
| [`test_updateAndGetPrice_refundsSurplus`](../../test/unit/PythChainlinkOracle.t.sol#L252) | Only the Pyth fee is consumed; the surplus is refunded, and the oracle holds no ETH |
| [`test_updateAndGetPrice_revertsOnInsufficientFee`](../../test/unit/PythChainlinkOracle.t.sol#L266) | `msg.value` below the fee reverts `InsufficientFee` |

---

## Constructor guards (5.7 · INV-12)

The oracle is immutable policy: no owner, no setters. Every feed is fixed at construction, and each config field is guarded.

| Test | Guard |
| :--- | :---- |
| [`test_constructor_revertsOnZeroPyth`](../../test/unit/PythChainlinkOracle.t.sol#L279) | non-zero Pyth address |
| [`test_constructor_revertsOnLengthMismatch`](../../test/unit/PythChainlinkOracle.t.sol#L286) | `assets.length == configs.length` |
| [`test_constructor_revertsOnZeroFeedId`](../../test/unit/PythChainlinkOracle.t.sol#L294) | non-zero Pyth feed id |
| [`test_constructor_revertsOnDuplicateAsset`](../../test/unit/PythChainlinkOracle.t.sol#L307) | no duplicate asset |
| [`test_constructor_revertsOnZeroStaleness`](../../test/unit/PythChainlinkOracle.t.sol#L334) | `maxStaleness > 0` |
| [`test_constructor_revertsOnConfOutOfRange`](../../test/unit/PythChainlinkOracle.t.sol#L343) | `0 < maxConfidenceBps < 10_000` |
| [`test_constructor_revertsOnDeviationOutOfRange`](../../test/unit/PythChainlinkOracle.t.sol#L352) | `0 < maxDeviationBps < 10_000` |
| [`test_constructor_revertsOnZeroChainlinkFeed`](../../test/unit/PythChainlinkOracle.t.sol#L361) | non-zero anchor address |
| [`test_constructor_revertsOnZeroHeartbeat`](../../test/unit/PythChainlinkOracle.t.sol#L369) | `heartbeat > 0` |
| [`test_constructor_revertsOnZeroAsset`](../../test/unit/PythChainlinkOracle.t.sol#L377) | non-zero asset address |

[`test_getFeedConfig_returnsWiring`](../../test/unit/PythChainlinkOracle.t.sol#L398) confirms the stored wiring is readable.

---

## Fuzz (5.10)

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_normalizesAcrossExpo`](../../test/fuzz/PythChainlinkOracle.t.sol#L52) | For any expo in `[-18, 0]`, a mantissa normalizes to exactly `mantissa * 10^(18+expo)` |
| [`testFuzz_confidenceGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L73) | For any price, conf, and expo in `[-18, 0]`, the oracle accepts if and only if `conf * 10_000 <= MAX_CONFIDENCE_BPS * price`, and a rejection reports `ceil(conf * 10_000 / price)` |
| [`testFuzz_deviationGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L105) | For any price from $1 to $1,000,000 and anchor on either side, the oracle accepts if and only if `\|pyth - anchor\| * 10_000 <= MAX_DEVIATION_BPS * anchor`, and a rejection reports `ceil(\|pyth - anchor\| * 10_000 / anchor)` |

Each gate fuzz recomputes the condition by cross-multiplication in plain integer arithmetic and asserts accept-or-revert, with the exact error payload, against it. Half the runs draw the input from a window of `[MAX - 1, MAX + 2]` bps around the limit, a third of which lies strictly inside `(MAX, MAX + 1)`, the band where a floored ratio would pass; the other half draw from the whole range.

---

## Market integration (5.8)

The real oracle wired into a real market, proving the payable price path end to end against the real fee/refund logic, not just the mock.

| Test | Asserts |
| :--- | :------ |
| [`test_borrowAgainstRealOracle_succeedsAndRefunds`](../../test/integration/OracleMarketBorrow.t.sol#L114) | A collateralized borrow (10 WETH → 10,000 USDC) pushes both feeds, consumes only `4 wei` of Pyth fee (2 feeds × 2 asset-calls), refunds the surplus, and leaves both the market and the oracle holding no ETH |
| [`test_borrowRevertsWhenUnderfunded`](../../test/integration/OracleMarketBorrow.t.sol#L136) | A borrow with `msg.value = 0` reverts: it cannot cover even the first per-asset Pyth fee |

> **The `receive()` gap.** The market forwards `address(this).balance` to the oracle once per asset; the real oracle consumes only the fee and refunds the surplus *back to the market* for its next per-asset call. The Phase 4 market had no `receive()`, so the refund reverted `RefundFailed`, a latent bug the mock never surfaced because Phase 4 tests sent no ETH and the mock only refunds when `msg.value > 0`. This integration test is what caught it; the fix is a `receive()` on the market. No other market change was needed: the `IPriceOracle` shape is unchanged, so `_pushPrices` and `_refundExcessValue` were already correct.

## Liquidation integration (8.10)

The same real oracle behind the two liquidation entry points. Nothing else reaches them with a real fee: the fork suite cannot move a price with a cached VAA, and every other layer prices through `MockPriceOracle`, which charges nothing. Alice borrows 15,000 USDC against 10 WETH at $2,000; each test crashes WETH to $1,700 with a fresh signed Pyth update one second later plus a matching Chainlink anchor, so liquidation capacity drops to `10 * 1,702 * 85% = $14,467` and only the absorb's own push makes her eligible. Rates are zeroed so every settlement amount is exact.

| Test | Asserts |
| :--- | :------ |
| [`test_absorbAgainstRealOracle_seizesSettlesAndRefunds`](../../test/integration/OracleMarketLiquidation.t.sol#L138) | Before the push, `isLiquidatable` reverts `PriceDeviationTooHigh` (stored $2,000 Pyth against the $1,700 anchor, 1,764.7 bps, reported as 1,765), so only the absorb's own update prices her. Credit `10 * 1,700 * 93% = 15,810` against 15,000 debt: debt wiped, 810 USDC surplus credited as supply, 10 WETH moved to seized inventory, reserves down by exactly 15,810; only `4 wei` of Pyth fee consumed, and market and oracle hold no ETH |
| [`test_absorbRevertsWhenUnderfunded`](../../test/integration/OracleMarketLiquidation.t.sol#L166) | `absorb` with `msg.value = 0` reverts `InsufficientFee(0, 2)` on the first per-asset push |
| [`test_buyCollateralAgainstRealOracle_sellsInventoryAndRefunds`](../../test/integration/OracleMarketLiquidation.t.sol#L177) | After the absorb, 10,000 USDC buys WETH at the 3.5%-discounted ask of $1,640.50 through `_pushBuyPrices`: collateral received equals the quote, inventory drawn down by it, reserves up by exactly the base paid; only `4 wei` consumed and no ETH retained |
| [`test_buyCollateralRevertsWhenUnderfunded`](../../test/integration/OracleMarketLiquidation.t.sol#L204) | `buyCollateral` with `msg.value = 0` reverts `InsufficientFee(0, 2)` |

> **Mutation check.** Removing `_refundExcessValue()` from `absorb` and `buyCollateral` fails three of the four tests (the spent-ETH assertions, and the underfunded buy, which the stranded absorb budget then silently funds).

## Failure modes inside the market

The unit suite proves each check reverts in the oracle; this suite proves what that revert does to the market's own entry points, through the real `PythChainlinkOracle` over `MockPyth` (60 s staleness, 200 bps confidence, 300 bps deviation; 3,600 s heartbeat on the collateral anchors, 86,400 s on USDC). alice holds 10 WETH against 15,000 USDC of debt; carol holds 10 WETH and 1 WBTC against 20,000, so WBTC is the collateral whose broken feed spills over onto the rest of her position. Every expected revert pins the asset and the values in the error.

| Test | Asserts |
| :--- | :------ |
| [`test_stalePrice_blocksBorrow`](../../test/integration/OracleFailureModes.t.sol#L187) | 61 s after the last WETH publish, a borrow carrying a base-only update reverts `StalePrice(weth, t0, 60)` |
| [`test_stalePrice_blocksAbsorbUntilAFreshUpdate`](../../test/integration/OracleFailureModes.t.sol#L200) | An absorbable account cannot be absorbed on a stale stored price; the same call with a fresh update succeeds. The one failure the caller can cure |
| [`test_stalePrice_blocksBuyCollateral`](../../test/integration/OracleFailureModes.t.sol#L218) | `buyCollateral` reverts `StalePrice` on the asset being bought |
| [`test_staleAnchor_blocksBorrow`](../../test/integration/OracleFailureModes.t.sol#L235) | Past the WETH heartbeat a borrow reverts `StaleAnchor(weth, t0, 3600)` even with a fresh Pyth update attached |
| [`test_staleAnchor_blocksAbsorbDespiteAFreshUpdate`](../../test/integration/OracleFailureModes.t.sol#L246) | A fresh signed update does not cure a stale anchor: the absorb reverts until Chainlink itself updates, then succeeds |
| [`test_staleAnchor_blocksBuyCollateral`](../../test/integration/OracleFailureModes.t.sol#L261) | `buyCollateral` reverts `StaleAnchor` on the asset being bought |
| [`test_confidenceTooWide_blocksBorrow`](../../test/integration/OracleFailureModes.t.sol#L277) | A $50 band on $2,000 (250 bps) reverts the borrow `ConfidenceTooWide(weth, 250, 200)` |
| [`test_confidenceTooWide_blocksAbsorb`](../../test/integration/OracleFailureModes.t.sol#L291) | A $40 band on the $1,700 crash (235.29 bps, reported rounded up as 236) reverts the absorb |
| [`test_confidenceTooWide_blocksBuyCollateral`](../../test/integration/OracleFailureModes.t.sol#L305) | The same band reverts `buyCollateral` |
| [`test_brokenCollateralFeed_blocksBorrowForAnAccountHoldingIt`](../../test/integration/OracleFailureModes.t.sol#L332) | With only the WBTC anchor stale, carol's borrow reverts `StaleAnchor(wbtc, ...)` although her WETH alone would cover it |
| [`test_brokenCollateralFeed_blocksWithdrawingOtherCollateral`](../../test/integration/OracleFailureModes.t.sol#L342) | Withdrawing WETH, whose feed is healthy, reverts on the WBTC anchor |
| [`test_brokenCollateralFeed_blocksAbsorbOfTheWholeAccount`](../../test/integration/OracleFailureModes.t.sol#L355) | carol is absorbable on a WETH crash alone, yet the absorb reverts on WBTC until its anchor updates, then seizes both assets: there is no partial absorb |
| [`test_brokenCollateralFeed_leavesAccountsWithoutItUnaffected`](../../test/integration/OracleFailureModes.t.sol#L375) | alice, who holds no WBTC, borrows normally through the same outage |
| [`test_brokenCollateralFeed_debtorCanRepayThenExitTheBrokenAsset`](../../test/integration/OracleFailureModes.t.sol#L387) | A partial WBTC withdrawal reverts, but after a repay (no oracle) carol withdraws all of it: zeroing the balance clears the `assetsIn` bit before the health check, so WBTC is no longer priced |
| [`test_outage_exitPathsStayOpen`](../../test/integration/OracleFailureModes.t.sol#L411) | With every anchor stale and no update at all, a supplier withdraws, a borrower repays in full with the sentinel, and the now debt-free account withdraws its collateral |

> **Mutation check.** Moving `_clearAssetIn` after the health check in `_withdrawCollateral` fails `test_brokenCollateralFeed_debtorCanRepayThenExitTheBrokenAsset` with `StaleAnchor(wbtc, ...)`: the exit through a full withdrawal of the broken asset depends on that ordering.

## Refund with forced ETH

ETH can reach the market outside any call, through a `selfdestruct` or a transfer before deployment. The refund used to sweep the market's whole balance to the caller, so with forced ETH present any caller that cannot receive ETH (most liquidators are contracts) reverted `RefundFailed`, even when paying the exact fee. The refund is now `msg.value` minus the Pyth fees paid in the call, only the caller's unspent value is forwarded to the oracle, and no call is made when nothing is left. Real `PythChainlinkOracle` over `MockPyth` at 1 wei per update; each entry point pushes a two-feed blob twice, so the exact fee is 4 wei.

| Test | Asserts |
| :--- | :------ |
| [`test_forcedBySelfdestruct_contractBorrowsWithExactFee`](../../test/integration/ForcedEthRefund.t.sol#L171) | 1 ETH forced in by `selfdestruct`; a contract with no `receive` borrows paying 4 wei; the forced ETH stays in the market |
| [`test_forcedByDeal_contractBorrowsWithExactFee`](../../test/integration/ForcedEthRefund.t.sol#L177) | The same with the market balance set by `vm.deal` |
| [`test_forcedBySelfdestruct_contractAbsorbsWithExactFee`](../../test/integration/ForcedEthRefund.t.sol#L183) | The contract absorbs an underwater account paying 4 wei |
| [`test_forcedByDeal_contractAbsorbsWithExactFee`](../../test/integration/ForcedEthRefund.t.sol#L189) | The same with `vm.deal` |
| [`test_forcedBySelfdestruct_contractBuysCollateralWithExactFee`](../../test/integration/ForcedEthRefund.t.sol#L195) | After an absorb, ETH is forced in and the contract buys the seized WETH paying 4 wei |
| [`test_forcedByDeal_contractBuysCollateralWithExactFee`](../../test/integration/ForcedEthRefund.t.sol#L202) | The same with `vm.deal` |
| [`test_excessIsRefundedExactlyToAnEoa`](../../test/integration/ForcedEthRefund.t.sol#L215) | An EOA sending 0.5 ETH spends exactly 4 wei; the forced ETH is neither refunded nor spent, and reserves move by the absorb credit only |
| [`test_forcedEthDoesNotPayTheCallersFee`](../../test/integration/ForcedEthRefund.t.sol#L231) | With forced ETH present, an absorb sending no value reverts `InsufficientFee(0, 2)`: forced ETH is not a fee budget |
| [`test_overpayingContractStillRevertsWithItsOwnExcess`](../../test/integration/ForcedEthRefund.t.sol#L242) | A rejecting contract that overpays reverts `RefundFailed` carrying exactly its own excess (0.5 ETH minus 4 wei), not the forced balance |

Before the fix all nine failed: six with `RefundFailed(caller, 1 ether)`, the EOA test with an underflow (it received the forced ETH), the fee test because the forced ETH paid the fee, and the overpaying test with the forced ETH included in the amount. Three mutants each fail at least one of them: a call made when the refund is zero (all six exact-fee tests and the fork test fail with `RefundFailed(caller, 0)`), the whole balance forwarded to the oracle (the fee test), and the refund taken as the whole balance (eight of the nine and the fork test).
