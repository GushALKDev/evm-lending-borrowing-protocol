# 🚧 Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)
**Prev:** [Mutation Checks](./06-mutation-checks.md)

---

## Open Gaps at Phase 8 (in progress)

The PoC is at 96% (67 of 70 items across phases 0-8; Phase 9 is post-PoC and excluded). Three Phase 8 items remain open.

**Full-lifecycle integration on a local deployment does not exist yet (roadmap 8.6).** [`OracleMarketBorrowTest`](../../test/integration/OracleMarketBorrow.t.sol) wires the real oracle into a real market to prove the payable price path (item 5.8), and [`ForkLifecycleTest`](../../test/fork/ForkLifecycle.t.sol) runs supply/borrow/accrue/repay against real mainnet dependencies. What is still missing is the single local end-to-end suite that drives the whole lifecycle in one sequence — supply, borrow, warp, repay, absorb, buyCollateral — against the deterministic `MockPriceOracle`-backed mocks, plus a rehearsal of [`Deploy.s.sol`](../../script/Deploy.s.sol) on anvil.

**The audit checklist and internal line-by-line review are not done (roadmap 8.10).** The checklist lives in [Guide 6, Section 7](../06-security.md#7-testing-plan); completing it and the manual review is the last verification gate before the PoC is declared closed.

**Findings remediation and a final full-suite re-run (roadmap 8.11)** follow 8.10 and depend on whatever it surfaces.

### Deliberately unreachable, kept as defensive guards

These are not gaps to close; they are the reason branch coverage sits just under 100% on the market and oracle, and each is justified rather than removed to buy coverage points:

- The fallthrough `revert UnknownAsset` in `_offsetOf` — every caller passes `_requireListed` first, so it is unreachable.
- The `InsufficientCash` bound in `withdrawReserves` — reachable only when recognized bad debt has pushed reserves above cash.
- The positive-`targetExpo` scale-up branch of `PythChainlinkOracle._scalePyth` for the confidence value — unreachable with realistic Pyth feeds.

---

## What each phase shipped

### Phase 8 — Invariant, fork, static analysis, quote fuzz (in progress)

The invariant suite ([inventory](./12-invariant.md)) drives the market through 100,000 bounded random calls per run with `fail_on_revert = false`, asserting INV-1/2/4/5/6/7/9/11 after every step against the **real** `InterestRateModel`. On its first full run it found a critical self-transfer minting bug. The [fork suite](./13-fork.md) replays a cached Hermes VAA through the real `updatePriceFeeds` fee/refund path and real Chainlink `latestRoundData`, exercising the lifecycle against real USDC and WETH (absorb/buyCollateral are excluded on the fork and stay covered at unit/fuzz/invariant level — see the fork inventory for why). [Static analysis](./14-static-analysis.md) (Slither + Aderyn) is clean, with every false positive triaged. Coverage is above 95% on all four columns for every contract (8.9). The storefront quote now carries per-site directed-rounding fuzz ([`QuoteRounding.t.sol`](../../test/fuzz/QuoteRounding.t.sol), roadmap 8.5), pinning `quoteCollateral` against its exact floored value where the AbsorbLiquidation round trip could survive a flipped direction.

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
