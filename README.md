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
* LPResourceAccount
* Swap

## Add as dependency

Update your `Move.toml` with

```toml
[dependencies.AnimeSwap]
git = 'https://github.com/AnimeSwap/v1-core.git'
rev = 'v0.4.1'
subdir = 'Swap'
```

Swap example:
```move
use SwapDeployer::AnimeSwapPoolV1;
...
// swap X to `amount_out` Y
let amount_out = 100000;
let amount_in = AnimeSwapPoolV1::get_amounts_in_1_pair<X, Y>(amount);
// check if `amount_in` meets your demand
let coins_in = coin::withdraw(&account, amount_in);
let coins_out = AnimeSwapPoolV1::swap_coins_for_coins<X, Y>(coins_in);
assert!(coin::value(&coins_out) == amount_out, 2);
```

Flash swap example:
```move
use SwapDeployer::AnimeSwapPoolV1Library;
use SwapDeployer::AnimeSwapPoolV1;
...
// loan `amount` X and repay Y
let amount = 100000;
let repay_amount = AnimeSwapPoolV1::get_amounts_in_1_pair<X, Y>(amount);
let coins_out;
if (AnimeSwapPoolV1Library::compare<X, Y>()) {
    // flash loan X
    let (coins_in, coins_in_zero, flash_swap) = AnimeSwapPoolV1::flash_swap<X, Y>(amount, 0);
    coin::destroy_zero<Y>(coins_in_zero);
    // do something with coins_in and get coins_out
    coins_out = f(coins_in);
    // repay Y
    let repay_coins = coin::extract(&mut coins_out, repay_amount);
    AnimeSwapPoolV1::pay_flash_swap<X, Y>(coin::zero<X>(), repay_coins, flash_swap);
} else {
    // flash loan X
    let (coins_in_zero, coins_in, flash_swap) = AnimeSwapPoolV1::flash_swap<Y, X>(0, amount);
    coin::destroy_zero<Y>(coins_in_zero);
    // do something with coins_in and get coins_out
    coins_out = f(coins_in);
    // repay Y
    let repay_coins = coin::extract(&mut coins_out, repay_amount);
    AnimeSwapPoolV1::pay_flash_swap<Y, X>(repay_coins, coin::zero<X>(), flash_swap);
};
// keep the reset `coins_out`
```