# EVM Lending / Borrowing Protocol

[![CI](https://github.com/GushALKDev/evm-lending-borrowing-protocol/actions/workflows/ci.yml/badge.svg)](https://github.com/GushALKDev/evm-lending-borrowing-protocol/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

A **single-market money market** in the style of Compound III (Comet): one borrowable base asset (USDC), isolated supply-only collateral (WETH, wBTC), index-based interest accrual, and protocol-absorbed liquidations. Built as a proof of concept of DeFi lending primitives, around provable solvency.

> **Proof of concept. Not audited and not deployed.** All code is written from scratch; Compound III is the architectural reference, and no code is copied or forked. Do not use in production.

---

## How it works

- **Suppliers** deposit USDC and hold a rebasing balance (`lmUSDC`) that grows with interest.
- **Borrowers** post WETH or wBTC collateral and borrow USDC against it.
- **Liquidator bots** absorb underwater accounts and buy the seized collateral at a discount.

One borrowable asset. Inert collateral. Every rounding direction favors the protocol, and solvency is designed to be provable, not assumed.

```
┌──────────────────────────────────────────────────────────────────┐
│                            THE MODEL                             │
│                                                                  │
│   SUPPLIERS ──── USDC ────►┌──────────────────┐                  │
│   (earn interest,          │                  │                  │
│    hold lmUSDC)            │  LENDING MARKET  │◄── WETH / wBTC   │
│                            │   (singleton)    │    BORROWERS     │
│   LIQUIDATORS ◄─ discount ─┤                  │    (post inert   │
│   (absorb, then            │  one base asset  │──── USDC ──►     │
│    buyCollateral)          │  derived reserves│    (borrow)      │
│                            └──────────────────┘                  │
│                                                                  │
│         interest split: suppliers + reserves, by construction    │
└──────────────────────────────────────────────────────────────────┘
```

---

## Key features

| Feature                         | Description                                                                 |
| :------------------------------ | :--------------------------------------------------------------------------- |
| **Single-base market (Comet)**  | One borrowable asset; collateral is deposit-only, bounding risk per asset.  |
| **Signed-principal accounting** | One `int104` per account; supply and borrow are mutually exclusive states.  |
| **Rebasing ERC20 (`lmUSDC`)**   | The market itself is the token; balances grow in place with accrual.        |
| **Jump-rate interest model**    | Kinked borrow curve; supply rate derived so reserves never accrue negative. |
| **Absorb liquidations**         | Protocol wipes debt, seizes collateral, resells via `buyCollateral`.        |
| **Explicit bad debt**           | Shortfalls recognized at absorb time; reserves are derived and can go negative visibly. |
| **Pyth + Chainlink oracle**     | Pull-based primary with confidence intervals; independent deviation anchor. |
| **Immutable deployment**        | No proxy, no parameter setters; owner limited to reserves and pause flags.  |

---

## Architecture

```
                      ┌─────────────────────────────────┐
                      │        LENDING MARKET           │
                      │  (accounting, custody, ERC20)   │
                      │                                 │
                      │  supply / withdraw / transfer   │
                      │  borrow / repay (signed paths)  │
                      │  accrue / absorb / buyCollateral│
                      │  getReserves / withdrawReserves │
                      └────────┬───────────────┬────────┘
                               │               │
                    rates      ▼               ▼      validated prices
              ┌──────────────────────┐  ┌──────────────────────────┐
              │  INTEREST RATE MODEL │  │  PYTH + CHAINLINK ORACLE │
              │  (stateless, kinked  │  │  (staleness, confidence, │
              │   curve + derived    │  │   deviation anchor)      │
              │   supply rate)       │  │                          │
              └──────────────────────┘  └──────────────────────────┘
```

| Contract | Role |
| :------- | :--- |
| `LendingMarket.sol` | Singleton market: accounting, custody and the rebasing ERC20 |
| `InterestRateModel.sol` | Stateless kinked curve with a derived supply rate |
| `PythChainlinkOracle.sol` | Price validation pipeline: staleness, confidence band, Chainlink deviation anchor |

Every non-obvious decision is recorded as an ADR in [Guide 3](./docs/03-architecture.md#8-architecture-decision-records).

---

## Security and testing

The design specifies 14 system invariants ([Guide 6](./docs/06-security.md#2-system-invariants)), checked by 17 stateful invariant tests. The load-bearing ones:

```solidity
// INV-1: exact integer accounting (load-bearing)
sum(positive principals) == totalSupplyBase;
sum(negative principals) == totalBorrowBase;

// INV-2: indexes only grow
baseSupplyIndex' >= baseSupplyIndex;  baseBorrowIndex' >= baseBorrowIndex;

// INV-3/4: every rounding favors the protocol; the residual accrues to reserves
getReserves() non-decreasing except by absorb and withdrawReserves;

// INV-9: no action leaves an account undercollateralized
isBorrowCollateralized(account) after every health-reducing call;
```

| Area | Result |
| :--- | :----- |
| Tests | 331, all green: 236 unit, 43 in `test/fuzz`, 32 integration, 17 stateful invariant, 3 fork |
| Fuzzing | 41 of the 43 tests in `test/fuzz` take fuzzed inputs and run 1,000 times each (41,000 runs); the other 2 are deterministic. Each of the 17 invariant tests runs 1,000 sequences of 100 calls (1,700,000 calls) |
| Coverage | Above 95% on lines, statements, branches and functions on every contract |
| Fork tests | The oracle against the real Pyth pull contract and Chainlink feeds, and supply, borrow, accrual and repay against real USDC and WETH at a pinned mainnet block |
| Static analysis | Slither: 0 findings. Aderyn: 12 detector categories, all triaged (4 false positives, 8 intended design or accepted gas choices, none a vulnerability) |
| Bugs caught | The INV-1 invariant caught a self-transfer minting bug |

Every figure comes from the commands in [Testing Documentation](./docs/tests/README.md#reproducing-the-numbers), which also catalogues each test and maps each invariant to what asserts it. Static analysis triage: [Static Analysis](./docs/tests/14-static-analysis.md).

---

## Getting started

Requires [Foundry](https://getfoundry.sh/) and Git.

```bash
git clone https://github.com/GushALKDev/evm-lending-borrowing-protocol.git
cd evm-lending-borrowing-protocol
forge install
forge build
forge test
```

```bash
forge test --fuzz-runs 10000                        # fuzz tests with more runs
forge test --match-contract InvariantsTest          # invariant suite
forge test --match-path "test/integration/*"        # local deployment, real oracle over MockPyth
FORK_RPC_URL=<eth-mainnet-rpc> forge test --match-path "test/fork/*"   # no-op without FORK_RPC_URL
forge coverage --report lcov
```

Fork scope (what runs against mainnet and why `absorb`, `buyCollateral` and wBTC do not): [Fork Tests](./docs/tests/13-fork.md#what-is-deliberately-out-of-scope-and-why).

### Local deployment

Every external address must point at a deployed contract first: the placeholder defaults have no code, so the market constructor reverts without them.

```bash
anvil
export USDC=<addr> WETH=<addr> WBTC=<addr> PYTH=<addr>
export USDC_CL_FEED=<addr> WETH_CL_FEED=<addr> WBTC_CL_FEED=<addr>
export USDC_PYTH_ID=<id> WETH_PYTH_ID=<id> WBTC_PYTH_ID=<id>   # optional: OWNER, GUARDIAN
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

`test/integration/DeployScript.t.sol` rehearses this exact flow in-test, against mock dependencies exported into the same variables.

---

## Roadmap

70 of the 72 PoC items are done. Every item with its scope and deliverables: [docs/ROADMAP.md](./docs/ROADMAP.md).

- [x] Phase 0: Setup & Infrastructure (6/6)
- [x] Phase 1: Core: Index Accounting & Storage (8/8)
- [x] Phase 2: Interest Rate Model (6/6)
- [x] Phase 3: Supply & Withdraw (8/8)
- [x] Phase 4: Borrow & Repay (7/7)
- [x] Phase 5: Oracle (Pyth + Chainlink) (10/10)
- [x] Phase 6: Absorb Liquidation (8/8)
- [x] Phase 7: Reserves & Protocol Management (6/6)
- [ ] Phase 8: Invariant & Fuzz Testing + Audit Prep (11/13)
  - [x] 8.1 Invariant: cash conservation via ghost tracking
  - [x] 8.2 Invariant: signed principals sum exactly to the supply and borrow totals
  - [x] 8.3 Invariant: monotone indexes, `supplyRate <= borrowRate`, reserves only decrease by absorb or `withdrawReserves`
  - [x] 8.4 Invariant: no action leaves an account below the borrow threshold; collateral totals match per-user sums
  - [x] 8.5 Fuzz: conversion, rate and quote math with directed-rounding assertions
  - [x] 8.6 End-to-end integration on a local deployment, plus a deploy script rehearsal
  - [x] 8.7 Fork tests against real USDC, WETH, Pyth and Chainlink on an Ethereum mainnet fork
  - [x] 8.8 Static analysis (Slither, Aderyn) with no criticals
  - [x] 8.9 Coverage above 95% on all contracts
  - [x] 8.10 Liquidation (`absorb`, `buyCollateral`) through the real oracle's fee and refund path
  - [x] 8.11 Invariant suite completed against the [Guide 6](./docs/06-security.md#7-testing-plan) testing plan
  - [ ] 8.12 Audit checklist from [Guide 6](./docs/06-security.md#6-audit-checklist) completed, plus an internal line-by-line review
  - [ ] 8.13 Findings remediation and a re-run of the full suite
- [ ] Phase 9: Future Work, post-PoC and outside its scope (0/6)

---

## Documentation

| Document | Covers |
| :------- | :----- |
| [Documentation index](./docs/README.md) | Master index and reading orders |
| [Roadmap](./docs/ROADMAP.md) | Implementation phases and progress (72 PoC items + 6 future work) |
| [Guide 1: Fundamentals](./docs/01-fundamentals.md) | Money markets and the single-base model |
| [Guide 2: Mathematics](./docs/02-mathematics.md) | Indexes, rates, liquidation, rounding policy |
| [Guide 3: Architecture](./docs/03-architecture.md) | Contracts, state, flows, ADRs |
| [Guide 4: Trade-offs](./docs/04-tradeoffs.md) | Risks, mitigations, risk matrix |
| [Guide 5: Implementation](./docs/05-implementation.md) | Interfaces, errors, access control |
| [Guide 6: Security](./docs/06-security.md) | Threat model, invariants, testing plan |
| [Testing Documentation](./docs/tests/README.md) | Per-test inventory, invariant coverage map, fork and static analysis |

---

## Project structure

```
src/
  LendingMarket.sol          Singleton market (accounting + custody + ERC20)
  InterestRateModel.sol      Kinked curve, derived supply rate
  PythChainlinkOracle.sol    Price validation pipeline
  interfaces/                ILendingMarket, IInterestRateModel, IPriceOracle
test/
  unit/  fuzz/  invariant/  integration/  fork/  mocks/
script/
  Deploy.s.sol               Deployment script
docs/                        Guides, roadmap and testing documentation
```

---

## Tech stack

Solidity 0.8.26 · Foundry (unit, fuzz, invariant, integration and fork tests) · OpenZeppelin v5 · Solady · Pyth Network + Chainlink

## License

MIT, see [LICENSE](./LICENSE).

## Author

[@GushALKDev](https://github.com/GushALKDev), Gustavo Martín ([LinkedIn](https://www.linkedin.com/in/gustavomaral/)).

## Acknowledgments

- [Compound III (Comet)](https://docs.compound.finance/): architectural reference (design only; no code copied or forked)
- [OpenZeppelin](https://openzeppelin.com/) and [Solady](https://github.com/Vectorized/solady): contract libraries
- [Foundry](https://getfoundry.sh/): development framework and testing suite
- [Pyth Network](https://pyth.network/) and [Chainlink](https://chain.link/): oracle infrastructure
