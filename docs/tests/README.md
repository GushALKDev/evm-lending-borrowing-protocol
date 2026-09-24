# 🧪 Testing Documentation

**Version:** 1.0
**Prerequisites:** [Guide 6: Security](../06-security.md)
**Status:** Updated at the close of every roadmap phase (current: Phase 8)

---

> This section is the executable counterpart of [Guide 6, Section 7](../06-security.md#7-testing-plan). Guide 6 states the invariants; this documents which test asserts each one, why the assertion is shaped the way it is, and links every entry to the code.

---

## 📖 Contents

| Document                                       | Covers                                                                     |
| :--------------------------------------------- | :-------------------------------------------------------------------------- |
| **[Strategy](./01-strategy.md)**               | Test layers, principles, infrastructure and mocks, how to run the suite     |
| **[Unit: Accounting](./02-unit-accounting.md)**| Phase 1 core: construction, conversions, accounting path, utilization, views, reserves, accrual |
| **[Unit: Supply & Withdraw](./03-unit-supply-withdraw.md)** | Phase 3 surface: base and collateral flows, ERC20, pause flags, constructor validation |
| **[Unit: Interest Rate Model](./04-unit-rate-model.md)** | Phase 2: the curve in isolation and wired into market accrual, accrual overflow bounds |
| **[Unit + Fuzz: Borrow & Repay](./08-unit-borrow-repay.md)** | Phase 4: sign crossings, capacity boundaries, the dust guard, accrue-before-action |
| **[Oracle](./09-oracle.md)**                   | Phase 5: the Pyth+Chainlink validation pipeline, normalization, fee/refund, and the market integration; Phase 8: absorb and buyCollateral through the real oracle |
| **[Absorb Liquidation](./10-absorb-liquidation.md)** | Phase 6: eligibility at price + conf, the three absorb settlements, the storefront quote, buyCollateral, and the round-trip reserve bound |
| **[Protocol Management](./11-protocol-management.md)** | Phase 7: withdrawReserves bounds, owner/guardian role separation, and the constructor revert matrix including INV-13 |
| **[Invariant Suite](./12-invariant.md)** | Phase 8: the StdInvariant handler, 17 invariants (INV-1 to INV-11, INV-14, the reserve table, absorb eligibility, repay under `PAUSE_SUPPLY`, no new risk under `PAUSE_BORROW`, the revert allowlist) and their mutation checks; the self-transfer minting bug it found |
| **[Fork Tests](./13-fork.md)** | Phase 8: the full lifecycle on an Ethereum mainnet fork against real USDC/WETH, real Pyth, and real Chainlink, via a cached Hermes VAA |
| **[Static Analysis](./14-static-analysis.md)** | Phase 8: the Slither + Aderyn run, the dead code removed, and every false positive triaged with justification |
| **[Fuzz](./05-fuzz.md)**                       | Conversion rounding, index monotonicity, rate properties, index-scale precision |
| **[Mutation Checks](./06-mutation-checks.md)** | Which flipped rounding direction each test catches, and the one that round trips missed |
| **[Gaps & Roadmap](./07-gaps-and-roadmap.md)** | What is not covered yet, and the testing deliverable of each remaining phase |

---

## 📊 Current Status

**331 tests, all green** (Phase 8 in progress: invariant suite covering INV-1 to INV-11 plus INV-14, the per-operation reserve table, repay always available under `PAUSE_SUPPLY`, no new risk under `PAUSE_BORROW`, and a revert-reason allowlist, oracle failure modes driven through the market's own entry points, refunds that ignore forced ETH, fork tests against real Ethereum mainnet dependencies, static analysis clean, coverage above 95% on every contract, directed-rounding fuzz on the storefront quote, the full local lifecycle plus a deploy-script rehearsal, and absorb/buyCollateral through the real oracle's fee path; INV-1 caught a self-transfer minting bug).

| Suite                                                                | Layer | Tests | Phase |
| :------------------------------------------------------------------- | :---- | ----: | :---- |
| [`LendingMarketAccountingTest`](../../test/unit/LendingMarketAccounting.t.sol) | Unit  |    36 | 1     |
| [`SupplyWithdrawTest`](../../test/unit/SupplyWithdraw.t.sol)          | Unit  |    48 | 3     |
| [`BorrowRepayTest`](../../test/unit/BorrowRepay.t.sol)                | Unit  |    59 | 4     |
| [`InterestRateModelTest`](../../test/unit/InterestRateModel.t.sol)    | Unit  |    18 | 2     |
| [`MarketAccrualWithRealCurveTest`](../../test/unit/MarketAccrualWithRealCurve.t.sol) | Unit |  4 | 2     |
| [`AccrualOverflowTest`](../../test/unit/AccrualOverflow.t.sol)        | Unit  |     3 | 1     |
| [`PythChainlinkOracleTest`](../../test/unit/PythChainlinkOracle.t.sol)| Unit  |    28 | 5     |
| [`AbsorbLiquidationTest`](../../test/unit/AbsorbLiquidation.t.sol)    | Unit  |    22 | 6     |
| [`ProtocolManagementTest`](../../test/unit/ProtocolManagement.t.sol)  | Unit  |    18 | 7     |
| [`ConversionRoundingTest`](../../test/fuzz/ConversionRounding.t.sol)  | Fuzz  |    19 | 1     |
| [`InterestRateModelFuzzTest`](../../test/fuzz/InterestRateModel.t.sol)| Fuzz  |     6 | 2     |
| [`BorrowCapacityFuzzTest`](../../test/fuzz/BorrowCapacity.t.sol)      | Fuzz  |     6 | 4     |
| [`IndexPrecisionTest`](../../test/fuzz/IndexPrecision.t.sol)          | Fuzz  |     4 | 1     |
| [`PythChainlinkOracleFuzzTest`](../../test/fuzz/PythChainlinkOracle.t.sol) | Fuzz | 3 | 5     |
| [`AbsorbLiquidationFuzzTest`](../../test/fuzz/AbsorbLiquidation.t.sol) | Fuzz | 2 | 6     |
| [`QuoteRoundingTest`](../../test/fuzz/QuoteRounding.t.sol)            | Fuzz  |     3 | 8     |
| [`OracleMarketBorrowTest`](../../test/integration/OracleMarketBorrow.t.sol) | Integration | 2 | 5 |
| [`OracleMarketLiquidationTest`](../../test/integration/OracleMarketLiquidation.t.sol) | Integration | 4 | 8 |
| [`OracleFailureModesTest`](../../test/integration/OracleFailureModes.t.sol) | Integration | 15 | 8 |
| [`ForcedEthRefundTest`](../../test/integration/ForcedEthRefund.t.sol) | Integration | 9 | 8 |
| [`FullLifecycleTest`](../../test/integration/FullLifecycle.t.sol)     | Integration | 1 | 8 |
| [`DeployScriptTest`](../../test/integration/DeployScript.t.sol)       | Integration | 1 | 8 |
| [`InvariantsTest`](../../test/invariant/Invariants.t.sol)             | Invariant | 17 | 8 |
| [`ForkLifecycleTest`](../../test/fork/ForkLifecycle.t.sol)            | Fork | 3 | 8 |
| **Total**                                                            |       | **331** |     |

| Layer (directory) | Tests |
| :---------------- | ----: |
| Unit (`test/unit`) | 236 |
| Fuzz (`test/fuzz`) | 43 |
| Integration (`test/integration`) | 32 |
| Invariant (`test/invariant`) | 17 |
| Fork (`test/fork`) | 3 |
| **Total** | **331** |

Under the default profile, 41 tests take fuzzed parameters at 1,000 runs each (41,000 runs), and each of the 17 invariants runs 1,000 sequences of 100 calls (100,000 calls each, 1,700,000 in total). The fork suite runs against the pinned mainnet block when `FORK_RPC_URL` is set and passes as a no-op otherwise; the counts above are the same in both modes.

### Coverage

| File                        | Lines            | Statements       | Branches       | Functions       |
| :-------------------------- | :--------------- | :--------------- | :------------- | :-------------- |
| `src/InterestRateModel.sol` | 100.00% (17/17)  | 100.00% (25/25)  | 100.00% (4/4)  | 100.00% (3/3)   |
| `src/LendingMarket.sol`     | 99.72% (361/362) | 99.59% (484/486) | 97.33% (73/75) | 100.00% (62/62) |
| `src/PythChainlinkOracle.sol` | 98.46% (64/65) | 96.91% (94/97)   | 95.45% (21/22) | 100.00% (8/8)   |

Every contract is now above the 95% gate on lines, statements, branches, and functions (roadmap 8.9). Phase 8 raised branch coverage on `LendingMarket.sol` from 81.5% to 97.1% by pinning the previously untested revert sides of the input guards (constructor `numAssets`/`collateralAsset`/`liquidateCF`, `ZeroAmount` on every entry point, `InvalidRecipient` on transfer and buyCollateral, and the `RefundFailed` path via a rejecting-receiver caller). The lines and branches still reported as never hit are listed, each with its reason, in [Gaps & Roadmap](./07-gaps-and-roadmap.md#deliberately-unreachable-kept-as-defensive-guards).

### Reproducing the numbers

Every count on this page and in the README comes from one of these commands, run at the repository root:

```bash
# Tests per suite and the total; with FORK_RPC_URL unset (mock mode) the fork suite passes as a no-op
forge test --summary
FORK_RPC_URL= forge test --summary

# Tests per layer (directory)
forge test --list --json | jq -r 'to_entries[] | "\(.key | split("/")[1]) \([.value[] | length] | add)"' \
  | awk '{n[$1] += $2} END {for (k in n) print k, n[k]}'

# Fuzzed tests and their runs, invariants and their calls
forge test | awk '/runs: [0-9]+, μ/ {match($0, /runs: [0-9]+/); f++; r += substr($0, RSTART + 6, RLENGTH - 6)}
  /calls: [0-9]+,/ {match($0, /calls: [0-9]+/); i++; c += substr($0, RSTART + 7, RLENGTH - 7)}
  END {print f " fuzz tests, " r " runs; " i " invariants, " c " calls"}'

# Coverage per contract (lines, statements, branches, functions)
forge coverage --no-match-coverage "test|script" --report summary

# Lines and branches never hit
forge coverage --no-match-coverage "test|script" --report lcov
awk -F'[:,]' '/^SF:/ {f = $2} /^BRDA:/ && f ~ /^src/ && ($5 == "-" || $5 == "0") {print f ":" $2 " branch"}
  /^DA:/ && f ~ /^src/ && $3 == "0" {print f ":" $2 " line"}' lcov.info
```

---

## 🔗 Invariant Coverage Map

Every invariant from [Guide 6, Section 2](../06-security.md#2-system-invariants), and what currently asserts it.

| Invariant | Statement (abridged)                              | Asserted by                                                                                        |
| :-------- | :------------------------------------------------ | :------------------------------------------------------------------------------------------------- |
| INV-1     | Principal sums equal the totals, split by sign    | The stateful [`invariant_INV1_principalSumsMatchTotals`](../../test/invariant/Invariants.t.sol) across sequences, plus [`testFuzz_accountingPath_totalsMatchPrincipalsAcrossCrossings`](../../test/fuzz/ConversionRounding.t.sol#L320), [`testFuzz_accountingPath_totalsMatchTwoAccounts`](../../test/fuzz/ConversionRounding.t.sol#L341), and the [six unit tests](./02-unit-accounting.md#single-accounting-path). The invariant suite found a self-transfer minting bug here (see [Invariant Suite](./12-invariant.md)) |
| INV-2     | Indexes monotone, never below seed                | [`testFuzz_accrual_indexesAreMonotone`](../../test/fuzz/ConversionRounding.t.sol#L240), [`testFuzz_accrual_borrowIndexOutgrowsSupplyIndex`](../../test/fuzz/ConversionRounding.t.sol#L263) |
| INV-3     | Round trips never favor the account               | The stateful [`invariant_INV3_roundTripsFavorTheProtocolAtLiveIndexes`](../../test/invariant/Invariants.t.sol#L252) at the evolved indexes, the four [round-trip tests](./05-fuzz.md#inv-3-round-trips-favor-the-protocol), and the four [per-site exact-value tests](./05-fuzz.md#directed-rounding-per-site) |
| INV-4     | Rounding residual accrues to reserves             | The stateful [`invariant_INV4_reserveDeltasMatchTheTable`](../../test/invariant/Invariants.t.sol#L242) (the per-operation table, exact) and [`invariant_INV4_pureAccrueDoesNotBleedReserves`](../../test/invariant/Invariants.t.sol#L230), plus [`testFuzz_interestSplit_reserveShareIsNonNegative`](../../test/fuzz/InterestRateModel.t.sol#L76), [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L278), [`testFuzz_indexScale_neverFavorsTheSupplier`](../../test/fuzz/IndexPrecision.t.sol#L66) |
| INV-5     | Cash conservation via ghost tracking              | The stateful [`invariant_INV5_cashConservation`](../../test/invariant/Invariants.t.sol): the market's base balance equals the ghost-tracked net of every recorded inflow/outflow across sequences |
| INV-6/7/8 | Collateral ledgers, bitmap, supply cap            | The stateful [`invariant_INV6_collateralTotalsMatchAndSolvent`](../../test/invariant/Invariants.t.sol) (summed `balanceOf >= totalsCollateral == Σ userCollateral`), [`invariant_INV7_bitmapMatchesCollateral`](../../test/invariant/Invariants.t.sol), and [`invariant_INV8_collateralWithinSupplyCap`](../../test/invariant/Invariants.t.sol#L277) against a cap the sequences reach, plus unit-level [`test_supplyCollateral_*`](./03-unit-supply-withdraw.md#supply-collateral-32), [`test_withdrawCollateral_*`](./03-unit-supply-withdraw.md#withdraw-collateral-34), and the [ADR-7 semantics tests](./10-absorb-liquidation.md#collateral-reserves-semantics-adr-7) |
| INV-9     | No action ends undercollateralized                | The stateful [`invariant_INV9_noActionLeavesUndercollateralized`](../../test/invariant/Invariants.t.sol) (latched per-action across sequences; see [note](./12-invariant.md#inv-9-is-per-action-not-global)), plus [`testFuzz_acceptedBorrowAlwaysLeavesTheAccountCollateralized`](../../test/fuzz/BorrowCapacity.t.sol#L73), [`testFuzz_repayNeverReducesHealth`](../../test/fuzz/BorrowCapacity.t.sol#L139), and the [nine capacity unit tests](./08-unit-borrow-repay.md#capacity-check-42) |
| INV-10    | `minBorrow` dust guard                            | The stateful [`invariant_INV10_noActionCreatesDustDebt`](../../test/invariant/Invariants.t.sol#L288) (latched on the borrow branch), [`testFuzz_acceptedBorrowNeverLandsInTheDustBand`](../../test/fuzz/BorrowCapacity.t.sol#L196), and the [five dust-guard unit tests](./08-unit-borrow-repay.md#minborrow-dust-guard-43-inv-10) |
| INV-11    | No debt against an empty pool                     | The stateful [`invariant_INV11_noDebtWithoutSupply`](../../test/invariant/Invariants.t.sol) across sequences, plus [`test_utilization_isZeroWhenSupplyIsZero`](../../test/unit/LendingMarketAccounting.t.sol#L245) for the divide-by-zero guard |
| INV-12    | Static configuration ordering                     | The [eight constructor tests](./03-unit-supply-withdraw.md#constructor-validation-inv-12) in `SupplyWithdrawTest` and the [six](./04-unit-rate-model.md#constructor-22-inv-12) in `InterestRateModelTest` |
| INV-13    | Absorb coverage condition                         | Constructor-enforced; the [three coverage tests](./11-protocol-management.md#constructor-revert-matrix-74) in `ProtocolManagementTest` pin it at, below, and above the floor |
| INV-14    | `supplyRate <= borrowRate`, monotone, continuous  | The stateful [`invariant_INV14_supplyRateAtMostBorrowRate`](../../test/invariant/Invariants.t.sol#L299) at the live utilization, plus [`testFuzz_supplyRateNeverExceedsBorrowRate`](../../test/fuzz/InterestRateModel.t.sol#L60), both [monotonicity fuzz tests](./05-fuzz.md#2-interestratemodeltsol--6-tests), [`testFuzz_continuity_noDownwardStepAcrossTheKink`](../../test/fuzz/InterestRateModel.t.sol#L111) |

---

## 📚 References

- [Documentation Index](../README.md)
- [Guide 2: Mathematics](../02-mathematics.md) — the formulas every rounding test pins
- [Guide 5: Implementation](../05-implementation.md) — the function contracts under test
- [Guide 6: Security](../06-security.md) — the invariants this suite executes
- [ROADMAP](../ROADMAP.md) — phase status
