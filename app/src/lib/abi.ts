import { erc20Abi } from 'viem'
import {
  chainlinkAbi,
  demoPythAbi,
  faucetAbi,
  lendingMarketAbi,
  oracleAbi,
  rateModelAbi,
  testnetTokenAbi,
} from '../abi'

const errorsOf = <T extends readonly { type: string }[]>(abi: T) =>
  abi.filter((item): item is Extract<T[number], { type: 'error' }> => item.type === 'error')

// Errors raised inside a market call can come from the oracle, DemoPyth or a token. Adding them to the
// market ABI lets viem decode any revert of a market call into a named error with its arguments.
export const marketAbi = [
  ...lendingMarketAbi,
  ...errorsOf(oracleAbi),
  ...errorsOf(demoPythAbi),
  ...errorsOf(testnetTokenAbi),
] as const

export const tokenAbi = [...erc20Abi, ...errorsOf(testnetTokenAbi)] as const

export { chainlinkAbi, demoPythAbi, faucetAbi, oracleAbi, rateModelAbi }
