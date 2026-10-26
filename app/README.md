# Lending Market demo app

A web app for the money market in this repository, running on Base Sepolia with testnet tokens. Visitors can
read the whole market without a wallet, and with one they can supply and withdraw USDC, post WETH or wBTC as
collateral, borrow and repay, absorb underwater accounts and buy seized collateral from the storefront.

Proof of concept, not audited, for educational purposes. The tokens are testnet stand-ins with no value.

Live: https://lending-poc.tesselium.com

## What it shows

- **The balance sheet.** Cash plus borrows against supplier balances plus reserves. Reserves are derived in the
  contract, never stored, so bad debt appears as a shortfall the moment an absorb recognizes it.
- **Positions as the contract sees them.** Balances tick with accrued interest. The app projects both indexes
  to the current second with the contract's own formulas and rounding (`src/lib/market.ts`), checked to the wei
  against a local deployment (`scripts/parity.test.ts`).
- **Previews before every call.** Each action shows the position before and after, and the call is simulated
  before the wallet asks for a signature, so a revert arrives as a sentence (`src/lib/errors.ts`) instead of a
  failed transaction.
- **A price shock simulator.** Moves collateral prices in the browser and shows when the position becomes
  absorbable and what absorb would do with it, liquidation factor included.

## Where prices come from

On mainnet the oracle reads Pyth and checks every price against a Chainlink anchor. Since the Pyth Core upgrade
in August 2026, Pyth's Hermes API needs a paid key, so this deployment replaces Pyth with
[`DemoPyth`](../script/testnet/DemoPyth.sol), a testnet stand-in that takes unsigned updates.

Before each call that needs a price (borrow, collateral withdrawal with debt, absorb, buy), the app reads the
Chainlink answers on Base Sepolia, encodes each one as a Pyth price with a 0.05% confidence half-width and the
latest block's timestamp (`src/lib/pyth.ts`), and passes the update to the market, which forwards it to the
oracle. The oracle contract is the repository's own, unchanged: it rejects a price more than 3% from the Chainlink
anchor, older than 60 seconds, or with a confidence half-width above 2%. That deviation check is what bounds a
forged update, since DemoPyth checks no signatures. DemoPyth also keeps the last write rather than the newest
`publishTime`, so a price someone else pushes in the same block is overwritten by the update the call carries.

## Run it locally

Requires Node 22 and, for a local chain, Foundry.

```bash
cd app
npm install
npm run dev                  # reads the Base Sepolia deployment
```

Against a local chain instead (anvil, three mock Chainlink feeds and a full deployment):

```bash
./app/scripts/local-chain.sh                 # from the repo root; writes src/config/deployments/31337.json
cd app && VITE_CHAIN_ID=31337 npm run dev
```

On the local chain the mock feeds stop updating, so after an hour the oracle treats the anchors as stale and
price-dependent calls revert, as they would on a real network. Rerun the script for a fresh deployment.

Checks:

```bash
npm run typecheck
npm test                                                   # unit tests of the market math
LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts     # parity against a local deployment
```

The parity suite checks every rounding the app mirrors against the contracts, to the wei: rates and indexes,
oracle prices, storefront quotes, the debt and capacities the market reports in its own revert data, the
principal each supply, withdraw, borrow and repay leaves, and absorb settlement with a surplus and with bad debt.
It reverts the chain to a snapshot when it finishes, so it can run again. CI runs it on every push, against a fresh
local deployment.

## Deploy the contracts to Base Sepolia

From the repository root, with a fresh key used only for this demo:

```bash
cast wallet import demo-deployer --interactive    # stores the key encrypted, asks for a password
```

Fund that address with a little Base Sepolia ETH from one of the
[Base faucets](https://docs.base.org/base-chain/network-information/network-faucets), then:

```bash
forge script script/testnet/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

The script simulates everything first, including a check that every Chainlink feed is fresh, and only then
broadcasts. It deploys the faucet and tokens, DemoPyth, the rate model, the oracle and the market with the same
parameters as `script/Deploy.s.sol`, and supplies 500,000 USDC on behalf of the faucet contract, which cannot
withdraw it. On a broadcast it writes `app/src/config/deployments/84532.json`, which the app reads: commit that
file. A run without `--broadcast` leaves the file alone.

Then open the seed borrow, with the same key, so the demo starts at 78% utilization, just under the rate
model's 80% kink, instead of idle:

```bash
forge script script/testnet/SeedBorrow.s.sol \
  --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

It posts 500 WETH and borrows 390,000 USDC. It is a separate run because the borrow carries a price that the
oracle rejects once it is older than 60 seconds; if a slow RPC makes it revert with `StalePrice`, run it again.

To verify the contracts on BaseScan, add `--verify --etherscan-api-key <key>` (an Etherscan API V2 key covers
BaseScan).

The testnet tooling has its own tests, kept apart so the protocol's test figures stay unchanged:

```bash
FOUNDRY_PROFILE=testnet forge test
```

## Deploy the app to Cloudflare Workers

The app runs as `lending-poc`, an assets-only Worker: there is no Worker script. `wrangler.jsonc` points it at
`dist/` and holds the SPA fallback, which serves `index.html` for every page path (`/liquidations`,
`/how-it-works`). `public/_headers` holds the cache and security headers; Vite copies it into `dist/`.

The `og:image` and `og:url` tags in `index.html` carry the absolute URL of the app's domain, lending-poc.tesselium.com,
since link preview crawlers do not resolve relative paths: change them if the app moves to another domain.

First deploy, from a terminal in `app/`:

```bash
npx wrangler login           # authorizes wrangler on your Cloudflare account, in the browser
npm run deploy               # builds, deploys and prints the workers.dev URL
```

Deploys on push: in the Cloudflare dashboard, connect this repository to the Worker (Workers Builds) with root
directory `app`, build command `npm run build` and deploy command `npx wrangler deploy`. The Worker name in
`wrangler.jsonc` must match the Worker in the dashboard, or the build fails.

`VITE_RPC_URL` is optional, for when the public Base Sepolia RPC rate limits the page. Vite reads it at build time,
so on Workers Builds it goes in the build variables (Settings, Build), not in the runtime variables. Any key in it
is visible to visitors, so restrict it to the site's domain at the provider.

The Workers Free plan is enough: the site is static, there is no Worker script, and requests to static assets are
free.

## Structure

```
src/
  abi/          generated from the Foundry build (npm run abi after forge build)
  config/       chain, links, and the deployment files written by the script
  lib/          market math, price update encoding, error messages, formatting
  hooks/        chain reads, the derived model, transactions, toasts, the current page
  components/   the interface
scripts/
  local-chain.sh     local rehearsal of the testnet deployment
  parity.test.ts     app math against a local deployment
  sync-abi.mjs       regenerates src/abi
```

Design notes, for the next demo apps: [DESIGN.md](./DESIGN.md).
