import type { ComponentProps } from 'react'
import { chain, explorerAddress, links } from '../config/chain'
import { navigate, pages, type Page } from '../hooks/useRoute'
import { formatBps } from '../lib/format'
import type { MarketModel } from '../lib/model'
import { Mark } from './icons'
import { WalletButton } from './Wallet'

/** Link to a page of this app: a plain click switches page without a reload, a modified click keeps the browser's behavior. */
export function Link({ href, ...rest }: ComponentProps<'a'> & { href: string }) {
  return (
    <a
      href={href}
      {...rest}
      onClick={(e) => {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
        e.preventDefault()
        navigate(href)
      }}
    />
  )
}

export function Header({ page, onConnect, onFaucet }: { page: Page; onConnect: () => void; onFaucet: () => void }) {
  return (
    <header className="site-header">
      <div className="wrap">
        <Link className="wordmark" href="/">
          <Mark />
          Lending Market
        </Link>
        <span className="network">{chain.name}</span>
        <nav className="page-nav" aria-label="Pages">
          {pages.map((p) => (
            <Link key={p.page} className="page-link" href={p.path} aria-current={p.page === page ? 'page' : undefined}>
              {p.label}
            </Link>
          ))}
        </nav>
        <div className="header-actions">
          <button className="btn btn-faucet" onClick={onFaucet} aria-label="Get test tokens">
            <span>Test tokens</span>
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M8 2.5c2 2.6 3.5 4.6 3.5 6.6a3.5 3.5 0 0 1-7 0c0-2 1.5-4 3.5-6.6z" fill="none" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
          <WalletButton onConnect={onConnect} />
        </div>
      </div>
    </header>
  )
}

export function Notice() {
  return (
    <div className="notice">
      <div className="wrap">
        Testnet proof of concept with tokens that have no value. Not audited. Prices are Chainlink's, pushed through a Pyth
        stand-in: <Link href="/how-it-works#oracle">how and why</Link>.
      </div>
    </div>
  )
}

export function HowItWorks({ model }: { model: MarketModel }) {
  const st = model.static
  const d = model.deployment
  return (
    <section className="section" id="how">
      <div className="wrap">
        <div className="section-head">
          <h2>How this market works</h2>
          <p>Four design decisions shape everything in this market. Each one is written up in the repository's guides.</p>
        </div>
        <div className="mechanics">
          <div className="mechanic">
            <h3>One borrowable asset</h3>
            <p>
              Only USDC can be borrowed. WETH and wBTC are collateral only: they earn nothing and are never lent out, so a
              bad debt can only ever be owed in USDC, and the risk of each collateral is bounded by its own cap.
            </p>
          </div>
          <div className="mechanic">
            <h3>One signed balance</h3>
            <p>
              Your USDC position is a single signed number: positive while you supply, negative while you borrow. A
              withdrawal that goes past zero is a borrow, which is why the Borrow tab withdraws any supply first.
            </p>
          </div>
          <div className="mechanic">
            <h3>Two edges for every price</h3>
            <p>
              The oracle reports a price and a confidence half-width. Borrowing capacity values collateral at the low edge
              and debt at the high edge. Absorb eligibility values collateral at the high edge instead, so uncertainty in
              the collateral price counts in the borrower's favor; debt stays at the high edge in both.
            </p>
          </div>
          <div className="mechanic">
            <h3>Absorb, then sell</h3>
            <p>
              An underwater account is absorbed by the protocol: its debt is cleared against reserves and its collateral
              seized, credited at the liquidation factor. The storefront then sells the seized collateral below the oracle
              price to anyone who pays in USDC.
            </p>
          </div>
        </div>

        <div className="oracle-note" id="oracle">
          <div>
            <h3>Where the prices come from</h3>
            <p>
              In the production configuration (script/Deploy.s.sol) the oracle reads Pyth, a pull oracle, and checks
              every price against Chainlink. Since August 2026
              Pyth's price API needs a paid key (
              <a href={links.pythUpgrade} target="_blank" rel="noreferrer">
                Pyth's announcement
              </a>
              ), which a free demo cannot use. So this deployment swaps Pyth for{' '}
              <a href={explorerAddress(d.pyth)} target="_blank" rel="noreferrer">
                DemoPyth
              </a>
              , a testnet stand-in that accepts unsigned prices.
            </p>
            <p>
              DemoPyth checks no signatures, so anyone can push a made-up price. The oracle contract is the repository's
              own, unchanged, and it rejects any price more than {formatBps(st.maxDeviationBps)} away from the Chainlink
              anchor, older than {st.maxStaleness.toString()} seconds, or with a confidence half-width above{' '}
              {formatBps(st.maxConfidenceBps)}. Each call also writes its own update just before reading it, so a price
              pushed by someone else in between is never the one it reads.
            </p>
          </div>
          <div className="flow" aria-label="What happens in a call that needs a price">
            <p className="muted" style={{ marginBottom: 4 }}>
              In every call that needs a price, such as a borrow:
            </p>
            <div className="flow-step">
              <b>1</b>
              <span>The app reads the latest Chainlink answer for USDC, ETH and BTC on {chain.name}.</span>
            </div>
            <div className="flow-step">
              <b>2</b>
              <span>
                It encodes each one as a Pyth price with a {formatBps(d.demoConfBps)} confidence half-width, timestamped
                with the latest block.
              </span>
            </div>
            <div className="flow-step">
              <b>3</b>
              <span>The market forwards the update to the oracle, which stores it in DemoPyth and validates it.</span>
            </div>
            <div className="flow-step">
              <b>4</b>
              <span>Only then does the market run the health check, all inside the same transaction.</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

export function Footer({ model }: { model: MarketModel | null }) {
  return (
    <footer className="site-footer">
      <div className="wrap">
        <p>Proof of concept, not audited. Testnet tokens have no value.</p>
        <nav className="footer-links" aria-label="Links">
          <a href={links.repo} target="_blank" rel="noreferrer">
            Source code
          </a>
          <a href={links.docs} target="_blank" rel="noreferrer">
            Documentation
          </a>
          {model ? (
            <a href={explorerAddress(model.deployment.market)} target="_blank" rel="noreferrer">
              Market contract
            </a>
          ) : null}
          <a href={links.author} target="_blank" rel="noreferrer">
            Built by Gustavo Martín
          </a>
        </nav>
      </div>
    </footer>
  )
}
