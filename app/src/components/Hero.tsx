import { chain, explorerAddress } from '../config/chain'
import { formatCompact, formatPct, formatUsd } from '../lib/format'
import { mulDiv } from '../lib/market'
import type { MarketModel } from '../lib/model'

interface Segment {
  key: string
  label: string
  value: bigint
  className: string
}

function Bar({ segments, scale, label }: { segments: Segment[]; scale: bigint; label: string }) {
  return (
    <div className="bar" role="img" aria-label={label}>
      {segments.map((s) => {
        const share = scale > 0n ? Number((s.value * 10_000n) / scale) / 100 : 0
        if (share <= 0) return null
        return (
          <div
            key={s.key}
            className={`seg ${s.className}`}
            style={{ flex: `0 0 ${Math.max(share, 0.8)}%` }}
            title={`${s.label}: ${formatCompact(s.value, 6)} USDC`}
          >
            {share > 16 ? <span className="seg-text">{s.label}</span> : null}
          </div>
        )
      })}
    </div>
  )
}

function Legend({ items }: { items: Segment[] }) {
  return (
    <div className="legend" style={{ marginTop: 14, marginBottom: 0 }}>
      {items.map((s) => (
        <span key={s.key}>
          <i className={s.className} style={{ height: 10, width: 10, borderRadius: 3 }} />
          {s.label} <strong style={{ fontWeight: 500 }}>{formatCompact(s.value, 6)}</strong>
        </span>
      ))}
    </div>
  )
}

export function BalanceSheet({ model }: { model: MarketModel }) {
  const { cash, totalBorrow, totalSupply, reserves } = model
  const shortfall = reserves < 0n ? -reserves : 0n
  const positiveReserves = reserves > 0n ? reserves : 0n
  const held = cash + totalBorrow
  const owed = totalSupply + positiveReserves
  const scale = held + shortfall > owed ? held + shortfall : owed
  const inventoryUSD = model.collaterals.reduce(
    (sum, c) => sum + mulDiv(c.inventory, c.price.price, 10n ** BigInt(c.info.decimals)),
    0n,
  )

  const heldSegs: Segment[] = [
    { key: 'cash', label: 'Cash', value: cash, className: 'seg-cash' },
    { key: 'borrow', label: 'Borrowed', value: totalBorrow, className: 'seg-borrow' },
    { key: 'short', label: 'Reserve deficit', value: shortfall, className: 'seg-shortfall' },
  ]
  const owedSegs: Segment[] = [
    { key: 'supply', label: 'Supplier balances', value: totalSupply, className: 'seg-supply' },
    { key: 'reserve', label: 'Reserves', value: positiveReserves, className: 'seg-reserve' },
  ]

  return (
    <div className="sheet">
      <div className="sheet-top">
        <h2>Market balance sheet</h2>
        <a className="card-sub" href={explorerAddress(model.deployment.market)} target="_blank" rel="noreferrer">
          Read live from {chain.name}
        </a>
      </div>
      {scale === 0n ? (
        <p className="muted">Nothing supplied yet. The first deposit will appear here.</p>
      ) : (
        <>
          <div className="sheet-rows">
            <span className="sheet-label">The market holds</span>
            <Bar segments={heldSegs} scale={scale} label="Cash and borrows" />
            <span className="sheet-total">{formatCompact(held, 6)}</span>
            <span className="sheet-label">It owes</span>
            <Bar segments={owedSegs} scale={scale} label="Supplier balances and reserves" />
            <span className="sheet-total">{formatCompact(owed, 6)}</span>
          </div>
          <Legend items={[...heldSegs, ...owedSegs].filter((s) => s.value > 0n || (s.key === 'reserve' && shortfall === 0n))} />
        </>
      )}
      <p className="sheet-note">
        Amounts in USDC. Reserves are not stored anywhere in the contract: they are whatever is left of cash plus
        borrows once every supplier is paid. An absorb lowers them by the debt the protocol takes over until the seized
        collateral sells, and bad debt lowers them for good. If that takes them below zero, the deficit is drawn here
        instead of being hidden.
        {inventoryUSD > 0n
          ? ` The market also holds ${formatUsd(inventoryUSD)} of seized collateral for sale, which reserves count only once it sells.`
          : null}
      </p>
      {!model.baseAnchorFresh ? (
        <div className="callout" data-tone="warn" style={{ marginTop: 14 }}>
          The Chainlink USDC feed has not updated within its window, so the oracle rejects every price that needs it.
          Borrowing, removing collateral, absorbing and buying revert until it updates.
        </div>
      ) : null}
      <div className="figures">
        <div className="figure">
          <div className="figure-value tone-supply">{formatPct(model.supplyApr)}</div>
          <div className="figure-label">Supply APR</div>
        </div>
        <div className="figure">
          <div className="figure-value tone-borrow">{formatPct(model.borrowApr)}</div>
          <div className="figure-label">Borrow APR</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatPct(model.utilization, 1)}</div>
          <div className="figure-label">Utilization</div>
        </div>
        <div className="figure">
          <div className="figure-value">{formatCompact(cash, 6)}</div>
          <div className="figure-label">USDC available to borrow</div>
        </div>
      </div>
    </div>
  )
}

export function Hero({ model }: { model: MarketModel }) {
  return (
    <section className="hero">
      <div className="wrap">
        <div className="hero-head">
          <h1>Supply USDC, or borrow it against WETH and wBTC.</h1>
          <p className="hero-sub">
            A single-asset money market in the style of Compound III, running on {chain.name} with testnet tokens.
            Every figure on this page is computed from the contracts' live state.
          </p>
        </div>
        <BalanceSheet model={model} />
      </div>
    </section>
  )
}
