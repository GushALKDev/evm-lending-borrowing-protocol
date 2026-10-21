import { useConnection, useWatchAsset } from 'wagmi'
import { chain, links } from '../config/chain'
import { useTx } from '../hooks/useTx'
import { faucetAbi } from '../lib/abi'
import { formatFixed } from '../lib/format'
import type { MarketModel } from '../lib/model'
import { TokenIcon } from './icons'
import { Dialog } from './Wallet'

const drips = [
  { symbol: 'USDC', amount: '10,000' },
  { symbol: 'WETH', amount: '5' },
  { symbol: 'WBTC', amount: '0.2' },
] as const

export function FaucetDialog({ model, onClose, onConnect }: { model: MarketModel; onClose: () => void; onConnect: () => void }) {
  const { address } = useConnection()
  const { run, busy } = useTx()
  const watch = useWatchAsset()
  const d = model.deployment
  const acc = model.account
  const next = acc ? acc.data.nextClaimAt : 0n
  const canClaim = !!acc && model.now >= next
  const noGas = !!acc && acc.data.wallet.eth === 0n
  const tokens = [d.base, ...d.collaterals]

  return (
    <Dialog title="Test tokens" onClose={onClose}>
      <p className="muted">
        The faucet hands out testnet tokens with no value, once a day per address. Transactions also need a little{' '}
        {chain.name} ETH for gas.
      </p>
      <div className="rows" style={{ margin: '14px 0 18px' }}>
        {drips.map((t) => (
          <div className="row" key={t.symbol}>
            <span className="asset">
              <TokenIcon symbol={t.symbol} />
              {t.symbol}
            </span>
            <span style={{ fontWeight: 500 }}>{t.amount}</span>
          </div>
        ))}
      </div>

      {!address ? (
        <button className="btn btn-primary btn-block" onClick={onConnect}>
          Connect wallet
        </button>
      ) : (
        <div className="steps">
          {noGas ? (
            <div className="callout" data-tone="warn">
              Your wallet has no {chain.name} ETH. Get some from a{' '}
              <a href={links.ethFaucet} target="_blank" rel="noreferrer">
                {chain.name} faucet
              </a>{' '}
              first, then come back.
            </div>
          ) : null}
          <button
            className="btn btn-primary btn-block"
            disabled={!canClaim || !!busy}
            onClick={() =>
              run('Claim test tokens', 'Test tokens claimed', () => ({
                address: d.faucet,
                abi: faucetAbi,
                functionName: 'claim',
              }))
            }
          >
            {busy ? 'Claiming…' : 'Claim test tokens'}
          </button>
          {!canClaim && acc ? (
            <p className="hint">
              You already claimed today. Next claim after {new Date(Number(next) * 1000).toLocaleString()}.
            </p>
          ) : null}
        </div>
      )}

      {address && acc ? (
        <>
          <div className="rows" style={{ marginTop: 18 }}>
            {tokens.map((t, i) => {
              const balance = i === 0 ? acc.data.wallet.base : acc.data.wallet.collaterals[i - 1]
              return (
                <div className="row" key={t.symbol}>
                  <span className="muted">Your {t.symbol}</span>
                  <span>
                    {formatFixed(balance, t.decimals, t.shown)}{' '}
                    <button
                      className="link-button"
                      style={{ marginLeft: 8, fontSize: 13 }}
                      onClick={() =>
                        watch.mutate({ type: 'ERC20', options: { address: t.address, symbol: t.symbol, decimals: t.decimals } })
                      }
                    >
                      Add to wallet
                    </button>
                  </span>
                </div>
              )
            })}
          </div>
        </>
      ) : null}
    </Dialog>
  )
}
