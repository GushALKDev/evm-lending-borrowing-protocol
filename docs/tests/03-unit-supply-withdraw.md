# 💸 Unit: Supply & Withdraw

**Section:** [Testing Documentation](./README.md)
**Suite:** [`test/unit/SupplyWithdraw.t.sol`](../../test/unit/SupplyWithdraw.t.sol) — 48 tests
**Phase:** 3
**Prev:** [Unit: Accounting](./02-unit-accounting.md) · **Next:** [Unit: Interest Rate Model](./04-unit-rate-model.md)

---

The Phase 3 user-facing surface: base and collateral flows, the rebasing ERC20 surface, the pause flags with the guardian role, and constructor validation. Reference: [Guide 3, Flows 6.1-6.4](../03-architecture.md#6-detailed-execution-flows).

---

## Supply Base (3.1)

| Test                                                                                             | Asserts                                                                                        |
| :----------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------- |
| [`test_supplyBase_creditsBalanceAndPullsTokens`](../../test/unit/SupplyWithdraw.t.sol#L67)       | Balance, custody, and `totalSupply` all move together.                                          |
| [`test_supplyBase_emitsSupplyAndTransfer`](../../test/unit/SupplyWithdraw.t.sol#L76)             | The domain `Supply` event fires first, then the ERC20 `Transfer` mint mirror from the zero address. Order is asserted, not just presence. |
| [`test_supplyBase_revertsOnZeroAmount`](../../test/unit/SupplyWithdraw.t.sol#L87)                | `ZeroAmount` rather than a silent no-op.                                                        |
| [`test_supplyBase_accrualGrowsBalance`](../../test/unit/SupplyWithdraw.t.sol#L93)                | After a year at a positive supply rate the balance has grown with no second deposit.             |

---

## Supply To

| Test                                                                                             | Asserts                                                                                        |
| :----------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------- |
| [`test_supplyTo_creditsTheDestinationFromTheCaller`](../../test/unit/SupplyWithdraw.t.sol#L111)    | Tokens leave the caller, the destination is credited, the caller is not, and both `Supply` and the `Transfer` mint name the destination. |
| [`test_supplyTo_collateralCreditsTheDestination`](../../test/unit/SupplyWithdraw.t.sol#L127)       | Collateral posted on behalf lands in the destination's ledger and `assetsIn` bitmap, not the payer's. |
| [`test_supplyTo_revertsOnZeroDestination`](../../test/unit/SupplyWithdraw.t.sol#L140)              | `InvalidRecipient(address(0))`: no position can be credited to the zero address.                 |

---

## Withdraw Base (3.3)

| Test                                                                                                | Asserts                                                                                      |
| :-------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------- |
| [`test_withdrawBase_returnsTokensAndClearsBalance`](../../test/unit/SupplyWithdraw.t.sol#L150)      | Partial withdrawal debits the balance and returns exactly that many tokens.                     |
| [`test_withdrawBase_fullWithdrawalZeroesBalance`](../../test/unit/SupplyWithdraw.t.sol#L162)        | A full exit zeroes both the balance and the stored principal: no dust principal left behind.    |
| [`test_withdrawBase_crossingBelowZeroIsRefusedWithoutCollateral`](../../test/unit/SupplyWithdraw.t.sol#L174) | Crossing below zero is a borrow, so it is refused on health: with no collateral posted the call reverts `NotCollateralized(alice, 500e18, 0)`. Phase 3 reverted `InsufficientBalance` here; Phase 4 replaced it with the borrow path. |
| [`test_withdrawBase_revertsWhenCashInsufficient`](../../test/unit/SupplyWithdraw.t.sol#L189)        | With supply on the books but cash drained out from under the market (simulating ~100% utilization), the withdrawal reverts `InsufficientCash` rather than misaccounting. This is the S4 bank-run mechanic ([Guide 6, Section 4](../06-security.md#4-adversarial-scenarios)). |

---

## Supply Collateral (3.2)

| Test                                                                                             | Asserts                                                                                        |
| :----------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------- |
| [`test_supplyCollateral_updatesLedgersAndBitmap`](../../test/unit/SupplyWithdraw.t.sol#L208)     | User ledger, global total, `assetsIn` bit, and token custody all update in one call (INV-6, INV-7). |
| [`test_supplyCollateral_enforcesSupplyCap`](../../test/unit/SupplyWithdraw.t.sol#L218)           | `SupplyCapExceeded` carries the asset, the cap, and the attempted total (INV-8).                 |
| [`test_supplyCollateral_revertsOnUnknownAsset`](../../test/unit/SupplyWithdraw.t.sol#L227)       | An unlisted token reverts `UnknownAsset` rather than being silently custodied and lost.          |

---

## Withdraw Collateral (3.4)

| Test                                                                                                   | Asserts                                                                                    |
| :------------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------- |
| [`test_withdrawCollateral_returnsAndClearsBitmapOnZero`](../../test/unit/SupplyWithdraw.t.sol#L238)     | Withdrawing to zero clears the `assetsIn` bit, so health checks stop iterating that asset (INV-7). |
| [`test_withdrawCollateral_partialKeepsBitmapSet`](../../test/unit/SupplyWithdraw.t.sol#L251)            | A partial withdrawal leaves the bit set: the bitmap tracks membership, not amount.             |
| [`test_withdrawCollateral_revertsOnInsufficientBalance`](../../test/unit/SupplyWithdraw.t.sol#L261)     | `InsufficientCollateral` carries account, asset, held, and requested.                          |

The health-check hook on this path is a `NotImplementedYet` stub, unreachable in Phase 3 because debt cannot exist. See [Gaps & Roadmap](./07-gaps-and-roadmap.md).

---

## ERC20 Transfer (3.5)

| Test                                                                                                | Asserts                                                                                   |
| :-------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------ |
| [`test_transfer_movesSupplyBetweenAccounts`](../../test/unit/SupplyWithdraw.t.sol#L275)             | A transfer moves supply-side value with both sides landing exactly.                          |
| [`test_transfer_revertsWhenItWouldPushSenderNegative`](../../test/unit/SupplyWithdraw.t.sol#L286)   | `TransferWouldBorrow`: a transfer can never open a debt, which is why it needs no oracle.    |
| [`test_transferFrom_spendsAllowance`](../../test/unit/SupplyWithdraw.t.sol#L312)                    | The allowance decrements by exactly the amount moved.                                        |
| [`test_transferFrom_revertsOnInsufficientAllowance`](../../test/unit/SupplyWithdraw.t.sol#L325)     | `InsufficientAllowance` carries owner, spender, allowance, and requested amount.             |
| [`test_transferFrom_infiniteAllowanceIsNotSpent`](../../test/unit/SupplyWithdraw.t.sol#L338)        | `type(uint256).max` is treated as infinite and left untouched, the conventional ERC20 optimization. |

---

## Pause Flags (3.6)

| Test                                                                                             | Asserts                                                                                          |
| :----------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------ |
| [`test_pause_ownerCanSetAndClear`](../../test/unit/SupplyWithdraw.t.sol#L354)                    | The owner can both set and clear flags.                                                            |
| [`test_pause_guardianCanAddButNotClear`](../../test/unit/SupplyWithdraw.t.sol#L364)              | The guardian may add flags (including on top of existing ones) but clearing any reverts `GuardianCannotUnpause`. The asymmetry is the whole point of the role ([Guide 6, Section 5](../06-security.md#5-pause-and-circuit-breaker-philosophy)). |
| [`test_pause_revertsForNonOwnerNonGuardian`](../../test/unit/SupplyWithdraw.t.sol#L384)          | Any other caller gets `Unauthorized`.                                                              |
| [`test_pause_supplyBlocksSupply`](../../test/unit/SupplyWithdraw.t.sol#L390)                     | `PAUSE_SUPPLY` blocks a base `supply` from an account with no debt with `Paused(flag)`. The repay and collateral top-up exceptions are in [Borrow & Repay](./08-unit-borrow-repay.md#pause-interaction). |
| [`test_pause_withdrawBlocksWithdraw`](../../test/unit/SupplyWithdraw.t.sol#L399)                 | `PAUSE_WITHDRAW` blocks `withdraw`.                                                                |
| [`test_pause_transferBlocksTransfer`](../../test/unit/SupplyWithdraw.t.sol#L410)                 | `PAUSE_TRANSFER` blocks `transfer`.                                                                |

---

## Sentinel, Metadata, Refund

| Test                                                                                                | Asserts                                                                                      |
| :-------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------- |
| [`test_supplyBase_maxSentinelRevertsWithoutDebt`](../../test/unit/SupplyWithdraw.t.sol#L426)        | The `type(uint256).max` full-repay sentinel has nothing to repay when no debt exists, so it reverts `ZeroAmount` rather than pulling an unbounded transfer. |
| [`test_metadata_matchesLmUSDC`](../../test/unit/SupplyWithdraw.t.sol#L436)                          | `name`, `symbol`, and `decimals` (mirroring the base token) are as specified.                   |
| [`test_withdraw_refundsExcessValue`](../../test/unit/SupplyWithdraw.t.sol#L595)                     | `withdraw` is payable for oracle-update fees; any `msg.value` it does not spend is refunded, so the caller's ETH balance is unchanged when no update is needed. |

---

## Constructor Validation (INV-12)

Each of these mutates exactly one field of the `MarketBuilder` defaults, so the revert unambiguously identifies which check fired.

| Test                                                                                                          | Asserts                                                                                  |
| :------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------- |
| [`test_constructor_revertsWhenBorrowCFNotBelowLiquidateCF`](../../test/unit/SupplyWithdraw.t.sol#L459)         | `borrowCF < liquidateCF` strictly; equality is rejected.                                   |
| [`test_constructor_revertsOnLiquidationFactorAboveScale`](../../test/unit/SupplyWithdraw.t.sol#L493)           | `liquidationFactor <= FACTOR_SCALE`.                                                       |
| [`test_constructor_revertsOnZeroStoreFrontPriceFactor`](../../test/unit/SupplyWithdraw.t.sol#L502)             | A zero storefront factor would make the discount degenerate.                                |
| [`test_constructor_revertsOnMismatchedDecimals`](../../test/unit/SupplyWithdraw.t.sol#L511)                    | The configured decimals must match the token's own `decimals()`, or every collateral valuation is silently off by orders of magnitude. |
| [`test_constructor_revertsOnZeroSupplyCap`](../../test/unit/SupplyWithdraw.t.sol#L517)                         | A zero cap would list an asset nobody can supply.                                           |
| [`test_constructor_revertsOnZeroOracle`](../../test/unit/SupplyWithdraw.t.sol#L523)                            | Zero-address oracle rejected at deployment.                                                 |
| [`test_constructor_revertsOnZeroGuardian`](../../test/unit/SupplyWithdraw.t.sol#L530)                          | Zero-address guardian rejected at deployment.                                               |
| [`test_constructor_revertsOnZeroMinBorrow`](../../test/unit/SupplyWithdraw.t.sol#L537)                         | A zero `minBorrow` would disable the INV-10 dust guard.                                     |

INV-13 (the absorb coverage condition) is not enforced here: it needs `MAX_CONFIDENCE_BPS` from the oracle and lands in Phase 7.
