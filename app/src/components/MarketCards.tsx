import { explorerAddress } from '../config/chain'
import { formatBps, formatFixed, formatPct, formatUsd, relativeTime } from '../lib/format'
import { RATE_SCALE, borrowRate, perSecondToAnnual, storefrontDiscount, supplyRate } from '../lib/market'
import type { MarketModel } from '../lib/model'
import { TokenIcon } from './icons'

/* ------------------------------------------------------------------ */
/* Rate curve                                                          */
/* ------------------------------------------------------------------ */

const W = 440
const H = 220
const PAD = { left: 38, right: 10, top: 22, bottom: 26 }

function niceStep(max: number) {
  const raw = max / 4
  const mag = 10 ** Math.floor(Math.log10(raw))
  return [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? raw
}

export function RatesCard({ model }: { model: MarketModel }) {
  const m = model.static.rateModel
  const toPct = (r: bigint) => Number((perSecondToAnnual(r) * 10_000n) / RATE_SCALE) / 100
  const samples = Array.from({ length: 101 }, (_, i) => {
    const u = (BigInt(i) * RATE_SCALE) / 100n
    return { x: i, borrow: toPct(borrowRate(m, u)), supply: toPct(supplyRate(m, u)) }
  })
  const kinkPct = Number((m.kink * 100n) / RATE_SCALE)
  const maxY = Math.max(...samples.map((s) => s.borrow)) * 1.08 || 1
  const step = niceStep(maxY)
  const yTop = Math.ceil(maxY / step) * step
  const sx = (x: number) => PAD.left + (x / 100) * (W - PAD.left - PAD.right)
  const sy = (y: number) => PAD.top + (1 - y / yTop) * (H - PAD.top - PAD.bottom)
  const path = (key: 'borrow' | 'supply') => samples.map((s, i) => `${i ? 'L' : 'M'}${sx(s.x).toFixed(1)},${sy(s[key]).toFixed(1)}`).join('')

  const uNow = Math.min(100, Number((model.utilization * 10_000n) / RATE_SCALE) / 100)
  const bNow = toPct(borrowRate(m, model.utilization))
  const sNow = toPct(supplyRate(m, model.utilization))
  const yTicks = Array.from({ length: Math.round(yTop / step) + 1 }, (_, i) => i * step)

  const at = (u: bigint) => formatPct(perSecondToAnnual(borrowRate(m, u)), 1)

  return (
    <div className="card">
      <div className="card-title">
        <h2>Interest rates</h2>
        <a className="card-sub" href={explorerAddress(model.deployment.rateModel)} target="_blank" rel="noreferrer">
          Rate model
        </a>
      </div>
      <div className="legend">
        <span>
          <i style={{ background: 'var(--slate)' }} />
          Borrow APR
        </span>
        <span>
          <i style={{ background: 'var(--accent)' }} />
          Supply APR
        </span>
      </div>
      <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`Borrow and supply rates by utilization. Now at ${uNow.toFixed(1)}% utilization: borrow ${bNow.toFixed(2)}%, supply ${sNow.toFixed(2)}%.`}>
        {yTicks.map((y) => (
          <g key={y}>
            <line className="grid" x1={PAD.left} x2={W - PAD.right} y1={sy(y)} y2={sy(y)} />
            <text className="axis-text" x={PAD.left - 8} y={sy(y) + 4} textAnchor="end">
              {Number.isInteger(y) ? y : y.toFixed(1)}%
            </text>
          </g>
        ))}
        {[0, 20, 40, 60, 80, 100].map((x) => (
          <text key={x} className="axis-text" x={sx(x)} y={H - 8} textAnchor={x === 0 ? 'start' : x === 100 ? 'end' : 'middle'}>
            {x}%
          </text>
        ))}
        <line className="kink" x1={sx(kinkPct)} x2={sx(kinkPct)} y1={PAD.top} y2={H - PAD.bottom} />
        <text className="axis-text" x={sx(kinkPct) + 5} y={H - PAD.bottom - 6} textAnchor="start">
          Kink
        </text>
        <path className="curve-borrow" d={path('borrow')} />
        <path className="curve-supply" d={path('supply')} />
        <line className="now-line" x1={sx(uNow)} x2={sx(uNow)} y1={PAD.top - 18} y2={H - PAD.bottom} />
        <circle className="now-dot-borrow" cx={sx(uNow)} cy={sy(bNow)} r={5} />
        <circle className="now-dot-supply" cx={sx(uNow)} cy={sy(sNow)} r={5} />
        <text className="now-text" x={sx(uNow) + (uNow > 60 ? -6 : 6)} y={PAD.top - 8} textAnchor={uNow > 60 ? 'end' : 'start'}>
          Now {uNow.toFixed(1)}%
        </text>
      </svg>
      <p className="hint" style={{ marginTop: 10 }}>
        The horizontal axis is utilization, the share of supplied USDC that is lent out. Borrowing costs{' '}
        {at(0n)} at zero, {at(m.kink)} at the {formatPct(m.kink, 0)} kink and {at(RATE_SCALE)} when fully lent. The
        supply rate is derived from it: borrow rate times utilization, minus the {formatPct(m.reserveFactor, 0)} reserve
        factor, so interest can only ever add to reserves.
      </p>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Collateral                                                          */
/* ------------------------------------------------------------------ */

export function CollateralCard({ model }: { model: MarketModel }) {
  return (
    <div className="card">
      <div className="card-title">
        <h2>Collateral</h2>
        <span className="card-sub">Fixed at deployment</span>
      </div>
      <div style={{ display: 'grid', gap: 22 }}>
        {model.collaterals.map((c) => {
          const p = c.info.params
          const age = Number(model.now - c.updatedAt)
          const capShare = c.info.supplyCap > 0n ? Number((c.totalPosted * 10_000n) / c.info.supplyCap) / 100 : 0
          return (
            <div key={c.info.symbol}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 12 }}>
                <span className="asset" style={{ fontSize: 16 }}>
                  <TokenIcon symbol={c.info.symbol} />
                  {c.info.symbol}
                </span>
                <span style={{ fontSize: 18, fontWeight: 500 }}>{formatUsd(c.price.price)}</span>
              </div>
              <p className="hint" style={{ marginTop: 2 }} data-tone={c.anchorFresh ? undefined : 'warn'}>
                {c.anchorFresh ? (
                  <>
                    Chainlink price, updated {relativeTime(age)} ago.{' '}
                    <a href={explorerAddress(c.info.chainlinkFeed)} target="_blank" rel="noreferrer">
                      Feed
                    </a>
                  </>
                ) : (
                  `The Chainlink feed has not updated for ${relativeTime(age)}, past its window. Calls that need this price will revert until it does.`
                )}
              </p>
              <dl className="rows" style={{ marginTop: 6 }}>
                <div className="row">
                  <dt>Posted</dt>
                  <dd>
                    {formatFixed(c.totalPosted, c.info.decimals, 2)}{' '}
                    <span className="faint">of {formatFixed(c.info.supplyCap, c.info.decimals, 0)} cap</span>
                    <div className="cap-bar" aria-hidden="true">
                      <span style={{ width: `${Math.max(capShare, c.totalPosted > 0n ? 1 : 0)}%` }} />
                    </div>
                  </dd>
                </div>
                <div className="row">
                  <dt>Borrow up to</dt>
                  <dd>{formatBps(p.borrowCollateralFactor)} of its value</dd>
                </div>
                <div className="row">
                  <dt>Absorbable when debt passes</dt>
                  <dd>{formatBps(p.liquidateCollateralFactor)} of its value</dd>
                </div>
                <div className="row">
                  <dt>Credited when absorbed</dt>
                  <dd>{formatBps(p.liquidationFactor)} of its value</dd>
                </div>
                <div className="row">
                  <dt>Storefront discount</dt>
                  <dd>{formatBps(storefrontDiscount(p))}</dd>
                </div>
              </dl>
            </div>
          )
        })}
      </div>
    </div>
  )
}
