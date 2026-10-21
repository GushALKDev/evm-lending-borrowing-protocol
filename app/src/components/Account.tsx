import { useMemo, useState } from 'react'
import { maxUint256, type Hex } from 'viem'
import { useConnection } from 'wagmi'
import { chain, links } from '../config/chain'
import { freshPriceUpdate, useTx } from '../hooks/useTx'
import { marketAbi, tokenAbi } from '../lib/abi'
import { formatBps, formatFixed, formatPct, formatUsd, parseAmount, toInput } from '../lib/format'
import {
  PAUSE,
  RATE_SCALE,
  absorbPreview,
  health,
  maxCollateralWithdraw,
  maxDebtFor,
  mulDiv,
  scalePrice,
  type Health,
  type Holding,
} from '../lib/market'
import type { AccountView, MarketModel } from '../lib/model'
import { TokenIcon } from './icons'

/* ------------------------------------------------------------------ */
/* Capacity meter                                                      */
/* ------------------------------------------------------------------ */

function pctOf(value: bigint, scale: bigint): number {
  return scale > 0n ? Math.min(100, Number((value * 10_000n) / scale) / 100) : 0
}

export function Meter({ h, ghost }: { h: Health; ghost?: Health | null }) {
  if (h.capacityUsed === null || h.liquidationPoint === null) return null
  const candidates = [RATE_SCALE * 5n / 4n, (h.liquidationPoint * 115n) / 100n, (h.capacityUsed * 105n) / 100n]
  if (ghost?.capacityUsed) candidates.push((ghost.capacityUsed * 105n) / 100n)
  const scale = candidates.reduce((a, b) => (a > b ? a : b))
  const used = h.capacityUsed
  const tone = h.isLiquidatable ? 'danger' : used > RATE_SCALE ? 'danger' : used > (RATE_SCALE * 85n) / 100n ? 'warn' : 'ok'
  const limitAt = pctOf(RATE_SCALE, scale)
  const liqAt = pctOf(h.liquidationPoint, scale)
  return (
    <div className="meter">
      <div className="meter-head">
        <span className="muted">Borrowing capacity used</span>
        <strong style={{ fontWeight: 600 }} className={tone === 'danger' ? 'tone-danger' : tone === 'warn' ? 'tone-warn' : ''}>
          {formatPct(used, 1)}
          {ghost?.capacityUsed != null ? (
            <>
              <span className="arrow">to</span>
              {formatPct(ghost.capacityUsed, 1)}
            </>
          ) : null}
        </strong>
      </div>
      <div
        className="meter-track"
        role="meter"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Number((used * 100n) / RATE_SCALE)}
        aria-label="Borrowing capacity used"
      >
        <div className="meter-fill" data-tone={tone} style={{ width: `${pctOf(used, scale)}%` }} />
        {ghost?.capacityUsed != null ? <div className="meter-ghost" style={{ width: `${pctOf(ghost.capacityUsed, scale)}%` }} /> : null}
        <div className="meter-mark" style={{ left: `${limitAt}%` }} />
        <div className="meter-mark" data-kind="liq" style={{ left: `${liqAt}%` }} />
      </div>
      <div className="meter-legend">
        <span style={{ left: `${limitAt}%`, transform: liqAt - limitAt < 14 ? 'translateX(-100%)' : undefined }}>
          Borrow limit
        </span>
        <span data-kind="liq" style={{ left: `${liqAt}%`, transform: liqAt - limitAt < 14 ? 'translateX(0)' : undefined }}>
          Absorb
        </span>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Position summary                                                    */
/* ------------------------------------------------------------------ */

function PositionSummary({ model, acc }: { model: MarketModel; acc: AccountView }) {
  const d = model.deployment
  const h = acc.health
  const state = acc.balance > 0n ? 'Supplying' : acc.balance < 0n ? 'Borrowing' : 'No USDC position'
  const singleHolding = acc.holdings.length === 1 ? acc.holdings[0] : null
  const singleInfo = singleHolding ? model.collaterals.find((c) => c.info.params === singleHolding.params)?.info : undefined

  return (
    <>
      <div className="position-main">
        <span className="position-state">{state}</span>
        <span className="position-amount">
          {formatFixed(acc.balance < 0n ? -acc.balance : acc.balance, d.base.decimals, 6)}
          <small>USDC</small>
        </span>
        <span className="hint">
          {acc.balance > 0n
            ? `Earning ${formatPct(model.supplyApr)} APR. Interest accrues every second.`
            : acc.balance < 0n
              ? `Paying ${formatPct(model.borrowApr)} APR. Interest accrues every second.`
              : 'Supply USDC to earn interest, or post collateral and borrow it.'}
        </span>
      </div>
      <dl className="rows">
        {model.collaterals.map((c, i) => {
          const bal = acc.collateral[i]
          if (bal === 0n) return null
          return (
            <div className="row" key={c.info.symbol}>
              <dt>
                <span className="asset">
                  <TokenIcon symbol={c.info.symbol} />
                  {c.info.symbol} posted
                </span>
              </dt>
              <dd>
                {formatFixed(bal, c.info.decimals, c.info.shown)}{' '}
                <span className="faint">{formatUsd(mulDiv(bal, c.price.price, 10n ** BigInt(c.info.decimals)))}</span>
              </dd>
            </div>
          )
        })}
        {acc.holdings.length === 0 ? (
          <div className="row">
            <dt>Collateral</dt>
            <dd className="faint">None posted</dd>
          </div>
        ) : (
          <div className="row">
            <dt>Borrowing capacity</dt>
            <dd>{formatUsd(h.borrowCapacity)}</dd>
          </div>
        )}
        {acc.borrowed > 0n ? (
          <div className="row">
            <dt>Debt value, at the price's high edge</dt>
            <dd>{formatUsd(h.debtUSD)}</dd>
          </div>
        ) : null}
      </dl>
      {acc.borrowed > 0n ? <Meter h={h} /> : null}
      {acc.borrowed > 0n && h.dropToLiquidation !== null ? (
        <p className="hint" data-tone={h.isLiquidatable ? 'danger' : undefined}>
          {h.isLiquidatable
            ? 'This position can be absorbed right now: anyone can call absorb on it.'
            : singleHolding && singleInfo
              ? `Absorbable if ${singleInfo.symbol} falls below ${formatUsd(
                  mulDiv(singleHolding.price.price, RATE_SCALE - h.dropToLiquidation, RATE_SCALE),
                )}, ${formatPct(h.dropToLiquidation, 1)} under today's price.`
              : `Absorbable if your collateral prices fall ${formatPct(h.dropToLiquidation, 1)} together.`}
        </p>
      ) : null}
    </>
  )
}

/* ------------------------------------------------------------------ */
/* Actions                                                             */
/* ------------------------------------------------------------------ */

type Tab = 'supply' | 'withdraw' | 'borrow' | 'repay' | 'collateral'

const tabs: { id: Tab; label: string }[] = [
  { id: 'supply', label: 'Supply' },
  { id: 'withdraw', label: 'Withdraw' },
  { id: 'borrow', label: 'Borrow' },
  { id: 'repay', label: 'Repay' },
  { id: 'collateral', label: 'Collateral' },
]

interface Plan {
  symbol: string
  decimals: number
  shown: number
  /** Maximum the user can enter, already capped by wallet, position and market limits */
  max: bigint
  maxLabel: string
  /** Value sent when the Max button was used and an exact sentinel applies (full repay) */
  sentinel?: bigint
  /** Allowance needed for the call, if it pulls tokens */
  approve?: { token: Hex; current: bigint; needed: bigint }
  /** The position after the call, for the preview */
  after?: { balance: bigint; holdings: Holding[]; collateral?: bigint }
  error?: string
  note?: string
  needsPrice: boolean
  verb: string
  done: string
  call: (amount: bigint) => { functionName: 'supply' | 'withdraw'; args: readonly unknown[] }
}

function useActionPlan(model: MarketModel, acc: AccountView, tab: Tab, assetIndex: number, removing: boolean, amount: bigint | null, usedMax: boolean): Plan {
  const d = model.deployment
  const st = model.static
  const base = d.base
  const h = acc.health
  const borrowed = acc.borrowed
  const supplied = acc.supplied
  const buffer = (x: bigint) => (x * 9_950n) / 10_000n // keeps 0.5% back for interest and price moves
  const a = amount ?? 0n

  const withHolding = (i: number, newBalance: bigint): Holding[] =>
    model.collaterals
      .map((c, j) => ({ params: c.info.params, balance: j === i ? newBalance : acc.collateral[j], price: c.price }))
      .filter((x) => x.balance > 0n)

  const borrowPaused = (model.state.pauseFlags & PAUSE.BORROW) !== 0
  const withdrawPaused = (model.state.pauseFlags & PAUSE.WITHDRAW) !== 0
  const supplyPaused = (model.state.pauseFlags & PAUSE.SUPPLY) !== 0

  switch (tab) {
    case 'supply': {
      const wallet = acc.data.wallet.base
      return {
        symbol: base.symbol,
        decimals: base.decimals,
        shown: base.shown,
        max: wallet,
        maxLabel: `Wallet ${formatFixed(wallet, base.decimals, base.shown)} USDC`,
        approve: { token: base.address, current: acc.data.allowance.base, needed: a },
        after: { balance: acc.balance + a, holdings: acc.holdings },
        error: a > wallet ? 'More than your wallet balance.' : supplyPaused && borrowed === 0n ? 'Supplying is paused on the market.' : undefined,
        note: borrowed > 0n ? 'You are borrowing, so this repays your debt first and supplies anything beyond it.' : undefined,
        needsPrice: false,
        verb: 'Supply USDC',
        done: 'USDC supplied',
        call: (x) => ({ functionName: 'supply', args: [base.address, x] }),
      }
    }
    case 'withdraw': {
      // At the latest block's timestamp: the visitor's clock can run ahead of the chain, and a full
      // withdrawal computed from it could cross zero into a dust borrow that the market rejects.
      const withdrawable = acc.suppliedAtChain
      const cashCap = model.cash < withdrawable ? model.cash : withdrawable
      return {
        symbol: base.symbol,
        decimals: base.decimals,
        shown: base.shown,
        max: cashCap,
        maxLabel: `Supplied ${formatFixed(supplied, base.decimals, base.shown)} USDC`,
        after: { balance: acc.balance - a, holdings: acc.holdings },
        error:
          supplied === 0n
            ? 'You have no USDC supplied. To take USDC out against collateral, use Borrow.'
            : a > withdrawable
              ? 'More than you have supplied. Withdraw stops at zero here; use Borrow to go below it.'
              : a > model.cash
                ? 'More than the market holds in cash right now.'
                : withdrawPaused
                  ? 'Withdrawals are paused on the market.'
                  : undefined,
        needsPrice: false,
        verb: 'Withdraw USDC',
        done: 'USDC withdrawn',
        call: (x) => ({ functionName: 'withdraw', args: [base.address, x, []] }),
      }
    }
    case 'borrow': {
      const maxDebt = buffer(maxDebtFor(h.borrowCapacity, model.basePrice, st.baseScale))
      const headroom = maxDebt > borrowed ? maxDebt - borrowed : 0n
      const atChain = acc.suppliedAtChain
      const cashRoom = model.cash > atChain ? model.cash - atChain : 0n
      // Borrowing from a supply withdraws the supply too. Interest earned between the latest block and the
      // landing block slightly shrinks the debt, so keep a cent above the minimum in that case.
      const minDebt = atChain > 0n ? st.minBorrow + st.baseScale / 100n : st.minBorrow
      const max = headroom < cashRoom ? headroom : cashRoom
      const debtAfter = borrowed + a
      const afterHealth = health(debtAfter, model.basePrice, st.baseScale, acc.holdings)
      let error: string | undefined
      if (acc.holdings.length === 0) error = 'Post WETH or wBTC as collateral first, in the Collateral tab.'
      else if (borrowPaused) error = 'Borrowing is paused on the market.'
      else if (a > 0n && debtAfter < minDebt)
        error = `A debt must be at least ${formatFixed(st.minBorrow, base.decimals, 0)} USDC${atChain > 0n ? ', plus a cent of margin when it starts from a supply' : ''}.`
      else if (a > 0n && !afterHealth.isBorrowCollateralized) error = 'More than your borrowing capacity.'
      else if (a > cashRoom) error = 'More than the market holds in cash right now.'
      return {
        symbol: base.symbol,
        decimals: base.decimals,
        shown: base.shown,
        max,
        maxLabel: `Up to ${formatFixed(max, base.decimals, base.shown)} USDC`,
        after: { balance: acc.balance - atChain - a, holdings: acc.holdings },
        error,
        note:
          supplied > 0n
            ? `A position is either supplying or borrowing. This withdraws your ${formatFixed(supplied, base.decimals, base.shown)} USDC supply and borrows the amount on top, in one call.`
            : undefined,
        needsPrice: true,
        verb: 'Borrow USDC',
        done: 'USDC borrowed',
        call: (x) => ({ functionName: 'withdraw', args: [base.address, x + atChain, []] }),
      }
    }
    case 'repay': {
      const wallet = acc.data.wallet.base
      // Repaying everything pulls the debt as accrued when the call lands: a wallet one basis point above
      // today's figure covers minutes of interest. The approval gets its own, larger margin below.
      const canRepayAll = wallet >= (borrowed * 10_001n) / 10_000n + 1n
      const max = canRepayAll ? borrowed : wallet < borrowed ? wallet : borrowed
      const repayAll = usedMax && canRepayAll
      return {
        symbol: base.symbol,
        decimals: base.decimals,
        shown: base.shown,
        max,
        maxLabel: `Debt ${formatFixed(borrowed, base.decimals, base.shown)} USDC`,
        sentinel: repayAll ? maxUint256 : undefined,
        approve: {
          token: base.address,
          current: acc.data.allowance.base,
          // The full repay pulls the debt as accrued at execution: approve a little above today's figure.
          needed: repayAll ? (borrowed * 10_010n) / 10_000n + 1n : a,
        },
        after: { balance: repayAll ? 0n : acc.balance + a, holdings: acc.holdings },
        error:
          borrowed === 0n
            ? 'You have no debt to repay.'
            : a > wallet
              ? 'More than your wallet balance.'
              : a > borrowed && !repayAll
                ? 'More than your debt. Use Max to repay it exactly, or Supply to deposit the rest.'
                : undefined,
        note: repayAll ? 'Repays the debt exactly as accrued when the transaction lands, nothing more.' : undefined,
        needsPrice: false,
        verb: 'Repay USDC',
        done: 'Debt repaid',
        call: (x) => ({ functionName: 'supply', args: [base.address, x] }),
      }
    }
    case 'collateral': {
      const c = model.collaterals[assetIndex]
      const info = c.info
      const posted = acc.collateral[assetIndex]
      if (!removing) {
        const wallet = acc.data.wallet.collaterals[assetIndex]
        const capRoom = info.supplyCap > c.totalPosted ? info.supplyCap - c.totalPosted : 0n
        const max = wallet < capRoom ? wallet : capRoom
        return {
          symbol: info.symbol,
          decimals: info.decimals,
          shown: info.shown,
          max,
          maxLabel: `Wallet ${formatFixed(wallet, info.decimals, info.shown)} ${info.symbol}`,
          approve: { token: info.address, current: acc.data.allowance.collaterals[assetIndex], needed: a },
          after: { balance: acc.balance, holdings: withHolding(assetIndex, posted + a), collateral: posted + a },
          error:
            a > wallet
              ? 'More than your wallet balance.'
              : a > capRoom
                ? `Only ${formatFixed(capRoom, info.decimals, info.shown)} ${info.symbol} left under the supply cap.`
                : supplyPaused && borrowed === 0n
                  ? 'Supplying is paused on the market.'
                  : undefined,
          needsPrice: false,
          verb: `Add ${info.symbol}`,
          done: `${info.symbol} added`,
          call: (x) => ({ functionName: 'supply', args: [info.address, x] }),
        }
      }
      const target = acc.holdings.find((x) => x.params === info.params)
      const max = target ? maxCollateralWithdraw(target, acc.holdings, h.debtUSD, 50n) : 0n
      const afterHoldings = withHolding(assetIndex, posted > a ? posted - a : 0n)
      const afterHealth = health(borrowed, model.basePrice, st.baseScale, afterHoldings)
      return {
        symbol: info.symbol,
        decimals: info.decimals,
        shown: info.shown,
        max,
        maxLabel: `Posted ${formatFixed(posted, info.decimals, info.shown)} ${info.symbol}`,
        after: { balance: acc.balance, holdings: afterHoldings, collateral: posted > a ? posted - a : 0n },
        error:
          posted === 0n
            ? `You have no ${info.symbol} posted.`
            : a > posted
              ? 'More than you have posted.'
              : borrowed > 0n && borrowPaused
                ? 'Collateral backing a debt stays put while borrowing is paused.'
                : borrowed > 0n && a > 0n && !afterHealth.isBorrowCollateralized
                  ? 'Your debt would exceed your borrowing capacity.'
                  : withdrawPaused
                    ? 'Withdrawals are paused on the market.'
                    : undefined,
        needsPrice: borrowed > 0n,
        verb: `Remove ${info.symbol}`,
        done: `${info.symbol} removed`,
        call: (x) => ({ functionName: 'withdraw', args: [info.address, x, []] }),
      }
    }
  }
}

function describeBalance(balance: bigint, decimals: number, shown: number) {
  if (balance === 0n) return 'None'
  return balance > 0n
    ? `Supplying ${formatFixed(balance, decimals, shown)}`
    : `Borrowing ${formatFixed(-balance, decimals, shown)}`
}

function Actions({ model, acc }: { model: MarketModel; acc: AccountView }) {
  const [tab, setTab] = useState<Tab>(acc.holdings.length > 0 && acc.supplied === 0n ? 'borrow' : 'supply')
  const [assetIndex, setAssetIndex] = useState(0)
  const [removing, setRemoving] = useState(false)
  const [input, setInput] = useState('')
  const [usedMax, setUsedMax] = useState(false)
  const { run, busy } = useTx()
  const { address } = useConnection()

  const d = model.deployment
  const plan = useActionPlan(model, acc, tab, assetIndex, removing, parseAmount(input, tab === 'collateral' ? model.collaterals[assetIndex].info.decimals : d.base.decimals), usedMax)
  const amount = parseAmount(input, plan.decimals)
  const invalidInput = input !== '' && amount === null
  const noGas = acc.data.wallet.eth === 0n

  const afterHealth = useMemo(() => {
    if (!plan.after || !amount) return null
    const borrowedAfter = plan.after.balance < 0n ? -plan.after.balance : 0n
    return health(borrowedAfter, model.basePrice, model.static.baseScale, plan.after.holdings)
  }, [plan.after, amount, model.basePrice, model.static.baseScale])

  const needsApproval = !!plan.approve && !!amount && plan.approve.current < plan.approve.needed
  const canSubmit = !!amount && amount > 0n && !plan.error && !busy && !noGas

  const reset = () => {
    setInput('')
    setUsedMax(false)
  }

  const submit = async () => {
    if (!amount || !address) return
    if (needsApproval && plan.approve) {
      const ok = await run(`Approve ${plan.symbol}`, `${plan.symbol} approved`, () => ({
        address: plan.approve!.token,
        abi: tokenAbi,
        functionName: 'approve',
        args: [d.market, plan.approve!.needed],
      }))
      if (!ok) return
    }
    const sent = plan.sentinel ?? amount
    const ok = await run(plan.verb, plan.done, async () => {
      const { functionName, args } = plan.call(sent)
      if (functionName === 'withdraw' && plan.needsPrice) {
        const { update, value } = await freshPriceUpdate(model.static.updateFee)
        return { address: d.market, abi: marketAbi, functionName, args: [args[0], args[1], update], value }
      }
      return { address: d.market, abi: marketAbi, functionName, args }
    }, { afterApproval: needsApproval })
    if (ok) reset()
  }

  const showCapacity = acc.borrowed > 0n || (afterHealth && afterHealth.debtUSD > 0n)

  return (
    <div style={{ marginTop: 22 }}>
      <div className="tabs" role="tablist" aria-label="Action">
        {tabs.map((t) => (
          <button
            key={t.id}
            role="tab"
            className="tab"
            aria-selected={tab === t.id}
            onClick={() => {
              setTab(t.id)
              reset()
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="action" role="tabpanel">
        {tab === 'collateral' ? (
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
            <div className="choice" aria-label="Asset">
              {model.collaterals.map((c, i) => (
                <button
                  key={c.info.symbol}
                  className="chip"
                  aria-pressed={assetIndex === i}
                  onClick={() => {
                    setAssetIndex(i)
                    reset()
                  }}
                >
                  {c.info.symbol}
                </button>
              ))}
            </div>
            <div className="choice" aria-label="Direction">
              <button className="chip" aria-pressed={!removing} onClick={() => (setRemoving(false), reset())}>
                Add
              </button>
              <button className="chip" aria-pressed={removing} onClick={() => (setRemoving(true), reset())}>
                Remove
              </button>
            </div>
          </div>
        ) : null}

        <div className="field">
          <label className="field-label" htmlFor="amount">
            <span>Amount</span>
            <span>{plan.maxLabel}</span>
          </label>
          <div className="input-wrap" data-invalid={invalidInput || (!!amount && !!plan.error)}>
            <input
              id="amount"
              className="amount-input"
              inputMode="decimal"
              autoComplete="off"
              placeholder="0.00"
              value={input}
              onChange={(e) => {
                setInput(e.target.value)
                setUsedMax(false)
              }}
            />
            <span className="unit">{plan.symbol}</span>
            <button
              className="max"
              disabled={plan.max === 0n}
              onClick={() => {
                setInput(toInput(plan.max, plan.decimals))
                setUsedMax(true)
              }}
            >
              Max
            </button>
          </div>
          {invalidInput ? <span className="hint" data-tone="danger">Enter a number with at most {plan.decimals} decimals.</span> : null}
          {plan.error && (amount || plan.max === 0n) ? (
            <span className="hint" data-tone="danger">
              {plan.error}
            </span>
          ) : null}
        </div>

        {plan.note ? <div className="callout">{plan.note}</div> : null}

        {amount && plan.after && !plan.error ? (
          <dl className="rows">
            <div className="row">
              <dt>USDC position</dt>
              <dd>
                <span className="faint">{describeBalance(acc.balance, d.base.decimals, d.base.shown)}</span>
                <span className="arrow">to</span>
                {describeBalance(plan.after.balance, d.base.decimals, d.base.shown)}
              </dd>
            </div>
            {plan.after.collateral !== undefined ? (
              <div className="row">
                <dt>{plan.symbol} posted</dt>
                <dd>
                  <span className="faint">{formatFixed(acc.collateral[assetIndex], plan.decimals, plan.shown)}</span>
                  <span className="arrow">to</span>
                  {formatFixed(plan.after.collateral, plan.decimals, plan.shown)}
                </dd>
              </div>
            ) : null}
            {showCapacity && afterHealth ? (
              <div className="row">
                <dt>Borrowing capacity used</dt>
                <dd>
                  <span className="faint">{acc.health.capacityUsed !== null ? formatPct(acc.health.capacityUsed, 1) : '0%'}</span>
                  <span className="arrow">to</span>
                  {afterHealth.capacityUsed !== null ? formatPct(afterHealth.capacityUsed, 1) : '0%'}
                </dd>
              </div>
            ) : null}
            {plan.needsPrice ? (
              <div className="row">
                <dt>Price check</dt>
                <dd style={{ fontWeight: 400 }} className="muted">
                  Latest Chainlink prices pushed in the same call
                </dd>
              </div>
            ) : null}
          </dl>
        ) : null}

        {noGas ? (
          <div className="callout" data-tone="warn">
            Your wallet has no {chain.name} ETH for gas. Get some from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </div>
        ) : null}

        <button className="btn btn-primary btn-block" disabled={!canSubmit} onClick={submit}>
          {busy ?? (needsApproval ? `Approve and ${plan.verb.toLowerCase()}` : plan.verb)}
        </button>
        {needsApproval && canSubmit ? (
          <p className="hint">Two transactions: an approval for this amount, then the {plan.verb.toLowerCase().split(' ')[0]} itself.</p>
        ) : null}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Price shock simulator                                               */
/* ------------------------------------------------------------------ */

function Simulator({ model, acc }: { model: MarketModel; acc: AccountView }) {
  const [move, setMove] = useState(-20)
  const st = model.static
  const factor = 1 + move / 100
  const shocked = acc.holdings.map((h) => ({ ...h, price: scalePrice(h.price, factor) }))
  const h = health(acc.borrowed, model.basePrice, st.baseScale, shocked)
  const preview = absorbPreview(acc.borrowed, model.basePrice, st.baseScale, shocked)
  const factors = acc.holdings
    .map((x) => {
      const info = model.collaterals.find((c) => c.info.params === x.params)!.info
      return `${formatBps(x.params.liquidationFactor)} for ${info.symbol}`
    })
    .join(' and ')

  return (
    <div className="card">
      <div className="card-title">
        <h3>What a price move would do</h3>
        <span className="card-sub">Simulation in your browser</span>
      </div>
      <label className="field-label" htmlFor="shock">
        <span>Collateral prices</span>
        <strong style={{ color: 'var(--ink)', fontWeight: 600 }}>
          {move > 0 ? '+' : ''}
          {move}%
        </strong>
      </label>
      <input
        id="shock"
        className="slider"
        type="range"
        min={-70}
        max={30}
        step={1}
        value={move}
        onChange={(e) => setMove(Number(e.target.value))}
      />
      <div className="slider-scale">
        <span>-70%</span>
        <span>Today</span>
        <span>+30%</span>
      </div>
      <Meter h={h} />
      <p className="outcome">
        {!h.isLiquidatable ? (
          <>
            <strong>Still safe.</strong>{' '}
            {h.dropToLiquidation !== null
              ? `At Chainlink prices, collateral could fall another ${formatPct(h.dropToLiquidation, 1)} before the position becomes absorbable. A price pushed within the oracle's 3% band, or accrued interest, moves that point.`
              : null}
          </>
        ) : (
          <>
            <strong>Absorbable.</strong> If someone calls absorb, the protocol takes all your collateral, worth{' '}
            {formatUsd(preview.seizedUSD)} at the mid price, and credits {formatUsd(preview.creditUSD)} of it ({factors})
            against your {formatFixed(preview.debtBase, 6, 2)} USDC debt.{' '}
            {preview.surplus > 0n
              ? `The debt is cleared and you keep ${formatFixed(preview.surplus, 6, 2)} USDC as a supply balance.`
              : `That leaves ${formatFixed(preview.badDebt, 6, 2)} USDC of bad debt, which comes out of reserves.`}
          </>
        )}
      </p>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* First visit                                                         */
/* ------------------------------------------------------------------ */

function GetStarted() {
  return (
    <div className="card">
      <div className="card-title">
        <h3>Try a full borrow in a few minutes</h3>
      </div>
      <div className="flow">
        <div className="flow-step">
          <b>1</b>
          <span>
            Get a little {chain.name} ETH for gas from a{' '}
            <a href={links.ethFaucet} target="_blank" rel="noreferrer">
              faucet
            </a>
            .
          </span>
        </div>
        <div className="flow-step">
          <b>2</b>
          <span>Connect your wallet and claim test USDC, WETH and wBTC from the button at the top.</span>
        </div>
        <div className="flow-step">
          <b>3</b>
          <span>Post WETH or wBTC as collateral, then borrow USDC against it.</span>
        </div>
        <div className="flow-step">
          <b>4</b>
          <span>Drag the price simulator to see the point where your position could be absorbed, and what you would keep.</span>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Card                                                                */
/* ------------------------------------------------------------------ */

export function AccountCard({ model, onConnect, onFaucet }: { model: MarketModel; onConnect: () => void; onFaucet: () => void }) {
  const { status, chainId } = useConnection()
  const acc = model.account

  if (status !== 'connected') {
    return (
      <>
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <div className="empty">
          <p>
            <strong>Connect a wallet to supply or borrow.</strong> You can read the whole market without one.
          </p>
          <p>
            New here? The faucet gives you 10,000 USDC, 5 WETH and 0.2 wBTC on {chain.name}, once a day.
          </p>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <button className="btn btn-primary" onClick={onConnect}>
              Connect wallet
            </button>
            <button className="btn" onClick={onFaucet}>
              Get test tokens
            </button>
          </div>
        </div>
      </div>
      <GetStarted />
      </>
    )
  }

  if (chainId !== chain.id) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Your wallet is on another network. Switch to {chain.name} from the button at the top.</p>
      </div>
    )
  }

  if (!acc) {
    return (
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
        </div>
        <p className="muted">Reading your position…</p>
      </div>
    )
  }

  const empty = acc.balance === 0n && acc.holdings.length === 0
  const hasTokens = acc.data.wallet.base > 0n || acc.data.wallet.collaterals.some((x) => x > 0n)

  return (
    <>
      <div className="card">
        <div className="card-title">
          <h2>Your position</h2>
          {empty && !hasTokens ? (
            <button className="link-button" onClick={onFaucet}>
              Get test tokens
            </button>
          ) : null}
        </div>
        <PositionSummary model={model} acc={acc} />
        <Actions model={model} acc={acc} />
      </div>
      {acc.borrowed > 0n && acc.holdings.length > 0 ? <Simulator model={model} acc={acc} /> : null}
    </>
  )
}
