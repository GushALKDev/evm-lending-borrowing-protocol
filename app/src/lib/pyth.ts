import { encodeAbiParameters, type Hex } from 'viem'
import { FACTOR_SCALE } from './market'

// One DemoPyth update entry: an abi-encoded PythStructs.PriceFeed, the same encoding as Pyth's MockPyth.
const priceStruct = {
  type: 'tuple',
  components: [
    { name: 'price', type: 'int64' },
    { name: 'conf', type: 'uint64' },
    { name: 'expo', type: 'int32' },
    { name: 'publishTime', type: 'uint256' },
  ],
} as const

const priceFeedParams = [
  {
    type: 'tuple',
    components: [{ name: 'id', type: 'bytes32' }, { ...priceStruct, name: 'price' }, { ...priceStruct, name: 'emaPrice' }],
  },
] as const

export interface FeedReading {
  pythFeedId: Hex
  answer: bigint
  decimals: number
}

/**
 * Builds the update the app sends with every price-dependent call: each Chainlink answer becomes a
 * DemoPyth price with `confBps` of confidence, published at the latest block's timestamp. DemoPyth
 * rejects a publishTime in the future, and the oracle rejects one older than 60 seconds, so the
 * timestamp comes from the chain rather than the visitor's clock.
 */
export function buildPriceUpdate(feeds: FeedReading[], confBps: bigint, publishTime: bigint): Hex[] {
  return feeds.map((f) => {
    const price = {
      price: f.answer,
      conf: (f.answer * confBps) / FACTOR_SCALE,
      expo: -f.decimals,
      publishTime,
    }
    return encodeAbiParameters(priceFeedParams, [{ id: f.pythFeedId, price, emaPrice: price }])
  })
}
