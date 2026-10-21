import { useState } from 'react'
import { AccountCard } from './components/Account'
import { FaucetDialog } from './components/FaucetDialog'
import { Hero } from './components/Hero'
import { Liquidations } from './components/Liquidations'
import { CollateralCard, RatesCard } from './components/MarketCards'
import { Footer, Header, HowItWorks, Notice } from './components/Sections'
import { Toasts } from './components/Toasts'
import { ConnectDialog } from './components/Wallet'
import { chain, deployment, links } from './config/chain'
import { useModel } from './hooks/useModel'

function NotDeployed() {
  return (
    <main className="wrap hero">
      <div className="hero-head">
        <h1>The market is not deployed on {chain.name} yet.</h1>
        <p className="hero-sub">
          Run the testnet deployment script to create it; it writes the addresses this app reads. Until then, the{' '}
          <a href={links.repo}>source code</a> is the place to look.
        </p>
      </div>
    </main>
  )
}

function Market() {
  const { model, error } = useModel()
  const [connectOpen, setConnectOpen] = useState(false)
  const [faucetOpen, setFaucetOpen] = useState(false)
  const openConnect = () => {
    setFaucetOpen(false)
    setConnectOpen(true)
  }

  return (
    <>
      <Header onConnect={openConnect} onFaucet={() => setFaucetOpen(true)} />
      <Notice />
      {model ? (
        <main id="top">
          <Hero model={model} />
          <div className="wrap main-grid">
            <div className="stack">
              <AccountCard model={model} onConnect={openConnect} onFaucet={() => setFaucetOpen(true)} />
            </div>
            <div className="stack">
              <RatesCard model={model} />
              <CollateralCard model={model} />
            </div>
          </div>
          <Liquidations model={model} />
          <HowItWorks model={model} />
        </main>
      ) : (
        <main className="wrap hero">
          {error ? (
            <div className="callout" data-tone="warn" role="alert">
              The market could not be read from {chain.name}. The RPC may be rate limiting requests; the page retries on
              its own.
            </div>
          ) : (
            <p className="muted">Reading the market from {chain.name}…</p>
          )}
        </main>
      )}
      <Footer model={model} />
      {connectOpen ? <ConnectDialog onClose={() => setConnectOpen(false)} /> : null}
      {faucetOpen && model ? <FaucetDialog model={model} onClose={() => setFaucetOpen(false)} onConnect={openConnect} /> : null}
      <Toasts />
    </>
  )
}

export function App() {
  return deployment ? <Market /> : <NotDeployed />
}
