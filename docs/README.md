# 📚 Complete Guide: EVM Lending / Borrowing Protocol (PoC)

**Version:** 1.0
**Status:** Portfolio/Educational Project

---

## 🎯 Quick Start

| Document                    | Description                        | Status      |
| :-------------------------- | :--------------------------------- | :---------- |
| **[README](../README.md)**  | Project overview and setup         | ✅ Complete |
| **[ROADMAP](./ROADMAP.md)** | Implementation phases and progress | ✅ Complete |
| **[LICENSE](../LICENSE)**   | MIT License                        | ✅ Complete |

---

## 📖 Technical Guides

### Core Concepts (Start Here)

1. **[Fundamental Concepts](./01-fundamentals.md)**
    - What a money market is
    - Supply and borrow mechanics
    - The single-base Comet model and why collateral is inert
    - Actors and their incentives
    - Differences vs Compound V2 and Aave V3, and the reasons

2. **[Protocol Mathematics](./02-mathematics.md)**
    - Index accounting (principal and present value)
    - Interest accrual and utilization (including U > 1)
    - Jump-rate model and the derived supply rate
    - Interest split and reserve growth (the directional rounding theorem)
    - Collateralization, health, and confidence bands
    - Liquidation math: absorb, coverage condition, buyCollateral pricing
    - The complete rounding policy catalogue

### Architecture & Implementation

3. **[Technical Architecture & Data Flow](./03-architecture.md)**
    - Component diagram and contract set
    - State layout (packed structs, derived reserves)
    - Oracle system (Pyth pull + Chainlink anchor) with its ADR
    - Execution flows: supply, withdraw, borrow, repay, accrue, absorb, buyCollateral
    - Design patterns (accrue-first CEI, pull over push, custom errors)
    - ADRs: single-base, absorb liquidation, immutability, derived rate, signed principal

4. **[Trade-offs and Risk Matrix](./04-tradeoffs.md)**
    - Twelve risks, each as risk / mitigation / residual
    - Oracle manipulation and failure, bad debt, MEV, rate manipulation
    - 100% utilization, reserve depletion, rounding, inflation and donation attacks
    - Risk matrix and the Future Work boundary

5. **[Solidity Implementation](./05-implementation.md)**
    - Tech stack (Foundry, OpenZeppelin v5, Solady, Pyth SDK)
    - Core data structures with packing
    - Function-by-function interface contracts (pre and postconditions)
    - Precision and decimals rules, custom error catalogue
    - Access control matrix and pre-deployment checklist

### Security

6. **[Security](./06-security.md)**
    - Threat model and critical assets
    - The full system invariant list (INV-1 to INV-14)
    - Attack vectors with mitigations
    - Adversarial scenarios: crashes, oracle outages, insolvency, bank runs, depeg
    - Pause and circuit-breaker philosophy
    - Audit checklist and the unit, fuzz, invariant, and fork testing plan (fork-tested oracle and token integration)

---

## 🗂️ Documentation Structure

```
docs/
├── README.md                    # This file
├── ROADMAP.md                   # Implementation roadmap (10 phases, 76 items)
│
├── 01-fundamentals.md           # Start here
├── 02-mathematics.md            # Core formulas and rounding policy
├── 03-architecture.md           # System design and ADRs
├── 04-tradeoffs.md              # Risk analysis
├── 05-implementation.md         # Solidity interface specification
└── 06-security.md               # Threat model, invariants, testing plan
```

---

## 🎓 Recommended Reading Order

### For Developers

1. [Fundamental Concepts](./01-fundamentals.md) - Understand the model
2. [Protocol Mathematics](./02-mathematics.md) - Learn the formulas
3. [Technical Architecture](./03-architecture.md) - See how it fits together
4. [Solidity Implementation](./05-implementation.md) - Study the interface contracts
5. [Security](./06-security.md) - Understand the invariants you must not break
6. [ROADMAP](./ROADMAP.md) - Build it in order

### For Auditors

1. [Technical Architecture](./03-architecture.md) - System overview and ADRs
2. [Protocol Mathematics](./02-mathematics.md) - Rounding directions, coverage condition
3. [Security](./06-security.md) - Invariants (INV-1 first), scenarios, checklist
4. [Trade-offs](./04-tradeoffs.md) - Known risks and accepted residuals
5. [Solidity Implementation](./05-implementation.md) - Pre/postconditions to verify

### For Researchers

1. [Fundamental Concepts](./01-fundamentals.md) - Model introduction and comparisons
2. [Protocol Mathematics](./02-mathematics.md) - The directional solvency theorem
3. [Trade-offs](./04-tradeoffs.md) - Design decisions and Future Work
4. [Technical Architecture ADRs](./03-architecture.md#8-architecture-decision-records) - The reasoning record

---

## 📊 Progress Tracking

See [ROADMAP.md](./ROADMAP.md) for detailed implementation progress across 10 phases and 76 trackable items.

**Current Status:** Phase 0 (Documentation) - Complete ✅

---

## 🏛️ Attribution

All smart contract code in this repository is **original and written from scratch**. The architectural design is **inspired by Compound III (Comet)**: the single borrowable base asset, index-based signed-principal accounting, and the absorb/buyCollateral liquidation model follow Comet's design space. Compound is referenced only as inspiration for that design space; **no Compound code is copied or forked**, and several components deliberately diverge from Comet (derived supply rate, immutable deployment, Pyth-based oracle) with the reasoning recorded in the [ADRs](./03-architecture.md#8-architecture-decision-records).

---

## 📝 Contributing

This is a portfolio/educational project. While not actively seeking contributions, feedback and suggestions are welcome via issues.

---

## ⚖️ License

This project is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.

---

## 🔗 External Resources

- **Foundry Documentation:** https://book.getfoundry.sh/
- **Compound III (Comet) Docs:** https://docs.compound.finance/ (architectural inspiration)
- **OpenZeppelin Contracts:** https://docs.openzeppelin.com/contracts/
- **Solady:** https://github.com/Vectorized/solady (gas-optimized libraries)
- **Pyth Network:** https://docs.pyth.network/ (primary oracle)
- **Chainlink Price Feeds:** https://docs.chain.link/data-feeds (deviation anchor)
- **Aave V3 Docs:** https://docs.aave.com/ (design comparison reference)

---

**Maintained by:** @GushALKDev (Portfolio Project)
