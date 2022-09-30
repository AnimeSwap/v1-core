# AnimeSwap

**AnimeSwap** is AMM protocol for [Aptos](https://www.aptos.com/) blockchain. 

* [Contracts documents](https://docs.animeswap.org/docs/contracts)
* [SDK](https://github.com/AnimeSwap/v1-sdk)

The current repository contains: 

* u256
* uq64x64
* TestCoin
* Faucet
* LPCoin
* SwapLibrary
* LPResourceAccount
* Swap

## Add as dependency

Update your `Move.toml` with

```toml
[dependencies.Liquidswap]
git = 'https://github.com/AnimeSwap/v1-core.git'
rev = 'v0.3.0'
subdir = 'Swap'
```

Swap example:
```move
use SwapDeployer::AnimeSwapPoolV1;
use SwapDeployer::AnimeSwapPoolV1Library;
use SwapDeployer::TestCoinsV1::{BTC, USDT};
use std::signer;
use aptos_framework::timestamp;
use aptos_framework::coin;

...

let amount_in = 100000;
let amount_out_desired = 100000;
let (reserve_x, reserve_y, _) = AnimeSwapPoolV1::get_reserves<BTC, USDT>();
let (swap_fee, _, _, _) = AnimeSwapPoolV1::get_admin_data();
let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_x, reserve_y, swap_fee);

assert!(amount_out >= amount_out_desired, 1);
let coins_in = coin::withdraw<BTC>(account, amount_in);
let coins_out = AnimeSwapPoolV1::swap_coins_for_coins_1<BTC, USDT>(account, coins_in, timestamp::now_seconds());
assert!(coin::value(&coins_out) == amount_out, 2);
```

Flash swap example:
```move
// loan `amount_in` BTC and repay USDT
let amount_in = 100000;
let (reserve_x, reserve_y, _) = AnimeSwapPoolV1::get_reserves<BTC, USDT>();
let (swap_fee, _, _, _) = AnimeSwapPoolV1::get_admin_data();
let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_x, reserve_y, swap_fee);

let (coin_out_1, coin_out_2, flash_swap) = AnimeSwapPoolV1::flash_swap<BTC, USDT>(amount_in, 0);

// do something with `coin_out_1` and `coin_out_2`
coin::deposit<BTC>(to, coin_out_1);
coin::deposit<USDT>(to, coin_out_2);

// repay `amount_out` USDT
let repay_coin_2 = coin::withdraw<USDT>(account, amount_out);
AnimeSwapPoolV1::pay_flash_swap<BTC, USDT>(account, coin::zero<BTC>(), repay_coin_2, flash_swap);
```