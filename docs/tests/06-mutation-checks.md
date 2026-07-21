# 🧬 Mutation Checks

**Section:** [Testing Documentation](./README.md)
**Prev:** [Fuzz](./05-fuzz.md) · **Next:** [Gaps & Roadmap](./07-gaps-and-roadmap.md)

---

Coverage says a line ran; it does not say an assertion would have caught it changing. For the rounding logic — where the entire solvency argument lives — each direction was flipped by hand and the suite re-run to confirm it fails.

---

## The Seven Rounding Sites

| Site                             | Flipped to      | Caught by                                                                                            |
| :------------------------------- | :-------------- | :----------------------------------------------------------------------------------------------------- |
| `presentValueSupply`             | round up        | [`testFuzz_presentValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L112)          |
| `presentValueBorrow`             | round down      | [`testFuzz_presentValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L122)           |
| `principalValueSupply`           | round up        | [`testFuzz_principalValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L133)        |
| `principalValueBorrow`           | round down      | [`testFuzz_principalValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L143)         |
| Supply index accrual             | ceil            | [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L278)           |
| Borrow index accrual             | floor           | [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L278)           |
| Utilization                      | ceil            | [`testFuzz_utilization_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L221)                 |

Plus one rate-model site:

| Site                             | Mutated to      | Caught by                                                                                            |
| :------------------------------- | :-------------- | :----------------------------------------------------------------------------------------------------- |
| Supply rate floor                | removed         | [`testFuzz_interestSplit_supplyRateIsFloored`](../../test/fuzz/InterestRateModel.t.sol#L92)           |

---

## The Finding That Shaped the Suite

Round-trip assertions alone did **not** catch a flipped `presentValueSupply`.

The reason is that the flip partially cancels against `principalValueSupply`'s floor: converting present value to principal and back, the two errors move in opposite directions, and `presentValue(principalValue(pv)) <= pv` still holds for most inputs. The property test passed on broken code.

That is why the four per-site exact-value tests exist. Each pins a single division against a locally computed expectation — `(principal * index) / 1e15` truncated, and so on — so no cancellation is possible and any single flipped direction fails immediately.

**The rule this produced:** new rounding code gets a per-site exact-value assertion, not only a round trip. A round trip is a useful sanity property, but it is not a specification of the rounding direction, and the rounding direction is what the solvency argument rests on ([Guide 2, Section 10](../02-mathematics.md#10-rounding-policy)).

---

## Scope and Limits

These checks are manual, not generated: there is no automated mutation-testing tool in the pipeline. The mutants chosen are the ones with a plausible failure mode — flipping a rounding direction is a one-character edit that a reviewer can miss and that silently transfers value on every operation.

Phase 8 (audit prep) is where the broader static-analysis pass lands (Slither, Aderyn). Automated mutation testing is not currently planned for the PoC.
