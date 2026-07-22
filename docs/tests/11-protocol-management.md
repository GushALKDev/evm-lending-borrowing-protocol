# Protocol Management (Phase 7)

**Suites:** [`ProtocolManagementTest`](../../test/unit/ProtocolManagement.t.sol) (15 unit)
**Covers:** roadmap items 7.2 to 7.6 · [Guide 5, Access Control Matrix](../05-implementation.md#6-access-control-matrix) · [Guide 6, INV-13](../06-security.md#2-system-invariants)

---

> The governance surface and its guardrails. Reserves are the protocol's only owner-spendable pool, and `withdrawReserves` is the one path out of the market that no supplier's principal backs. Every test here is about one question: can the owner take exactly the reserves the accounting says exist and no more, can the guardian pause without ever being able to unpause or steal, and does the constructor refuse a collateral whose liquidation factor could leave a promptly absorbed account uncovered?

## Withdraw reserves (7.2)

Positive reserves are seeded by donating base to the market: with no principal change, `getReserves() = cash + totalBorrowPV - totalSupplyPV` rises by exactly the donated cash.

| Test | Asserts |
| :--- | :------ |
| [`test_withdrawReserves_ownerWithdrawsToTreasury`](../../test/unit/ProtocolManagement.t.sol#L62) | The owner moves reserves to the treasury; reserves fall by exactly the withdrawn amount |
| [`test_withdrawReserves_emitsEvent`](../../test/unit/ProtocolManagement.t.sol#L73) | `WithdrawReserves(to, amount)` fires with the recipient and amount |
| [`test_withdrawReserves_revertsForNonOwner`](../../test/unit/ProtocolManagement.t.sol#L81) | A non-owner (here the guardian) cannot withdraw: `Ownable` reverts |
| [`test_withdrawReserves_revertsOnZeroRecipient`](../../test/unit/ProtocolManagement.t.sol#L88) | `to == address(0)` reverts `InvalidRecipient`, so reserves cannot be burned |
| [`test_withdrawReserves_revertsWhenExceedingReserves`](../../test/unit/ProtocolManagement.t.sol#L97) | Withdrawing above `getReserves()` reverts `InsufficientReserves`, even with ample cash |
| [`test_withdrawReserves_reservesBoundBitesBeforeCash`](../../test/unit/ProtocolManagement.t.sol#L109) | A supplier's deposit makes cash exceed reserves (reserves stay 0); the reserves bound stops any withdrawal, so supplier cash is never spendable |

`withdrawReserves` is `onlyOwner` + `nonReentrant`, accrues first so reserves reflect interest to now, and is bounded independently by `getReserves()` and by cash. Neither bound implies the other: bad debt can push reserves above cash, and supplier deposits push cash above reserves.

---

## Role separation (7.3)

| Test | Asserts |
| :--- | :------ |
| [`test_roles_guardianCanPauseButNotUnpause`](../../test/unit/ProtocolManagement.t.sol#L128) | The guardian sets a pause flag but cannot clear it: `GuardianCannotUnpause` |
| [`test_roles_ownerCanUnpause`](../../test/unit/ProtocolManagement.t.sol#L139) | The owner clears a flag the guardian set |
| [`test_roles_strangerCannotSetFlags`](../../test/unit/ProtocolManagement.t.sol#L148) | Neither owner nor guardian: `Unauthorized` |
| [`test_roles_onlyOwnerWithdrawsReserves`](../../test/unit/ProtocolManagement.t.sol#L154) | The guardian, the other privileged role, still cannot withdraw reserves |

The guardian can only add flags (the new set must be a superset of the current one); only the owner can clear. Reserve withdrawal is owner-exclusive.

---

## Constructor revert matrix (7.4)

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_revertsWhenCoverageConditionFails`](../../test/unit/ProtocolManagement.t.sol#L176) | **INV-13.** A `liquidationFactor` below `liquidateCF * (1 + maxConfidenceBps)` (86% < 86.7% floor at 200 bps) reverts `InvalidConfiguration("coverage")` |
| [`test_constructor_acceptsCoverageAtTheFloor`](../../test/unit/ProtocolManagement.t.sol#L184) | Exactly at the floor (86.7%) is accepted: the bound is `>=`, rounded up |
| [`test_constructor_coverageFloorTracksOracleConfidence`](../../test/unit/ProtocolManagement.t.sol#L191) | A wider oracle band (10%) raises the floor to 93.5%, so the reference 93% factor now fails: the floor tracks `MAX_CONFIDENCE_BPS` read from the oracle |
| [`test_constructor_revertsOnBorrowCFAboveLiquidateCF`](../../test/unit/ProtocolManagement.t.sol#L199) | INV-12: `borrowCF` must be strictly below `liquidateCF` |
| [`test_constructor_revertsOnZeroSupplyCap`](../../test/unit/ProtocolManagement.t.sol#L206) | A zero supply cap is rejected |

INV-13 (absorb coverage, Guide 2 Section 8): a promptly absorbed account, eligible at the high confidence edge, must still credit enough at the mid price to cover its debt. The worst case widens `liquidateCF` by the oracle's max confidence, so the constructor requires `liquidationFactor >= liquidateCF * (FACTOR_SCALE + MAX_CONFIDENCE_BPS) / FACTOR_SCALE`, reading the ceiling from the wired oracle.
