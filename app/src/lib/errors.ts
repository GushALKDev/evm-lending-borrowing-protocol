import {
  BaseError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
} from 'viem'
import { chain } from '../config/chain'
import { formatBps, formatFixed } from './format'

export interface ErrorContext {
  symbolOf: (address: string) => string
  decimalsOf: (address: string) => number
}

const usd = (v: unknown) => `$${formatFixed(v as bigint, 18, 2)}`

/**
 * Turns a failed simulation or transaction into one sentence that says what happened and, where it
 * helps, what to do. Contract errors are decoded by name from the combined market ABI.
 */
export function describeError(err: unknown, ctx: ErrorContext): string {
  if (err instanceof Error && err.name === 'Error' && err.message.startsWith('The transaction reverted when it landed'))
    return err.message
  if (!(err instanceof BaseError)) return err instanceof Error ? err.message : 'The request failed.'

  if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
  if (err.walk((e) => e instanceof InsufficientFundsError))
    return `Your wallet needs ${chain.name} ETH to pay for gas. Get some from a faucet and try again.`

  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as
    | ContractFunctionRevertedError
    | null
  const name = reverted?.data?.errorName
  const a = (reverted?.data?.args ?? []) as readonly unknown[]
  const base = (amount: unknown) => `${formatFixed(amount as bigint, 6, 2)} USDC`
  const token = (asset: unknown, amount: unknown) =>
    `${formatFixed(amount as bigint, ctx.decimalsOf(asset as string), 4)} ${ctx.symbolOf(asset as string)}`

  switch (name) {
    case 'NotCollateralized':
      return `This would leave your debt (${usd(a[1])}) above your borrowing capacity (${usd(a[2])}).`
    case 'MinBorrowNotMet':
      return `A debt must be at least ${base(a[1])}. This would leave ${base(a[0])}.`
    case 'InsufficientCash':
      return `The market has ${base(a[1])} available right now, less than the ${base(a[0])} requested.`
    case 'SupplyCapExceeded':
      return `This would take total ${ctx.symbolOf(a[0] as string)} posted past its supply cap of ${token(a[0], a[1])}.`
    case 'InsufficientCollateral':
      return `You have ${token(a[1], a[2])} posted, less than the amount requested.`
    case 'Paused':
      return 'This action is paused on the market right now.'
    case 'RepayExceedsDebtWhilePaused':
      return 'Supplying is paused: you can only repay up to your debt.'
    case 'TransferWouldBorrow':
      return 'Transfers cannot create debt: the amount is above your supplied balance.'
    case 'NotLiquidatable':
      return `This account is not absorbable at current prices: debt ${usd(a[1])}, liquidation capacity ${usd(a[2])}.`
    case 'NotForSale':
      return 'The storefront only sells while reserves are below their target.'
    case 'TooMuchSlippage':
      return 'The price moved and the quote fell below your minimum. Refresh the quote and try again.'
    case 'InsufficientInventory':
      return `Only ${token(a[0], a[2])} of seized collateral is for sale.`
    case 'ZeroAmount':
      return 'Enter an amount above zero.'
    case 'UnknownAsset':
      return 'That asset is not listed on this market.'
    case 'StalePrice':
      return 'The pushed price was older than 60 seconds when the transaction landed. Try again.'
    case 'StaleAnchor':
      return `The Chainlink feed for ${ctx.symbolOf(a[0] as string)} has not updated within its window, so the oracle rejects every price that needs it until it does. Try again later.`
    case 'PriceDeviationTooHigh':
      return `The ${ctx.symbolOf(a[0] as string)} price was ${formatBps(a[1] as bigint)} away from its Chainlink anchor, above the ${formatBps(a[2] as bigint)} limit.`
    case 'ConfidenceTooWide':
      return `The ${ctx.symbolOf(a[0] as string)} price was too uncertain to use.`
    case 'ZeroPrice':
      return `The oracle returned no price for ${ctx.symbolOf(a[0] as string)}.`
    case 'InsufficientFee':
      return 'The price update fee was not covered.'
    case 'FuturePublishTime':
      return 'The price update was timestamped ahead of the chain. Try again in a few seconds.'
    case 'ClaimTooSoon': {
      const next = new Date(Number(a[1] as bigint) * 1000)
      return `You already claimed today. The faucet opens again for you at ${next.toLocaleTimeString()} on ${next.toLocaleDateString()}.`
    }
    case 'ERC20InsufficientBalance':
      return 'Your wallet balance is too low for this amount.'
    case 'ERC20InsufficientAllowance':
      return 'The market is not approved to move this amount yet. Approve it first.'
    case 'RefundFailed':
      return 'The market could not refund the unused price update fee to your account.'
  }

  if (reverted) return `The transaction would revert${name ? ` (${name})` : ''}.`
  return err.shortMessage || 'The request failed.'
}
