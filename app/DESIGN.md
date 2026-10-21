# Design notes

Working notes for the demo app, so the next PoC frontends can share the same system.

## Subject

A money market proof of concept on a testnet. Visitors are protocol founders, CTOs and engineers
judging the engineering behind it, plus anyone who wants to try supplying and borrowing. The page has
two jobs: let them use the market without friction, and make the protocol's solvency mechanics
visible (derived reserves, signed balances, confidence bands, absorb).

## The one memorable element

The market's balance sheet, drawn as two bars of equal length: what the market holds (cash and
borrows) against what it owes (supplier balances and reserves). Reserves are never stored in the
contract, they are derived from this identity, so the drawing is the protocol's accounting rather
than decoration. Bad debt appears as a red shortfall the moment it is recognized. Everything else
stays quiet.

## Tokens

Color (light / dark):

| Role | Light | Dark |
| :-- | :-- | :-- |
| Ground | #EDF0EE | #0E1412 |
| Surface | #FFFFFF | #151C1A |
| Ink | #16201D | #E2E8E5 |
| Verdigris (supply, reserves, primary actions) | #2F6B5E | #7DB5A6 |
| Slate (debt, borrow side) | #46668A | #8AA6C7 |
| Red (shortfall, liquidation) | #B23B2A | #E07A66 |

The verdigris ties the demos to the brand site's copper-green accent. Cool mineral greys instead of
the warm cream that most generated pages default to.

Type: IBM Plex Sans for everything, with tabular figures for numbers; IBM Plex Mono only for
addresses and hashes. Plex comes from an engineering lineage, which fits a protocol built by someone
from industrial control systems. Sentence case throughout, no all-caps labels.

## Layout

```
header   wordmark, network, test tokens, wallet
notice   one line: testnet, not audited, where prices come from
hero     headline + balance sheet + four rates
grid     your position and actions (left, wider) | rates curve and collateral (right)
section  liquidations: check an account, storefront, accounts with debt
section  how it works (four mechanics + the oracle note)
footer
```

Left-aligned throughout. Two columns from 1024 px, one below.

## Rules

- Copy names what the user does: Supply, Withdraw, Borrow, Repay. The button that says Supply
  produces a toast that says Supplied.
- Every preview shows before and after, computed with the contract's own rounding.
- Errors say what happened and what to do, decoded from the contract's custom errors.
- Motion only where something changed: the balance sheet bars ease to new widths, balances tick
  with accrued interest.
