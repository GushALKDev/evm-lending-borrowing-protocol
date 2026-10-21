import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { getAddress, isAddress, parseAbiItem, type Address } from 'viem'
import { useConnection } from 'wagmi'
import { getBlockNumber, getPublicClient, readContracts } from 'wagmi/actions'
import { freshPriceUpdate, useTx } from '../hooks/useTx'
import { marketAbi, tokenAbi } from '../lib/abi'
import { formatBps, formatFixed, formatPct, formatUsd, parseAmount, shortAddress, toInput } from '../lib/format'
import { PAUSE, absorbPreview, mulDivUp, quoteCollateral, storefrontDiscount, FACTOR_SCALE } from '../lib/market'
import { buildAccount, type AccountView, type MarketModel } from '../lib/model'
import { wagmiConfig } from '../wagmi'
import { Meter } from './Account'
import { TokenIcon } from './icons'

async function readAccount(model: MarketModel, account: Address): Promise<AccountView> {
  const d = model.deployment
  const r = (await readContracts(wagmiConfig, {
    allowFailure: false,
    contracts: [
      { address: d.market, abi: marketAbi, functionName: 'getPrincipal', args: [account] },
      ...d.collaterals.map((c) => ({ address: d.market, abi: marketAbi, functionName: 'userCollateral', args: [account, c.address] })),
    ] as never,
  })) as unknown as readonly unknown[]
  return buildAccount(
    { principal: BigInt(r[0] as bigint), collateral: (r.slice(1) as bigint[]).map(BigInt) },
    model.state,
    model.static,
    model.basePrice,
    model.collaterals,
  )
}

function statusOf(acc: AccountView): { label: string; tone: 'ok' | 'warn' | 'danger' | undefined } {
  if (acc.borrowed === 0n) return { label: 'No debt', tone: undefined }
  if (acc.health.isLiquidatable) return { label: 'Absorbable', tone: 'danger' }
  if (!acc.health.isBorrowCollateralized) return { label: 'Over its borrow limit', tone: 'warn' }
  return { label: 'Healthy', tone: 'ok' }
}

/* ------------------------------------------------------------------ */
/* Check an account                                                    */
/* ------------------------------------------------------------------ */

