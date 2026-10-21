import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import type { Abi, Address, Hex } from 'viem'
import { useConnection } from 'wagmi'
import { estimateGas, getBlock, readContracts, simulateContract, waitForTransactionReceipt, writeContract } from 'wagmi/actions'
import { encodeFunctionData } from 'viem'
import { deployment, explorerTx } from '../config/chain'
import { chainlinkAbi } from '../lib/abi'
import { describeError } from '../lib/errors'
import { buildPriceUpdate } from '../lib/pyth'
import { wagmiConfig } from '../wagmi'
import { useToasts } from './useToasts'

export interface ContractCall {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
  value?: bigint
}

/** The call passed simulation but reverted once mined, so nothing changed. */
export class LandedRevertError extends Error {
  constructor() {
    super('The transaction reverted when it landed, so nothing changed. Prices or balances may have moved: try again.')
  }
}

// Read lazily: on a chain with no deployment file the app renders a notice and never calls these.
const tokens = () => (deployment ? [deployment.base, ...deployment.collaterals] : [])
const find = (a: string) => tokens().find((t) => t.address.toLowerCase() === a.toLowerCase())
const errorContext = {
  symbolOf: (a: string) => find(a)?.symbol ?? 'the asset',
  decimalsOf: (a: string) => find(a)?.decimals ?? 18,
}

/**
 * Reads the latest Chainlink answers and block timestamp and returns the DemoPyth update for a
 * price-dependent call, plus the fee to attach. The market pays the update once per oracle read: the
 * base plus each collateral the account holds, so three reads at most. Any unspent value is refunded.
 */
export async function freshPriceUpdate(singleUpdateFee: bigint): Promise<{ update: Hex[]; value: bigint }> {
  const d = deployment!
  const feeds = [d.base, ...d.collaterals]
  const [block, results] = await Promise.all([
    getBlock(wagmiConfig, { blockTag: 'latest' }),
    readContracts(wagmiConfig, {
      allowFailure: false,
      contracts: feeds.flatMap((f) => [
        { address: f.chainlinkFeed, abi: chainlinkAbi, functionName: 'latestRoundData' } as const,
        { address: f.chainlinkFeed, abi: chainlinkAbi, functionName: 'decimals' } as const,
      ]),
    }),
  ])
  const readings = feeds.map((f, i) => ({
    pythFeedId: f.pythFeedId,
    answer: (results[2 * i] as readonly bigint[])[1],
    decimals: Number(results[2 * i + 1]),
  }))
  const update = buildPriceUpdate(readings, d.demoConfBps, block.timestamp)
  const reads = BigInt(1 + d.collaterals.length)
  return { update, value: singleUpdateFee * BigInt(update.length) * reads }
}

/** Simulates, sends and confirms one call at a time, reporting each step in a toast. */
export function useTx() {
  const { address } = useConnection()
  const toasts = useToasts()
  const queryClient = useQueryClient()
  const [busy, setBusy] = useState<string | null>(null)

  const run = useCallback(
    async (label: string, done: string, build: () => Promise<ContractCall> | ContractCall): Promise<boolean> => {
      if (!address) return false
      setBusy(label)
      const id = toasts.push({ tone: 'pending', title: label, body: 'Checking the call against the chain…' })
      try {
        const call = await build()
        // Simulating first surfaces a revert, decoded, before the wallet asks for a signature.
        const { request } = await simulateContract(wagmiConfig, { ...call, account: address } as never)
        // The node estimates gas at the latest block's timestamp. When the market already accrued in that
        // block, accrue() is a no-op in the estimate but writes both indexes once the call lands a block
        // later, which costs about 5,000 gas more. A margin on top of our own estimate covers that.
        const estimate = await estimateGas(wagmiConfig, {
          account: address,
          to: call.address,
          data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
          value: call.value,
        })
        const gas = (estimate * 125n) / 100n + 25_000n
        toasts.update(id, { body: 'Confirm it in your wallet.' })
        const hash = await writeContract(wagmiConfig, { ...(request as object), gas } as never)
        toasts.update(id, { body: 'Waiting for the block…', href: explorerTx(hash) })
        let receipt
        try {
          receipt = await waitForTransactionReceipt(wagmiConfig, { hash })
        } catch {
          // The transaction was sent, but its outcome could not be read: do not guess either way.
          toasts.update(id, {
            tone: 'error',
            title: `${label}: outcome unknown`,
            body: 'The transaction was sent but its result could not be read from the RPC. Check it on the explorer before trying again.',
          })
          await queryClient.invalidateQueries()
          return false
        }
        if (receipt.status !== 'success') throw new LandedRevertError()
        toasts.update(id, { tone: 'success', title: done, body: undefined })
        await queryClient.invalidateQueries()
        return true
      } catch (err) {
        console.error(err)
        toasts.update(id, { tone: 'error', title: `${label} failed`, body: describeError(err, errorContext) })
        return false
      } finally {
        setBusy(null)
      }
    },
    [address, toasts, queryClient],
  )

  return { run, busy }
}
