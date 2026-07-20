# 🏦 EVM Lending / Borrowing Protocol (PoC)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

A **single-market money market** in the style of Compound III (Comet): one borrowable base asset (USDC), isolated supply-only collateral (WETH, wBTC), index-based interest accrual, and protocol-absorbed liquidations. Built as a proof of concept of DeFi lending primitives with a thesis of **audit-ready rigor and provable solvency**.

> ⚠️ **DISCLAIMER:** This is a portfolio/educational project demonstrating advanced smart contract development. **All code is written from scratch**; the architecture is inspired by Compound III, never copied or forked. NOT audited - do not use in production.

---

## 🎯 What is this?

A DeFi money market where:

- **Suppliers** deposit USDC and hold a rebasing balance (`lmUSDC`) that grows with interest
- **Borrowers** post WETH/wBTC collateral and borrow USDC against it
- **Liquidator bots** absorb underwater accounts and buy the seized collateral at a discount

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

## ✨ Key Features

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

## 🏗️ Architecture

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

---

## 📚 Documentation

Comprehensive documentation is available in [`/docs`](./docs/):

| Document                                                       | Description                                  |
| :-------------------------------------------------------------- | :--------------------------------------------- |
| **[📋 Complete Index](./docs/README.md)**                      | Master index - start here                    |
| **[🗺️ Roadmap](./docs/ROADMAP.md)**                            | Implementation phases & progress (76 items)  |
| **[📖 Guide 1: Fundamentals](./docs/01-fundamentals.md)**      | Money markets & the single-base model        |
| **[🧮 Guide 2: Mathematics](./docs/02-mathematics.md)**        | Indexes, rates, liquidation, rounding policy |
| **[🏗️ Guide 3: Architecture](./docs/03-architecture.md)**      | Contracts, state, flows, ADRs                |
| **[⚖️ Guide 4: Trade-offs](./docs/04-tradeoffs.md)**           | Risks, mitigations, risk matrix              |
| **[💻 Guide 5: Implementation](./docs/05-implementation.md)**  | Interfaces, errors, access control           |
| **[🔒 Guide 6: Security](./docs/06-security.md)**              | Threat model, invariants, testing plan       |

---

## 🛠️ Tech Stack

| Component           | Technology                    |
| :------------------ | :---------------------------- |
| **Smart Contracts** | Solidity 0.8.26               |
| **Framework**       | Foundry                       |
| **Testing**         | Forge (unit, fuzz, invariant, integration, fork) |
| **Libraries**       | OpenZeppelin v5, Solady       |
| **Oracles**         | Pyth Network + Chainlink      |
| **Standards**       | ERC-20 (rebasing)             |

---

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/GushALKDev/evm-lending-borrowing-protocol.git
cd evm-lending-borrowing-protocol

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with coverage
forge coverage
```

### Local Development

```bash
# Start local node
anvil

# Deploy to local node
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

---

## 🧪 Testing

```bash
# Unit tests
forge test

# Fuzz tests (more runs)
forge test --fuzz-runs 10000

# Invariant tests
forge test --match-contract InvariantTest

# Integration tests (local deployment, mocked oracle stack)
forge test --match-path "test/integration/*"

# Fork tests (fork-tested oracle and token integration; needs a mainnet RPC)
forge test --match-path "test/fork/*" --fork-url $MAINNET_RPC_URL

# Coverage report
forge coverage --report lcov
```

> **On fork testing:** the fork suite validates this protocol's **real external dependencies** on a mainnet fork: the `PythChainlinkOracle` against the live Pyth pull contract and live Chainlink feeds, and the market flows against the real USDC, WETH, and wBTC contracts. This protocol is **not** a fork of any lending protocol; the lending logic is original and self-contained, and is covered by the unit, fuzz, and invariant suites.

### Key Invariants

The protocol maintains these properties at all times (full list in [Guide 6](./docs/06-security.md#2-system-invariants)):

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

---

## 📁 Project Structure

```
evm-lending-borrowing-protocol/
├── docs/                        # Comprehensive documentation
│   ├── README.md                # Master index
│   ├── ROADMAP.md               # Implementation roadmap
│   ├── 01-fundamentals.md       # Guide 1: Core concepts
│   ├── 02-mathematics.md        # Guide 2: Protocol math
│   ├── 03-architecture.md       # Guide 3: System design
│   ├── 04-tradeoffs.md          # Guide 4: Risks & solutions
│   ├── 05-implementation.md     # Guide 5: Solidity interfaces
│   └── 06-security.md           # Guide 6: Security analysis
├── src/                         # Smart contracts
│   ├── LendingMarket.sol        # Singleton market (accounting + custody + ERC20)
│   ├── InterestRateModel.sol    # Kinked curve, derived supply rate
│   ├── PythChainlinkOracle.sol  # Price validation pipeline
│   └── interfaces/              # ILendingMarket, IInterestRateModel, IPriceOracle
├── test/                        # Test files
│   ├── unit/                    # Unit tests
│   ├── fuzz/                    # Fuzz tests
│   ├── invariant/               # Invariant tests
│   ├── integration/             # End-to-end tests (local, mocked oracles)
│   └── fork/                    # Mainnet-fork tests (live Pyth/Chainlink, real tokens)
├── script/                      # Deployment scripts
├── LICENSE                      # MIT License
└── README.md
```

---

## 🎓 What This Project Demonstrates

This project showcases advanced smart contract development skills through **original implementation from scratch**:

**Documentation (Complete):**

- [x] Comet-style single-base money market architecture
- [x] Index-based accounting with signed principals and a rebasing ERC20
- [x] Directional rounding analysis with a provable reserve-growth theorem
- [x] Absorb liquidation model with explicit bad-debt accounting
- [x] Oracle design with confidence-band health policies (Pyth + Chainlink)
- [x] Full ADR record for every non-obvious decision
- [x] Threat model, 14 system invariants, and a unit, fuzz, invariant, and fork testing plan (fork-tested oracle and token integration)

**Implementation (Pending - see [ROADMAP](./docs/ROADMAP.md)):**

- [ ] Core contracts (LendingMarket, InterestRateModel, PythChainlinkOracle)
- [ ] Full test pyramid: unit, fuzz, invariant, integration, and fork (oracle and token integration)
- [ ] Deployment scripts and audit-prep pass

---

## 🤝 Contributing

This is a portfolio project, but contributions are welcome! Feel free to:

- Open issues for bugs or suggestions
- Submit PRs for improvements
- Fork and adapt for your own learning

---

## 📜 License

This project is licensed under the **MIT License** - see the [LICENSE](./LICENSE) file for details.

---

## 👤 Author

**[GushALKDev]**

- GitHub: [@GushALKDev](https://github.com/GushALKDev)
- LinkedIn: [Gustavo Martín](https://www.linkedin.com/in/gustavomaral/)

---

## 🙏 Acknowledgments

- [Compound III (Comet)](https://docs.compound.finance/) - Architectural inspiration (design only; no code copied or forked)
- [OpenZeppelin](https://openzeppelin.com/) - Security standards and contract libraries
- [Foundry](https://getfoundry.sh/) - Development framework and testing suite
- [Solady](https://github.com/Vectorized/solady) - Gas-optimized libraries
- [Pyth Network](https://pyth.network/) & [Chainlink](https://chain.link/) - Oracle infrastructure

---

<p align="center">
  <i>Built with ❤️ to demonstrate what's possible in DeFi</i>
</p>
