module SwapDeployer::AnimeSwapPoolV1Library {
    use ResourceAccountDeployer::LPCoinV1::LPCoin;
    use std::signer;
    use std::type_info;
    use aptos_std::string;
    use aptos_std::comparator::Self;
    use aptos_framework::coin;
    use std::option::{Self};
    use u256::u256;

    const INSUFFICIENT_AMOUNT: u64 = 201;
    const INSUFFICIENT_LIQUIDITY: u64 = 202;
    const INSUFFICIENT_INPUT_AMOUNT: u64 = 203;
    const INSUFFICIENT_OUTPUT_AMOUNT: u64 = 204;
    const COIN_TYPE_SAME_ERROR: u64 = 205;

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    public fun quote(
        amount_x: u64,
        reserve_x: u64,
        reserve_y: u64
    ) :u64 {
        assert!(amount_x > 0, INSUFFICIENT_AMOUNT);
        assert!(reserve_x > 0 && reserve_y > 0, INSUFFICIENT_LIQUIDITY);
        let amount_y = ((amount_x as u128) * (reserve_y as u128) / (reserve_x as u128) as u64);
        amount_y
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    public fun get_amount_out(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        swap_fee: u64
    ): u64 {
        assert!(amount_in > 0, INSUFFICIENT_INPUT_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, INSUFFICIENT_LIQUIDITY);
        // use u256 to prevent overflow
        let amount_in_with_fee = u256::mul(u256::from_u64(amount_in), u256::from_u64(10000 - swap_fee));
        let numerator = u256::mul(amount_in_with_fee, u256::from_u64(reserve_out));
        let denominator = u256::add(u256::mul(u256::from_u64(reserve_in), u256::from_u64(10000)), amount_in_with_fee);
        let amount_out = u256::as_u64(u256::div(numerator, denominator));
        amount_out
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    public fun get_amount_in(
        amount_out: u64,
        reserve_in: u64,
        reserve_out: u64,
        swap_fee: u64
    ): u64 {
        assert!(amount_out > 0, INSUFFICIENT_OUTPUT_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, INSUFFICIENT_LIQUIDITY);
        // use u256 to prevent overflow
        let numerator = u256::mul(u256::mul(u256::from_u64(reserve_in), u256::from_u64(amount_out)), u256::from_u64(10000));
        let denominator = u256::mul( u256::sub(u256::from_u64(reserve_out), u256::from_u64(amount_out)), u256::from_u64(10000 - swap_fee));
        let amount_in = u256::as_u64(u256::div(numerator, denominator)) + 1;
        amount_in
    }

    // sqrt function
    public fun sqrt(
        x: u64,
        y: u64
    ): u64 {
        sqrt_128((x as u128) * (y as u128))
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    public fun sqrt_128(
        y: u128
    ): u64 {
        if (y < 4) {
            if (y == 0) {
                0
            } else {
                1
            }
        } else {
            let z = y;
            let x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            };
            (z as u64)
        }
    }

    // return Math.min
    public fun min(
        x:u64,
        y:u64
    ): u64 {
        if (x < y) return x else return y
    }

    // compare type, when use, CoinType1 should < CoinType2
    public fun compare<CoinType1, CoinType2>(): bool{
        let type_name_coin_1 = type_info::type_name<CoinType1>();
        let type_name_coin_2 = type_info::type_name<CoinType2>();
        assert!(type_name_coin_1 != type_name_coin_2, COIN_TYPE_SAME_ERROR);

        if (string::length(&type_name_coin_1) < string::length(&type_name_coin_2)) return true;
        if (string::length(&type_name_coin_1) > string::length(&type_name_coin_2)) return false;

        let struct_cmp = comparator::compare(&type_name_coin_1, &type_name_coin_2);
        comparator::is_smaller_than(&struct_cmp)
    }

    // get coin::supply<LPCoin<CoinType1, CoinType2>>
    public fun get_lpcoin_total_supply<CoinType1, CoinType2>(): u128 {
        option::get_with_default(
            &coin::supply<LPCoin<CoinType1, CoinType2>>(),
            0u128
        )
    }

    // register coin if not registered
    public fun register_coin<CoinType>(
        account: &signer
    ) {
        let account_addr = signer::address_of(account);
        if (!coin::is_account_registered<CoinType>(account_addr)) {
            coin::register<CoinType>(account);
        };
    }

    // register coin if to not registerd and account address equals to address
    // return bool: whether to address registerd after this func call
    public fun try_register_coin<CoinType>(
        account: &signer,
        to: address
    ): bool {
        if (coin::is_account_registered<CoinType>(to)) return true;
        if (signer::address_of(account) == to) {
            coin::register<CoinType>(account);
            return true
        };
        false
    }

    #[test_only]
    use SwapDeployer::TestCoinsV1::{BTC, USDT};
    #[test_only]
    const TEST_ERROR:u64 = 10000;
    #[test_only]
    const SQRT_ERROR:u64 = 10001;
    #[test_only]
    const QUOTE_ERROR:u64 = 10002;

    #[test]
    public entry fun test_last_price_x_cumulative_overflow() {
        let u128_max = 340282366920938463463374607431768211455u128;
        let u128_max_u256 = u256::from_u128(u128_max);
        let u128_max_add_1_u256 = u256::add(u128_max_u256, u256::from_u64(1));
        let u128_max_add_2_u256 = u256::add(u128_max_u256, u256::from_u64(2));
        let a = u256::as_u128(u256::shr(u256::shl(u128_max_u256, 128), 128));
        assert!(a == u128_max, TEST_ERROR);
        let b = u256::as_u128(u256::shr(u256::shl(u128_max_add_1_u256, 128), 128));
        assert!(b == 0, TEST_ERROR);
        let c = u256::as_u128(u256::shr(u256::shl(u128_max_add_2_u256, 128), 128));
        assert!(c == 1, TEST_ERROR);
    }

    #[test]
    public entry fun test_sqrt() {
        let a = sqrt(1, 100);
        assert!(a == 10, SQRT_ERROR);
        let a = sqrt(1, 1000);
        assert!(a == 31, SQRT_ERROR);
        let a = sqrt(10003, 7);
        assert!(a == 264, SQRT_ERROR);
        let a = sqrt(999999999999999, 1);
        assert!(a == 31622776, SQRT_ERROR);
    }

    #[test]
    public entry fun test_quote() {
        let a = quote(123, 456, 789);
        assert!(a == 212, QUOTE_ERROR);
    }

    #[test]
    public entry fun test_get_amount_out() {
        let a = get_amount_out(123456789, 456789123, 789123456, 30);
        assert!(a == 167502115, TEST_ERROR);
    }

    #[test]
    public entry fun test_get_amount_in() {
        let a = get_amount_in(123456789, 456789123, 789123456, 30);
        assert!(a == 84972572, TEST_ERROR);
    }

    #[test_only]
    struct TestCoinA {}
    #[test_only]
    struct TestCoinB {}

    #[test]
    public entry fun test_compare() {
        let a = compare<USDT, BTC>();
        assert!(a == false, TEST_ERROR);
        let a = compare<BTC, USDT>();
        assert!(a == true, TEST_ERROR);
        let a = compare<TestCoinA, TestCoinB>();
        assert!(a == true, TEST_ERROR);
    }
}