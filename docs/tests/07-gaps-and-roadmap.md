# 🚧 Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)
**Prev:** [Mutation Checks](./06-mutation-checks.md)

---

## Open Gaps at Phase 8 (in progress)

The PoC is at 97% (70 of 72 items across phases 0-8; Phase 9 is post-PoC and excluded). Two Phase 8 items remain open.

**The audit checklist and internal line-by-line review are not done (roadmap 8.12).** The checklist lives in [Guide 6, Section 6](../06-security.md#6-audit-checklist); completing it and the manual review is the last verification gate before the PoC is declared closed.

**Findings remediation and a final full-suite re-run (roadmap 8.13)** follow 8.12 and depend on whatever it surfaces.

### Deliberately unreachable, kept as defensive guards

These are the lines and branches `forge coverage --report lcov` reports as never hit in `src/`. They are the reason coverage sits just under 100% on the market and oracle, and each is kept rather than removed to buy coverage points:

- `LendingMarket._offsetOf`, the fallthrough `revert UnknownAsset` (line): every caller passes `_requireListed` first, so it is unreachable.
- `LendingMarket.withdrawReserves`, the `InsufficientCash` bound (branch): reachable only when recognized bad debt has pushed reserves above cash.
- `LendingMarket.setPauseFlags`, the owner branch (branch): its body is an empty block, which the coverage tool reports as not taken although owner calls run in `test_pause_ownerCanSetAndClear` and `test_roles_ownerCanUnpause`.
- `PythChainlinkOracle.updateAndGetPrice`, `RefundFailed` (branch): reachable by a direct caller of the oracle that overpays and cannot receive ETH; the market always can, and no test calls the oracle that way.
- `PythChainlinkOracle._scalePyth`, the scale-down path for `18 + expo < 0` (line): it needs a Pyth exponent below -18, which no realistic feed uses.

---

## What each phase shipped

### Phase 8 — Invariant, fork, static analysis, quote fuzz (in progress)

The invariant suite ([inventory](./12-invariant.md)) drives the market through 100,000 bounded random calls per invariant (1,000 runs of 100 calls) with `fail_on_revert = false`, asserting 17 invariants after every step against the **real** `InterestRateModel`: INV-1 to INV-11 and INV-14, the per-operation reserve table exactly, absorb eligibility in both directions, repay always available under `PAUSE_SUPPLY`, no new risk under `PAUSE_BORROW`, and a revert-reason allowlist (roadmap 8.11), each new one falsified by a targeted mutant, over liquidity rebalanced so sequences reach the kink and `U > 1`. On its first full run it found a critical self-transfer minting bug. The [fork suite](./13-fork.md) replays a cached Hermes VAA through the real `updatePriceFeeds` fee/refund path and real Chainlink `latestRoundData`, exercising the lifecycle against real USDC and WETH (absorb/buyCollateral are excluded on the fork and stay covered at unit/fuzz/invariant level; see the fork inventory for why). [Static analysis](./14-static-analysis.md) (Slither + Aderyn) is clean, with every false positive triaged. Coverage is above 95% on all four columns for every contract (8.9). The storefront quote now carries per-site directed-rounding fuzz ([`QuoteRounding.t.sol`](../../test/fuzz/QuoteRounding.t.sol), roadmap 8.5), pinning `quoteCollateral` against its exact floored value where the AbsorbLiquidation round trip could survive a flipped direction. The local end-to-end lifecycle (roadmap 8.6) runs supply → borrow → warp → repay → absorb → buyCollateral in one sequence on a production `LendingMarket` against a `MockPriceOracle` ([`FullLifecycleTest`](../../test/integration/FullLifecycle.t.sol)), and [`DeployScriptTest`](../../test/integration/DeployScript.t.sol) rehearses [`Deploy.s.sol`](../../script/Deploy.s.sol) against real deployed dependencies exported into its environment vars, the reproducible form of a deploy rehearsal. [`OracleMarketLiquidationTest`](../../test/integration/OracleMarketLiquidation.t.sol) (roadmap 8.10) closes the one payable path nothing else reached: `absorb` and `buyCollateral` through the real `PythChainlinkOracle` with a real Pyth fee, asserting the exact fee consumed and the refund sweep ([inventory](./09-oracle.md#liquidation-integration-810)).

### Phase 7 — Reserves & protocol management

`withdrawReserves` is now implemented in the production contract (it was a reverting harness stub through Phases 4-6), and the constructor's INV-13 absorb-coverage condition is enforced and pinned at, below, and above the floor. Owner/guardian role separation and the full constructor revert matrix are covered in [`ProtocolManagementTest`](./11-protocol-management.md).

### Phase 6 — Absorb liquidation

17 unit and 2 fuzz tests ([inventory](./10-absorb-liquidation.md)) for the two-step liquidation: eligibility at `price + conf`, the surplus/exact/shortfall settlements with explicit bad debt, multi-collateral absorb, the storefront quote, `buyCollateral` gated on the reserve deficit, the `ABSORB`/`BUY` pause flags, and the round-trip reserve bound (proceeds `>= creditBase`, since the shortfall gap to the full debt is the already-recognized bad debt).

### Phase 5 — Oracle

28 unit, 3 fuzz, and 2 integration tests ([inventory](./09-oracle.md)) for `PythChainlinkOracle`: the four-stage validation pipeline, 1e18 normalization from Pyth expo and Chainlink decimals, the fee/refund path against the SDK's `MockPyth`, the constructor guard matrix, and the market integration. The integration test surfaced a latent Phase 4 bug — the market had no `receive()` for the oracle's per-asset fee refund — now fixed.

### Phase 4 — Borrow & repay

37 unit and 6 fuzz tests ([inventory](./08-unit-borrow-repay.md)), closing INV-9 and INV-10 at the single-account level; the multi-account, adversarially-sequenced form was then closed by the Phase 8 invariant suite.

---

## Maintenance

This section is updated at the close of every phase:

1. Re-run `forge test --summary` and `forge coverage --no-match-coverage "test|script"`, and update the tables in the [index](./README.md).
2. Add the new tests to the matching inventory file, with a line-anchored link to the code.
3. Move any newly covered invariant out of ⏳ in the [invariant coverage map](./README.md#-invariant-coverage-map).
4. Record what shipped in the section above and update the open-gaps list.

**On the line anchors:** the links in these files point at line numbers, which drift when a test file is edited. Regenerate them with:

```bash
grep -nE "^\s*function (test|testFuzz)" test/unit/*.t.sol test/fuzz/*.t.sol
```
