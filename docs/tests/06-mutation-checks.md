# Mutation Checks

**Section:** [Testing Documentation](./README.md)
**Prev:** [Fuzz](./05-fuzz.md) · **Next:** [Gaps & Roadmap](./07-gaps-and-roadmap.md)

---

Coverage says a line ran; it does not say an assertion would have caught it changing. For the rounding logic, where the entire solvency argument lives, each direction was flipped by hand and the suite re-run to confirm it fails.

---

## The Seven Rounding Sites

| Site                             | Flipped to      | Caught by                                                                                            |
| :------------------------------- | :-------------- | :----------------------------------------------------------------------------------------------------- |
| `presentValueSupply`             | round up        | [`testFuzz_presentValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L113)          |
| `presentValueBorrow`             | round down      | [`testFuzz_presentValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L123)           |
| `principalValueSupply`           | round up        | [`testFuzz_principalValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L134)        |
| `principalValueBorrow`           | round down      | [`testFuzz_principalValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L144)         |
| Supply index accrual             | ceil            | [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L279)           |
| Borrow index accrual             | floor           | [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L279)           |
| Utilization                      | ceil            | [`testFuzz_utilization_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L222)                 |

Plus one rate-model site:

| Site                             | Mutated to      | Caught by                                                                                            |
| :------------------------------- | :-------------- | :----------------------------------------------------------------------------------------------------- |
| Supply rate floor                | removed         | [`testFuzz_interestSplit_supplyRateIsFloored`](../../test/fuzz/InterestRateModel.t.sol#L92)           |

Plus the stateful checks of roadmap 8.11, listed with their mutants in the [invariant suite](./12-invariant.md#falsification). One of them is the stateful counterpart of the finding below: a flipped `presentValueBorrow` survives the live-index round trip by construction and is caught only by the exact per-operation reserve table.

---

## The Finding That Shaped the Suite

Round-trip assertions alone did **not** catch a flipped `presentValueSupply`, and no round trip can: each of the four holds for every input whichever way a `presentValue` conversion rounds, by construction.

- `pv -> principal -> pv` (supply): the first leg floors, so `principal * index / 1e15 <= pv`. The second leg cannot return a value above the integer `pv`, whichever way it rounds.
- `principal -> pv -> principal` (supply): since `index >= 1e15`, an error of less than one unit of present value maps back to less than one unit of principal, and the final floor removes it.
- The borrow side is the same with the inequalities reversed, which is also why the live-index INV-3 passes a flipped `presentValueBorrow` ([invariant suite](./12-invariant.md#the-reserve-table-has-no-tolerance)).

So a round trip pins at most the direction of its first leg, and never the direction of a `presentValue` conversion. With either `presentValue` mutant applied, all four round-trip tests in `ConversionRounding.t.sol` pass at 10,000 runs (`FOUNDRY_FUZZ_RUNS=10000 forge test --match-contract ConversionRoundingTest --match-test RoundTrip`).

That is why the four per-site exact-value tests exist. Each pins a single division against a locally computed expectation (`(principal * index) / 1e15` truncated, and so on), so any single flipped direction fails.

**The rule this produced:** every rounding site gets a per-site exact-value assertion, not only a round trip. A round trip is a useful sanity property, but it is not a specification of the rounding direction, and the rounding direction is what the solvency argument rests on ([Guide 2, Section 10](../02-mathematics.md#10-rounding-policy)).

---

## Scope and Limits

These checks are manual, not generated: there is no automated mutation-testing tool in the pipeline. The mutants chosen are the ones with a plausible failure mode: flipping a rounding direction is a one-character edit that a reviewer can miss and that silently transfers value on every operation.

Phase 8 (audit prep) is where the broader static-analysis pass lands (Slither, Aderyn). Automated mutation testing is not currently planned for the PoC.