function CheckAccount({ model, target, setTarget }: { model: MarketModel; target: string; setTarget: (s: string) => void }) {
  const { address } = useConnection()
  const { run, busy } = useTx()
  const valid = isAddress(target)
  const q = useQuery({
    queryKey: ['account-check', target, model.deployment.market],
    queryFn: () => readAccount(model, getAddress(target)),
    enabled: valid,
    refetchInterval: 8_000,
  })
  // Recompute with the live projected state and prices every render.
  const acc = q.data
    ? buildAccount({ principal: q.data.principal, collateral: q.data.collateral }, model.state, model.static, model.basePrice, model.collaterals)
    : null
  const status = acc ? statusOf(acc) : null
  const absorbPaused = (model.state.pauseFlags & PAUSE.ABSORB) !== 0
  const preview = acc ? absorbPreview(acc.borrowed, model.basePrice, model.static.baseScale, acc.holdings) : null

  const absorb = () =>
    run('Absorb account', 'Account absorbed', async () => {
      const { update, value } = await freshPriceUpdate(model.static.updateFee)
      return { address: model.deployment.market, abi: marketAbi, functionName: 'absorb', args: [getAddress(target), update], value }
    })

  return (
    <div className="card">
      <div className="card-title">
        <h3>Check an account</h3>
      </div>
      <p className="hint" style={{ marginBottom: 12 }}>
        Anyone can absorb an account whose debt passes its liquidation capacity, valued with collateral at the high edge
        of each price band. The caller is paid nothing: the protocol takes over the debt and the collateral, and sells the
        collateral later through the storefront.
      </p>
      <form
        className="inline-form"
        onSubmit={(e) => {
          e.preventDefault()
          q.refetch()
        }}
      >
        <label htmlFor="account" className="visually-hidden">
          Account address
        </label>
        <input
          id="account"
          className="text-input"
          placeholder="0x… account address"
          spellCheck={false}
          value={target}
          onChange={(e) => setTarget(e.target.value.trim())}
        />
        {address && target.toLowerCase() !== address.toLowerCase() ? (
          <button type="button" className="btn" onClick={() => setTarget(address)}>
            Mine
          </button>
        ) : null}
      </form>
      {target && !valid ? (
        <p className="hint" data-tone="danger" style={{ marginTop: 8 }}>
          That is not a valid address.
        </p>
      ) : null}
      {acc && status ? (
        <div style={{ marginTop: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span className="mono">{shortAddress(target)}</span>
            <span className="status" data-tone={status.tone}>
              {status.label}
            </span>
          </div>
          <dl className="rows" style={{ marginTop: 8 }}>
            <div className="row">
              <dt>USDC position</dt>
              <dd>
                {acc.balance >= 0n ? 'Supplying ' : 'Borrowing '}
                {formatFixed(acc.balance < 0n ? -acc.balance : acc.balance, 6, 2)}
              </dd>
            </div>
            {model.collaterals.map((c, i) =>
              acc.collateral[i] > 0n ? (
                <div className="row" key={c.info.symbol}>
                  <dt>{c.info.symbol} posted</dt>
                  <dd>{formatFixed(acc.collateral[i], c.info.decimals, c.info.shown)}</dd>
                </div>
              ) : null,
            )}
            {acc.borrowed > 0n ? (
              <div className="row">
                <dt>Debt against liquidation capacity</dt>
                <dd>
                  {formatUsd(acc.health.debtUSD)} <span className="faint">of {formatUsd(acc.health.liquidationCapacity)}</span>
                </dd>
              </div>
            ) : null}
          </dl>
          {acc.borrowed > 0n ? <Meter h={acc.health} /> : null}
          {acc.health.isLiquidatable && preview ? (
            <div className="steps" style={{ marginTop: 10 }}>
              <div className="callout" data-tone="danger">
                Absorbing seizes {formatUsd(preview.seizedUSD)} of collateral and credits {formatUsd(preview.creditUSD)} of it
                against {formatFixed(preview.debtBase, 6, 2)} USDC of debt.{' '}
                {preview.badDebt > 0n
                  ? `${formatFixed(preview.badDebt, 6, 2)} USDC is left uncovered and is recorded as bad debt.`
                  : `The account keeps ${formatFixed(preview.surplus, 6, 2)} USDC as supply.`}
              </div>
              <button className="btn btn-primary btn-block" disabled={!address || !!busy || absorbPaused} onClick={absorb}>
                {busy ?? 'Absorb account'}
              </button>
              {!address ? <p className="hint">Connect a wallet to absorb.</p> : null}
            </div>
          ) : null}
        </div>
      ) : valid && q.isLoading ? (
        <p className="hint" style={{ marginTop: 12 }}>
          Reading the account…
        </p>
      ) : null}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Storefront                                                          */
/* ------------------------------------------------------------------ */

function Storefront({ model }: { model: MarketModel }) {
  const { address } = useConnection()
  const { run, busy } = useTx()
  const [input, setInput] = useState('')
  const [assetIndex, setAssetIndex] = useState(0)
  const d = model.deployment
  const st = model.static
  const forSale = model.collaterals.filter((c) => c.inventory > 0n)
  const selling = model.reserves < BigInt(st.targetReserves)
  const c = model.collaterals[assetIndex]
  const amount = parseAmount(input, d.base.decimals)
  const quote = amount ? quoteCollateral(c.info.params, c.price, model.basePrice, st.baseScale, amount) : 0n
  const ask = mulDivUp(c.price.price, FACTOR_SCALE - storefrontDiscount(c.info.params), FACTOR_SCALE)
  const acc = model.account
  const wallet = acc?.data.wallet.base ?? 0n
  // Largest base amount whose quote fits the inventory, from the inverse of the quote formula.
  const maxBase = c.inventory > 0n ? (c.inventory * st.baseScale * ask) / (model.basePrice.price * 10n ** BigInt(c.info.decimals)) : 0n
  const error =
    amount && amount > wallet
      ? 'More than your wallet balance.'
      : quote > c.inventory
        ? `Only ${formatFixed(c.inventory, c.info.decimals, c.info.shown)} ${c.info.symbol} for sale.`
        : undefined

  const buy = async () => {
    if (!amount || !address || !acc) return
    if (acc.data.allowance.base < amount) {
      const ok = await run('Approve USDC', 'USDC approved', () => ({
        address: d.base.address,
        abi: tokenAbi,
        functionName: 'approve',
        args: [d.market, amount],
      }))
      if (!ok) return
    }
    const minOut = (quote * 9_950n) / 10_000n
    const ok = await run(`Buy ${c.info.symbol}`, `${c.info.symbol} bought`, async () => {
      const { update, value } = await freshPriceUpdate(st.updateFee)
      return { address: d.market, abi: marketAbi, functionName: 'buyCollateral', args: [c.info.address, minOut, amount, address, update], value }
    })
    if (ok) setInput('')
  }

  return (
    <div className="card">
      <div className="card-title">
        <h3>Storefront</h3>
        <span className="card-sub">Seized collateral for sale</span>
      </div>
      {forSale.length === 0 ? (
        <div className="empty">
          <p>
            <strong>Nothing for sale.</strong> Collateral appears here after an absorb, priced below the oracle at each
            asset's storefront discount, while reserves are under their target of{' '}
            {formatFixed(st.targetReserves, d.base.decimals, 0)} USDC.
          </p>
          <p>
            Prices here follow Chainlink, so an account usually becomes absorbable when the market moves or its interest
            builds up; a pushed price can also shift it, within the oracle's 3% band around Chainlink. The simulator
            next to your position shows what an absorb would do.
          </p>
        </div>
      ) : (
        <div className="action" style={{ marginTop: 0 }}>
          <div className="choice">
            {model.collaterals.map((x, i) => (
              <button key={x.info.symbol} className="chip" aria-pressed={assetIndex === i} onClick={() => (setAssetIndex(i), setInput(''))}>
                {x.info.symbol}
              </button>
            ))}
          </div>
          <dl className="rows">
            <div className="row">
              <dt>
                <span className="asset">
                  <TokenIcon symbol={c.info.symbol} />
                  For sale
                </span>
              </dt>
              <dd>
                {formatFixed(c.inventory, c.info.decimals, c.info.shown)} {c.info.symbol}
              </dd>
            </div>
            <div className="row">
              <dt>Price</dt>
              <dd>
                {formatUsd(ask)} <span className="faint">{formatBps(storefrontDiscount(c.info.params))} below {formatUsd(c.price.price)}</span>
              </dd>
            </div>
          </dl>
          {!selling ? <div className="callout">Reserves are at their target, so the storefront is closed.</div> : null}
          <div className="field">
            <label className="field-label" htmlFor="buy-amount">
              <span>You pay</span>
              <span>Wallet {formatFixed(wallet, 6, 2)} USDC</span>
            </label>
            <div className="input-wrap" data-invalid={!!error}>
              <input id="buy-amount" className="amount-input" inputMode="decimal" placeholder="0.00" value={input} onChange={(e) => setInput(e.target.value)} />
              <span className="unit">USDC</span>
              <button className="max" onClick={() => setInput(toInput(maxBase < wallet ? maxBase : wallet, 6))}>
                Max
              </button>
            </div>
            {error ? (
              <span className="hint" data-tone="danger">
                {error}
              </span>
            ) : amount ? (
              <span className="hint">
                You receive about {formatFixed(quote, c.info.decimals, c.info.shown)} {c.info.symbol}, with at most 0.5% slippage.
              </span>
            ) : null}
          </div>
          <button className="btn btn-primary btn-block" disabled={!address || !amount || !!error || !!busy || !selling} onClick={buy}>
            {busy ?? `Buy ${c.info.symbol}`}
          </button>
        </div>
      )}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Accounts with debt                                                  */
/* ------------------------------------------------------------------ */

const SCAN_WINDOW = 500_000n // about 11 days of Base blocks
const supplyCollateralEvent = parseAbiItem('event SupplyCollateral(address indexed from, address indexed asset, uint256 amount)')

async function scanBorrowers(model: MarketModel): Promise<{ accounts: Address[]; fromBlock: bigint; partial: boolean }> {
  const client = getPublicClient(wagmiConfig)!
  const latest = await getBlockNumber(wagmiConfig)
  const start = latest - model.deployment.deployBlock > SCAN_WINDOW ? latest - SCAN_WINDOW : model.deployment.deployBlock
  const found = new Set<Address>()
  let from = start
  let span = 10_000n
  let requests = 0
  while (from <= latest && requests < 80) {
    const to = from + span - 1n > latest ? latest : from + span - 1n
    try {
      const logs = await client.getLogs({ address: model.deployment.market, event: supplyCollateralEvent, fromBlock: from, toBlock: to })
      logs.forEach((l) => l.args.from && found.add(l.args.from))
      from = to + 1n
    } catch {
      if (span <= 500n) break
      span /= 2n // the RPC rejected the range: retry with a smaller one
    }
    requests++
  }
  return { accounts: [...found], fromBlock: start, partial: from <= latest }
}

function Borrowers({ model, onPick }: { model: MarketModel; onPick: (a: string) => void }) {
  const scan = useQuery({
    queryKey: ['borrowers', model.deployment.market],
    queryFn: () => scanBorrowers(model),
    staleTime: 60_000,
    refetchInterval: 120_000,
  })
  const accounts = useQuery({
    queryKey: ['borrower-positions', scan.data?.accounts.join(',')],
    queryFn: async () => Promise.all(scan.data!.accounts.slice(0, 60).map(async (a) => ({ address: a, acc: await readAccount(model, a) }))),
    enabled: !!scan.data && scan.data.accounts.length > 0,
    refetchInterval: 30_000,
  })
  const rows = (accounts.data ?? [])
    .map((r) => ({
      address: r.address,
      acc: buildAccount({ principal: r.acc.principal, collateral: r.acc.collateral }, model.state, model.static, model.basePrice, model.collaterals),
    }))
    .filter((r) => r.acc.borrowed > 0n)
    .sort((a, b) => Number(((b.acc.health.capacityUsed ?? 0n) - (a.acc.health.capacityUsed ?? 0n)) / 10n ** 12n))

  return (
    <div className="card" style={{ gridColumn: '1 / -1' }}>
      <div className="card-title">
        <h3>Accounts with debt</h3>
        <span className="card-sub">Closest to absorb first</span>
      </div>
      {scan.isLoading ? (
        <p className="hint">Scanning the market's collateral deposits…</p>
      ) : scan.error ? (
        <p className="hint" data-tone="warn">
          The RPC refused the log scan. Check accounts one by one above.
        </p>
      ) : rows.length === 0 ? (
        <p className="hint">No open borrows yet.</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Account</th>
                <th className="num">Debt</th>
                <th className="num">Capacity used</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.slice(0, 12).map((r) => {
                const s = statusOf(r.acc)
                return (
                  <tr key={r.address}>
                    <td className="mono">{shortAddress(r.address)}</td>
                    <td className="num">{formatFixed(r.acc.borrowed, 6, 2)} USDC</td>
                    <td className="num">{r.acc.health.capacityUsed !== null ? formatPct(r.acc.health.capacityUsed, 1) : 'n/a'}</td>
                    <td>
                      <span className="status" data-tone={s.tone}>
                        {s.label}
                      </span>
                    </td>
                    <td className="num">
                      <button className="link-button" onClick={() => onPick(r.address)}>
                        Check
                      </button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
      {scan.data?.partial ? (
        <p className="hint" style={{ marginTop: 10 }}>
          Only part of the history could be scanned through this RPC; older borrowers may be missing.
        </p>
      ) : null}
    </div>
  )
}

export function Liquidations({ model }: { model: MarketModel }) {
  const [target, setTarget] = useState('')
  return (
    <section className="section" id="liquidations">
      <div className="wrap">
        <div className="section-head">
          <h2>Liquidations</h2>
          <p>
            Absorb and buyCollateral are the two halves of a liquidation here. Absorb settles an underwater account
            against the protocol; the storefront then sells what was seized at a discount, which is where a liquidator's
            profit comes from.
          </p>
        </div>
        <div className="liq-grid">
          <CheckAccount model={model} target={target} setTarget={setTarget} />
          <Storefront model={model} />
          <Borrowers
            model={model}
            onPick={(a) => {
              setTarget(a)
              document.getElementById('account')?.scrollIntoView({ behavior: 'smooth', block: 'center' })
            }}
          />
        </div>
      </div>
    </section>
  )
}
