module SwapDeployer::AnimeSwapPoolV1 {
    use ResourceAccountDeployer::LPCoinV1::LPCoin;
    use SwapDeployer::AnimeSwapPoolV1Library;
    use SwapDeployer::lp_resource_account;
    use std::signer;
    use std::type_info::{Self, TypeInfo};
    use std::string::utf8;
    use std::event;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin, MintCapability, FreezeCapability, BurnCapability};
    use aptos_framework::account::{Self, SignerCapability};
    use u256::u256;
    use uq64x64::uq64x64;
    // use std::debug;    // For debug

    struct LiquidityPool<phantom CoinType1, phantom CoinType2, phantom LPCoin> has key {
        coin_x_reserve: Coin<CoinType1>,
        coin_y_reserve: Coin<CoinType2>,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        k_last: u128,
        lp_mint_cap: MintCapability<LPCoin>,
        lp_freeze_cap: FreezeCapability<LPCoin>,
        lp_burn_cap: BurnCapability<LPCoin>,
        locked: bool,
    }

    // resource_account has this resource as admin_data
    struct AdminData has key, drop {
        signer_cap: SignerCapability,
        dao_fee_to: address,
        admin_address: address,
        dao_fee: u8,   // 1/(dao_fee+1) comes to dao_fee_to if dao_fee_on
        swap_fee: u64,  // BP, swap_fee * 1/10000
        dao_fee_on: bool,   // default: true
        is_pause_flash: bool, // pause flash swap
    }

    struct PairMeta has drop, store, copy {
        coin_x: TypeInfo,
        coin_y: TypeInfo,
        lp_coin: TypeInfo,
    }

    // resource_account has this resource for pair list
    struct PairInfo has key {
        pair_list: vector<PairMeta>,
    }

    struct Events<phantom CoinType1, phantom CoinType2> has key {
        pair_created_event: event::EventHandle<PairCreatedEvent<CoinType1, CoinType2>>,
        mint_event: event::EventHandle<MintEvent<CoinType1, CoinType2>>,
        burn_event: event::EventHandle<BurnEvent<CoinType1, CoinType2>>,
        swap_event: event::EventHandle<SwapEvent<CoinType1, CoinType2>>,
        sync_event: event::EventHandle<SyncEvent<CoinType1, CoinType2>>,
        flash_swap_event: event::EventHandle<FlashSwapEvent<CoinType1, CoinType2>>,
    }

    struct PairCreatedEvent<phantom CoinType1, phantom CoinType2> has drop, store {
        sender_address: address,
        meta: PairMeta,
    }

    struct MintEvent<phantom CoinType1, phantom CoinType2> has drop, store {
        sender_address: address,
        amount_x: u64,
        amount_y: u64,
    }

    struct BurnEvent<phantom CoinType1, phantom CoinType2> has drop, store {
        sender_address: address,
        amount_x: u64,
        amount_y: u64,
    }

    struct SwapEvent<phantom CoinType1, phantom CoinType2> has drop, store {
        sender_address: address,
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64,
    }

    struct SyncEvent<phantom CoinType1, phantom CoinType2> has drop, store {
        reserve_x: u64,
        reserve_y: u64,
    }

    struct FlashSwapEvent<phantom CoinType1, phantom CoinType2> has drop, store {
        sender_address: address,
        loan_coin_1: u64,
        loan_coin_2: u64,
        repay_coin_1: u64,
        repay_coin_2: u64,
    }

    // no copy, no drop
    struct FlashSwap<phantom CoinType1, phantom CoinType2> {
        loan_coin_1: u64,
        loan_coin_2: u64
    }

    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MAX_U64: u64 = 18446744073709551615u64;

    const TIME_EXPIRED: u64 = 101;
    const INTERNAL_ERROR: u64 = 102;
    const FORBIDDEN: u64 = 103;
    const INSUFFICIENT_AMOUNT: u64 = 104;
    const INSUFFICIENT_LIQUIDITY: u64 = 105;
    const INSUFFICIENT_LIQUIDITY_MINT: u64 = 106;
    const INSUFFICIENT_LIQUIDITY_BURN: u64 = 107;
    const INSUFFICIENT_X_AMOUNT: u64 = 108;
    const INSUFFICIENT_Y_AMOUNT: u64 = 109;
    const INSUFFICIENT_INPUT_AMOUNT: u64 = 110;
    const INSUFFICIENT_OUTPUT_AMOUNT: u64 = 111;
    const K_ERROR: u64 = 112;
    const TO_ADDRESS_NOT_REGISTER_COIN_ERROR: u64 = 114;
    const PAIR_ALREADY_EXIST: u64 = 115;
    const PAIR_NOT_EXIST: u64 = 116;
    const LOAN_ERROR: u64 = 117;
    const LOCK_ERROR: u64 = 118;
    const PAIR_ORDER_ERROR: u64 = 119;
    const PAUSABLE_ERROR: u64 = 120;

    const DEPLOYER_ADDRESS: address = @SwapDeployer;
    const RESOURCE_ACCOUNT_ADDRESS: address = @ResourceAccountDeployer;

    // initialize
    fun init_module(admin: &signer) {
        // init admin data
        let signer_cap = lp_resource_account::retrieve_signer_cap(admin);
        let resource_account = &account::create_signer_with_capability(&signer_cap);
        move_to(resource_account, AdminData {
            signer_cap,
            dao_fee_to: DEPLOYER_ADDRESS,
            admin_address: DEPLOYER_ADDRESS,
            dao_fee: 5,         // 1/6 to dao fee
            swap_fee: 30,       // 0.3%
            dao_fee_on: true,  // default true
            is_pause_flash: false,    // default false
        });
        // init pair info
        move_to(resource_account, PairInfo{
            pair_list: vector::empty(),
        });
    }

    // multiple pairs
    public fun get_amounts_out_1_pair<CoinType1, CoinType2>(
        amount_in: u64
    ): u64 acquires LiquidityPool, AdminData {
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_in, reserve_out, swap_fee);
        amount_out
    }

    // multiple pairs
    public fun get_amounts_out_2_pair<CoinType1, CoinType2, CoinType3>(
        amount_in: u64
    ): u64 acquires LiquidityPool, AdminData {
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_mid = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType2, CoinType3>()) {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType3, LPCoin<CoinType2, CoinType3>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType3, CoinType2, LPCoin<CoinType3, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_mid, reserve_in, reserve_out, swap_fee);
        amount_out
    }

    // multiple pairs
    public fun get_amounts_out_3_pair<CoinType1, CoinType2, CoinType3, CoinType4>(
        amount_in: u64
    ): u64 acquires LiquidityPool, AdminData {
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_mid = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType2, CoinType3>()) {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType3, LPCoin<CoinType2, CoinType3>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType3, CoinType2, LPCoin<CoinType3, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_mid = AnimeSwapPoolV1Library::get_amount_out(amount_mid, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType3, CoinType4>()) {
            let lp = borrow_global<LiquidityPool<CoinType3, CoinType4, LPCoin<CoinType3, CoinType4>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType4, CoinType3, LPCoin<CoinType4, CoinType3>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_mid, reserve_in, reserve_out, swap_fee);
        amount_out
    }

    // multiple pairs
    public fun get_amounts_in_1_pair<CoinType1, CoinType2>(
        amount_out: u64
    ): u64 acquires LiquidityPool, AdminData {
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_in = AnimeSwapPoolV1Library::get_amount_in(amount_out, reserve_in, reserve_out, swap_fee);
        amount_in
    }

    // multiple pairs
    public fun get_amounts_in_2_pair<CoinType1, CoinType2, CoinType3>(
        amount_out: u64
    ): u64 acquires LiquidityPool, AdminData {
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out);
        if (AnimeSwapPoolV1Library::compare<CoinType2, CoinType3>()) {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType3, LPCoin<CoinType2, CoinType3>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType3, CoinType2, LPCoin<CoinType3, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_mid = AnimeSwapPoolV1Library::get_amount_in(amount_out, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_in = AnimeSwapPoolV1Library::get_amount_in(amount_mid, reserve_in, reserve_out, swap_fee);
        amount_in
    }

    // multiple pairs
    public fun get_amounts_in_3_pair<CoinType1, CoinType2, CoinType3, CoinType4>(
        amount_out: u64
    ): u64 acquires LiquidityPool, AdminData {
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out);
        if (AnimeSwapPoolV1Library::compare<CoinType3, CoinType4>()) {
            let lp = borrow_global<LiquidityPool<CoinType3, CoinType4, LPCoin<CoinType3, CoinType4>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType4, CoinType3, LPCoin<CoinType4, CoinType3>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_mid = AnimeSwapPoolV1Library::get_amount_in(amount_out, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType2, CoinType3>()) {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType3, LPCoin<CoinType2, CoinType3>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType3, CoinType2, LPCoin<CoinType3, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_mid = AnimeSwapPoolV1Library::get_amount_in(amount_mid, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        } else {
            let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
            (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        };
        let amount_in = AnimeSwapPoolV1Library::get_amount_in(amount_mid, reserve_in, reserve_out, swap_fee);
        amount_in
    }

    // get pair meta with `CoinType1`, `CoinType2`
    public fun get_pair_meta<CoinType1, CoinType2>(): PairMeta {
        let coin_x_type_info = type_info::type_of<CoinType1>();
        let coin_y_type_info = type_info::type_of<CoinType2>();
        let lp_coin_type_info = type_info::type_of<LPCoin<CoinType1, CoinType2>>();
        PairMeta {
            coin_x: coin_x_type_info,
            coin_y: coin_y_type_info,
            lp_coin: lp_coin_type_info,
        }
    }

    // require lp unlocked
    fun assert_lp_unlocked<CoinType1, CoinType2>() acquires LiquidityPool {
        assert!(exists<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS), PAIR_NOT_EXIST);
        let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(lp.locked == false, LOCK_ERROR);
    }

    fun when_paused() acquires AdminData {
        assert!(borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).is_pause_flash == true, PAUSABLE_ERROR);
    }

    fun when_not_paused() acquires AdminData {
        assert!(borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).is_pause_flash == false, PAUSABLE_ERROR);
    }

    // return pair admin account signer
    fun get_resource_account_signer(): signer acquires AdminData {
        let signer_cap = &borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).signer_cap;
        account::create_signer_with_capability(signer_cap)
    }

    // create account & register coin
    fun create_pair<CoinType1, CoinType2>(account: &signer) acquires AdminData, PairInfo {
        // check lp not exist
        assert!(!exists<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS), PAIR_ALREADY_EXIST);
        let resource_account_signer = get_resource_account_signer();
        // create lp coin
        let (lp_b, lp_f, lp_m) = coin::initialize<LPCoin<CoinType1, CoinType2>>(&resource_account_signer, utf8(b"AnimeSwapLPCoin"), utf8(b"ANILPCoin"), 8, true);
        // register coin
        AnimeSwapPoolV1Library::register_coin<LPCoin<CoinType1, CoinType2>>(&resource_account_signer);
        // register LiquidityPool
        move_to(&resource_account_signer, LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>{
            coin_x_reserve: coin::zero<CoinType1>(), coin_y_reserve: coin::zero<CoinType2>(), last_block_timestamp: 0,
            last_price_x_cumulative: 0, last_price_y_cumulative: 0, k_last: 0,
            lp_mint_cap: lp_m, lp_freeze_cap: lp_f, lp_burn_cap: lp_b,
            locked: false,
        });
        // add pair_info
        let pair_meta = get_pair_meta<CoinType1, CoinType2>();
        let pair_info = borrow_global_mut<PairInfo>(RESOURCE_ACCOUNT_ADDRESS);
        vector::push_back<PairMeta>(&mut pair_info.pair_list, copy pair_meta);

        // init events
        let events = Events<CoinType1, CoinType2> {
            pair_created_event: account::new_event_handle<PairCreatedEvent<CoinType1, CoinType2>>(&resource_account_signer),
            mint_event: account::new_event_handle<MintEvent<CoinType1, CoinType2>>(&resource_account_signer),
            burn_event: account::new_event_handle<BurnEvent<CoinType1, CoinType2>>(&resource_account_signer),
            swap_event: account::new_event_handle<SwapEvent<CoinType1, CoinType2>>(&resource_account_signer),
            sync_event: account::new_event_handle<SyncEvent<CoinType1, CoinType2>>(&resource_account_signer),
            flash_swap_event: account::new_event_handle<FlashSwapEvent<CoinType1, CoinType2>>(&resource_account_signer),
        };
        event::emit_event(&mut events.pair_created_event, PairCreatedEvent {
            sender_address: signer::address_of(account),
            meta: pair_meta,
        });
        move_to(&resource_account_signer, events);
    }

    fun add_liquidity_internal<CoinType1, CoinType2>(
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64
    ): (u64, u64) acquires LiquidityPool {
        let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_x, reserve_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        if (reserve_x == 0 && reserve_y == 0) {
            (amount_x_desired, amount_y_desired)
        } else {
            let amount_y_optimal = AnimeSwapPoolV1Library::quote(amount_x_desired, reserve_x, reserve_y);
            if (amount_y_optimal <= amount_y_desired) {
                assert!(amount_y_optimal >= amount_y_min, INSUFFICIENT_Y_AMOUNT);
                (amount_x_desired, amount_y_optimal)
            } else {
                let amount_x_optimal = AnimeSwapPoolV1Library::quote(amount_y_desired, reserve_y, reserve_x);
                assert!(amount_x_optimal <= amount_x_desired, INTERNAL_ERROR);
                assert!(amount_x_optimal >= amount_x_min, INSUFFICIENT_X_AMOUNT);
                (amount_x_optimal, amount_y_desired)
            }
        }
    }

    fun swap_internal_1<CoinType1, CoinType2>(
        account: &signer,
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64,
        coins_in: Coin<CoinType1>
    ): Coin<CoinType2> acquires LiquidityPool, AdminData, Events {
        assert!(amount_x_in > 0 || amount_y_in > 0, INSUFFICIENT_INPUT_AMOUNT);
        assert!(amount_x_out > 0 || amount_y_out > 0, INSUFFICIENT_OUTPUT_AMOUNT);
        assert_lp_unlocked<CoinType1, CoinType2>();
        let lp = borrow_global_mut<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_x, reserve_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        coin::merge(&mut lp.coin_x_reserve, coins_in);
        let (balance_x, balance_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        assert!(amount_x_out < reserve_x && amount_y_out < reserve_y, INSUFFICIENT_LIQUIDITY);

        let coins_out = coin::extract(&mut lp.coin_y_reserve, amount_y_out);
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let balance_x_adjusted = (balance_x as u128) * 10000 - (amount_x_in as u128) * (swap_fee as u128);
        let balance_y_adjusted = (balance_y as u128) * 10000 - (amount_y_in as u128) * (swap_fee as u128);
        // use u256 to prevent overflow
        // should be: balance_x * balance_y >= reserve_x * reserve_y
        assert!(u256::compare(&u256::add(u256::mul(u256::from_u128(balance_x_adjusted), u256::from_u128(balance_y_adjusted)), u256::from_u64(1)),
            &u256::mul(u256::mul(u256::from_u64(reserve_x), u256::from_u64(reserve_y)), u256::from_u64(100000000))) == 2, K_ERROR);
        // update internal
        update_internal(lp, balance_x, balance_y, reserve_x, reserve_y);
        // event
        let events = borrow_global_mut<Events<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS);
        event::emit_event(&mut events.swap_event, SwapEvent {
            sender_address: signer::address_of(account),
            amount_x_in,
            amount_y_in,
            amount_x_out,
            amount_y_out,
        });
        coins_out
    }

    fun swap_internal_2<CoinType1, CoinType2>(
        account: &signer,
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64,
        coins_in: Coin<CoinType2>
    ): Coin<CoinType1> acquires LiquidityPool, AdminData, Events {
        assert!(amount_x_in > 0 || amount_y_in > 0, INSUFFICIENT_INPUT_AMOUNT);
        assert!(amount_x_out > 0 || amount_y_out > 0, INSUFFICIENT_OUTPUT_AMOUNT);
        assert_lp_unlocked<CoinType1, CoinType2>();
        let lp = borrow_global_mut<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_x, reserve_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        coin::merge(&mut lp.coin_y_reserve, coins_in);
        let (balance_x, balance_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        assert!(amount_x_out < reserve_x && amount_y_out < reserve_y, INSUFFICIENT_LIQUIDITY);

        let coins_out = coin::extract(&mut lp.coin_x_reserve, amount_x_out);
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let balance_x_adjusted = (balance_x as u128) * 10000 - (amount_x_in as u128) * (swap_fee as u128);
        let balance_y_adjusted = (balance_y as u128) * 10000 - (amount_y_in as u128) * (swap_fee as u128);
        // use u256 to prevent overflow
        // should be: balance_x * balance_y >= reserve_x * reserve_y
        assert!(u256::compare(&u256::add(u256::mul(u256::from_u128(balance_x_adjusted), u256::from_u128(balance_y_adjusted)), u256::from_u64(1)),
            &u256::mul(u256::mul(u256::from_u64(reserve_x), u256::from_u64(reserve_y)), u256::from_u64(100000000))) == 2, K_ERROR);
        // update internal
        update_internal(lp, balance_x, balance_y, reserve_x, reserve_y);
        // event
        let events = borrow_global_mut<Events<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS);
        event::emit_event(&mut events.swap_event, SwapEvent {
            sender_address: signer::address_of(account),
            amount_x_in,
            amount_y_in,
            amount_x_out,
            amount_y_out,
        });
        coins_out
    }

    /**
     * entry functions
     */

    // add liquidity. if pair not exist, create pair first
    public entry fun add_liquidity_entry<CoinType1, CoinType2>(
        account: &signer,
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64
    ) acquires LiquidityPool, AdminData, PairInfo, Events {
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            if (!exists<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS)) {
                create_pair<CoinType1, CoinType2>(account);
            };
            add_liquidity<CoinType1, CoinType2>(account, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min, deadline);
        } else {
            if (!exists<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS)) {
                create_pair<CoinType2, CoinType1>(account);
            };
            add_liquidity<CoinType2, CoinType1>(account, amount_y_desired, amount_x_desired, amount_y_min, amount_x_min, deadline);
        }
    }

    // remove liquidity
    public entry fun remove_liquidity_entry<CoinType1, CoinType2>(
        account: &signer,
        liquidity: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            remove_liquidity<CoinType1, CoinType2>(account, liquidity, amount_x_min, amount_y_min, deadline);
        } else {
            remove_liquidity<CoinType2, CoinType1>(account, liquidity, amount_y_min, amount_x_min, deadline);
        }
    }

    // 1 pair swap CoinType1->CoinType2
    public entry fun swap_exact_coins_for_coins_entry<CoinType1, CoinType2>(
        account: &signer,
        amount_in: u64,
        amount_out_min: u64,
        to: address,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        {
            // check to address register first
            let succ = AnimeSwapPoolV1Library::try_register_coin<CoinType2>(account, to);
            assert!(succ == true, TO_ADDRESS_NOT_REGISTER_COIN_ERROR);
            let amount_out = get_amounts_out_1_pair<CoinType1, CoinType2>(amount_in);
            assert!(amount_out >= amount_out_min, INSUFFICIENT_OUTPUT_AMOUNT);
        };
        // swap
        let coins_in = coin::withdraw<CoinType1>(account, amount_in);
        let coins_out;
        coins_out = swap_coins_for_coins<CoinType1, CoinType2>(account, coins_in, deadline);
        coin::deposit<CoinType2>(to, coins_out);
    }

    // 2 pairs swap CoinType1->CoinType2->CoinType3
    public entry fun swap_exact_coins_for_coins_2_pair_entry<CoinType1, CoinType2, CoinType3>(
        account: &signer,
        amount_in: u64,
        amount_out_min: u64,
        to: address,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        {
            // check to address register first
            let succ = AnimeSwapPoolV1Library::try_register_coin<CoinType3>(account, to);
            assert!(succ == true, TO_ADDRESS_NOT_REGISTER_COIN_ERROR);
            let amount_out = get_amounts_out_2_pair<CoinType1, CoinType2, CoinType3>(amount_in);
            assert!(amount_out >= amount_out_min, INSUFFICIENT_OUTPUT_AMOUNT);
        };
        // swap
        let coins_in = coin::withdraw<CoinType1>(account, amount_in);
        let coins_out;
        let coins_mid;
        coins_mid = swap_coins_for_coins<CoinType1, CoinType2>(account, coins_in, deadline);
        coins_out = swap_coins_for_coins<CoinType2, CoinType3>(account, coins_mid, deadline);
        coin::deposit<CoinType3>(to, coins_out);
    }

    // 3 pairs swap CoinType1->CoinType2->CoinType3->CoinType4
    public entry fun swap_exact_coins_for_coins_3_pair_entry<CoinType1, CoinType2, CoinType3, CoinType4>(
        account: &signer,
        amount_in: u64,
        amount_out_min: u64,
        to: address,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        {
            // check to address register first
            let succ = AnimeSwapPoolV1Library::try_register_coin<CoinType4>(account, to);
            assert!(succ == true, TO_ADDRESS_NOT_REGISTER_COIN_ERROR);
            let amount_out = get_amounts_out_3_pair<CoinType1, CoinType2, CoinType3, CoinType4>(amount_in);
            assert!(amount_out >= amount_out_min, INSUFFICIENT_OUTPUT_AMOUNT);
        };
        // swap
        let coins_in = coin::withdraw<CoinType1>(account, amount_in);
        let coins_out;
        let coins_mid;
        let coins_mid_2;
        coins_mid = swap_coins_for_coins<CoinType1, CoinType2>(account, coins_in, deadline);
        coins_mid_2 = swap_coins_for_coins<CoinType2, CoinType3>(account, coins_mid, deadline);
        coins_out = swap_coins_for_coins<CoinType3, CoinType4>(account, coins_mid_2, deadline);
        coin::deposit<CoinType4>(to, coins_out);
    }

    // 1 pair swap CoinType1->CoinType2
    public entry fun swap_coins_for_exact_coins_entry<CoinType1, CoinType2>(
        account: &signer,
        amount_out: u64,
        amount_in_max: u64,
        to: address,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        let amount_in;
        {
            // check to address register first
            let succ = AnimeSwapPoolV1Library::try_register_coin<CoinType2>(account, to);
            assert!(succ == true, TO_ADDRESS_NOT_REGISTER_COIN_ERROR);
            amount_in = get_amounts_in_1_pair<CoinType1, CoinType2>(amount_out);
            assert!(amount_in <= amount_in_max, INSUFFICIENT_INPUT_AMOUNT);
        };
        let coins_in = coin::withdraw<CoinType1>(account, amount_in);
        let coins_out;
        coins_out = swap_coins_for_coins<CoinType1, CoinType2>(account, coins_in, deadline);
        coin::deposit<CoinType2>(to, coins_out);
    }

    // 2 pairs swap CoinType1->CoinType2->CoinType3
    public entry fun swap_coins_for_exact_coins_2_pair_entry<CoinType1, CoinType2, CoinType3>(
        account: &signer,
        amount_out: u64,
        amount_in_max: u64,
        to: address,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        let amount_in;
        {
            // check to address register first
            let succ = AnimeSwapPoolV1Library::try_register_coin<CoinType3>(account, to);
            assert!(succ == true, TO_ADDRESS_NOT_REGISTER_COIN_ERROR);
            amount_in = get_amounts_in_2_pair<CoinType1, CoinType2, CoinType3>(amount_out);
            assert!(amount_in <= amount_in_max, INSUFFICIENT_INPUT_AMOUNT);
        };
        // swap
        let coins_in = coin::withdraw<CoinType1>(account, amount_in);
        let coins_out;
        let coins_mid;
        coins_mid = swap_coins_for_coins<CoinType1, CoinType2>(account, coins_in, deadline);
        coins_out = swap_coins_for_coins<CoinType2, CoinType3>(account, coins_mid, deadline);
        coin::deposit<CoinType3>(to, coins_out);
    }

    // 3 pairs swap CoinType1->CoinType2->CoinType3->CoinType4
    public entry fun swap_coins_for_exact_coins_3_pair_entry<CoinType1, CoinType2, CoinType3, CoinType4>(
        account: &signer,
        amount_out: u64,
        amount_in_max: u64,
        to: address,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        let amount_in;
        {
            // check to address register first
            let succ = AnimeSwapPoolV1Library::try_register_coin<CoinType4>(account, to);
            assert!(succ == true, TO_ADDRESS_NOT_REGISTER_COIN_ERROR);
            amount_in = get_amounts_in_3_pair<CoinType1, CoinType2, CoinType3, CoinType4>(amount_out);
            assert!(amount_in <= amount_in_max, INSUFFICIENT_INPUT_AMOUNT);
        };
        // swap
        let coins_in = coin::withdraw<CoinType1>(account, amount_in);
        let coins_out;
        let coins_mid;
        let coins_mid_2;
        coins_mid = swap_coins_for_coins<CoinType1, CoinType2>(account, coins_in, deadline);
        coins_mid_2 = swap_coins_for_coins<CoinType2, CoinType3>(account, coins_mid, deadline);
        coins_out = swap_coins_for_coins<CoinType3, CoinType4>(account, coins_mid_2, deadline);
        coin::deposit<CoinType4>(to, coins_out);
    }

    /**
     *  set fee config
     */
    public entry fun set_dao_fee_to(
        account: &signer,
        dao_fee_to: address
    ) acquires AdminData {
        let admin_data = borrow_global_mut<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(signer::address_of(account) == admin_data.admin_address, FORBIDDEN);
        admin_data.dao_fee_to = dao_fee_to;
    }

    public entry fun set_admin_address(
        account: &signer,
        admin_address: address
    ) acquires AdminData {
        let admin_data = borrow_global_mut<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(signer::address_of(account) == admin_data.admin_address, FORBIDDEN);
        admin_data.admin_address = admin_address;
    }

    public entry fun set_dao_fee(
        account: &signer,
        dao_fee: u8
    ) acquires AdminData {
        let admin_data = borrow_global_mut<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(signer::address_of(account) == admin_data.admin_address, FORBIDDEN);
        if (dao_fee == 0) {
            admin_data.dao_fee_on = false;
        } else {
            admin_data.dao_fee_on = true;
            admin_data.dao_fee = dao_fee;
        };
    }

    public entry fun set_swap_fee(
        account: &signer,
        swap_fee: u64
    ) acquires AdminData {
        let admin_data = borrow_global_mut<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(signer::address_of(account) == admin_data.admin_address, FORBIDDEN);
        assert!(swap_fee <= 1000, FORBIDDEN);
        admin_data.swap_fee = swap_fee;
    }

    public entry fun withdraw_dao_fee<CoinType1, CoinType2>(
        account: &signer
    ) acquires AdminData {
        if (!AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            withdraw_dao_fee<CoinType2, CoinType1>(account);
            return
        };
        let admin_data = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        let acc_addr = signer::address_of(account);
        assert!(acc_addr == admin_data.dao_fee_to, FORBIDDEN);
        if (!coin::is_account_registered<LPCoin<CoinType1, CoinType2>>(acc_addr)) {
            coin::register<LPCoin<CoinType1, CoinType2>>(account);
        };
        let amount = coin::balance<LPCoin<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS) - MINIMUM_LIQUIDITY;
        coin::transfer<LPCoin<CoinType1, CoinType2>>(&get_resource_account_signer(), acc_addr, amount);
    }

    public entry fun pause(
        account: &signer
    ) acquires AdminData {
        when_not_paused();
        let admin_data = borrow_global_mut<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(signer::address_of(account) == admin_data.admin_address, FORBIDDEN);
        admin_data.is_pause_flash = true;
    }

    public entry fun unpause(
        account: &signer
    ) acquires AdminData {
        when_paused();
        let admin_data = borrow_global_mut<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(signer::address_of(account) == admin_data.admin_address, FORBIDDEN);
        admin_data.is_pause_flash = false;
    }

    /**
     *  add liquidity
     */
    fun add_liquidity<CoinType1, CoinType2>(
        account: &signer,
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        // check lp exist
        assert!(exists<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS), PAIR_NOT_EXIST);
        // check deadline first
        let now = timestamp::now_seconds();
        assert!(now <= deadline, TIME_EXPIRED);
        let (amount_x, amount_y) = add_liquidity_internal<CoinType1, CoinType2>(amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);
        let coin_x = coin::withdraw<CoinType1>(account, amount_x);
        let coin_y = coin::withdraw<CoinType2>(account, amount_y);
        let lp_coins = mint<CoinType1, CoinType2>(account, coin_x, coin_y);

        let acc_addr = signer::address_of(account);
        if (!coin::is_account_registered<LPCoin<CoinType1, CoinType2>>(acc_addr)) {
            coin::register<LPCoin<CoinType1, CoinType2>>(account);
        };
        coin::deposit(acc_addr, lp_coins);
    }

    /**
     *  remore liquidity
     *  assert CoinType1 < CoinType2
     */
    fun remove_liquidity<CoinType1, CoinType2>(
        account: &signer,
        liquidity: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64
    ) acquires LiquidityPool, AdminData, Events {
        // check deadline first
        let now = timestamp::now_seconds();
        assert!(now <= deadline, TIME_EXPIRED);
        let coin = coin::withdraw<LPCoin<CoinType1, CoinType2>>(account, liquidity);
        let (x_out, y_out) = burn<CoinType1, CoinType2>(account, coin);
        assert!(coin::value(&x_out) >= amount_x_min, INSUFFICIENT_X_AMOUNT);
        assert!(coin::value(&y_out) >= amount_y_min, INSUFFICIENT_Y_AMOUNT);
        // transfer
        coin::deposit(signer::address_of(account), x_out);
        coin::deposit(signer::address_of(account), y_out);
    }

    /**
     *  swap
     *  swap from CoinType1 to CoinType2
     *  no require for cmp(CoinType1, CoinType2)
     */
    public fun swap_coins_for_coins<CoinType1, CoinType2>(
        account: &signer,
        coins_in: Coin<CoinType1>,
        deadline: u64
    ): Coin<CoinType2> acquires LiquidityPool, AdminData, Events {
        // check deadline first
        let now = timestamp::now_seconds();
        assert!(now <= deadline, TIME_EXPIRED);
        let amount_in = coin::value(&coins_in);
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let (reserve_in, reserve_out) =
            if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
                let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
                (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve))
            } else {
                let lp = borrow_global<LiquidityPool<CoinType2, CoinType1, LPCoin<CoinType2, CoinType1>>>(RESOURCE_ACCOUNT_ADDRESS);
                (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve))
            };
        let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_in, reserve_out, swap_fee);
        if (AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            let amount_x_in = amount_in;
            let amount_y_in = 0;
            let amount_x_out = 0;
            let amount_y_out = amount_out;
            swap_internal_1<CoinType1, CoinType2>(account, amount_x_in, amount_y_in, amount_x_out, amount_y_out, coins_in)
        } else {
            let amount_x_in = 0;
            let amount_y_in = amount_in;
            let amount_x_out = amount_out;
            let amount_y_out = 0;
            swap_internal_2<CoinType2, CoinType1>(account, amount_x_in, amount_y_in, amount_x_out, amount_y_out, coins_in)
        }
    }

    /**
     *  @deprecated swap
     *  assert CoinType1 < CoinType2
     *  swap from CoinType1 to CoinType2
     */
    public fun swap_coins_for_coins_1<CoinType1, CoinType2>(
        account: &signer,
        coins_in: Coin<CoinType1>,
        deadline: u64
    ) :Coin<CoinType2> acquires LiquidityPool, AdminData, Events {
        // check deadline first
        let now = timestamp::now_seconds();
        assert!(now <= deadline, TIME_EXPIRED);
        let amount_in = coin::value(&coins_in);
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_in, reserve_out) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_in, reserve_out, swap_fee);
        let amount_x_in = amount_in;
        let amount_y_in = 0;
        let amount_x_out = 0;
        let amount_y_out = amount_out;
        let coins_out = swap_internal_1<CoinType1, CoinType2>(account, amount_x_in, amount_y_in, amount_x_out, amount_y_out, coins_in);
        coins_out
    }

    /**
     *  @deprecated swap
     *  assert CoinType1 < CoinType2
     *  swap from CoinType2 to CoinType1
     */
    public fun swap_coins_for_coins_2<CoinType1, CoinType2>(
        account: &signer,
        coins_in: Coin<CoinType2>,
        deadline: u64
    ) :Coin<CoinType1> acquires LiquidityPool, AdminData, Events {
        // check deadline first
        let now = timestamp::now_seconds();
        assert!(now <= deadline, TIME_EXPIRED);
        let amount_in = coin::value(&coins_in);
        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_in, reserve_out) = (coin::value(&lp.coin_y_reserve), coin::value(&lp.coin_x_reserve));
        let amount_out = AnimeSwapPoolV1Library::get_amount_out(amount_in, reserve_in, reserve_out, swap_fee);
        let amount_x_in = 0;
        let amount_y_in = amount_in;
        let amount_x_out = amount_out;
        let amount_y_out = 0;
        let coins_out = swap_internal_2<CoinType1, CoinType2>(account, amount_x_in, amount_y_in, amount_x_out, amount_y_out, coins_in);
        coins_out
    }

    // update cumulative, coin_reserve, block_timestamp
    fun update_internal<CoinType1, CoinType2>(
        lp: &mut LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>,
        balance_x: u64, // new reserve value
        balance_y: u64,
        reserve_x: u64, // old reserve value
        reserve_y: u64
    ) acquires Events {
        let now = timestamp::now_seconds();
        let time_elapsed = now - lp.last_block_timestamp;
        if (time_elapsed > 0 && reserve_x != 0 && reserve_y != 0) {
            // allow overflow u128
            let last_price_x_cumulative_delta = uq64x64::mul(uq64x64::div(uq64x64::encode(reserve_y), reserve_x), time_elapsed);
            let last_price_x_cumulative_256 = u256::add(u256::from_u128(lp.last_price_x_cumulative), u256::from_u128(uq64x64::to_u128(last_price_x_cumulative_delta)));
            lp.last_price_x_cumulative = u256::as_u128(u256::shr(u256::shl(last_price_x_cumulative_256, 128), 128));

            let last_price_y_cumulative_delta = uq64x64::mul(uq64x64::div(uq64x64::encode(reserve_x), reserve_y), time_elapsed);
            let last_price_y_cumulative_256 = u256::add(u256::from_u128(lp.last_price_y_cumulative), u256::from_u128(uq64x64::to_u128(last_price_y_cumulative_delta)));
            lp.last_price_y_cumulative = u256::as_u128(u256::shr(u256::shl(last_price_y_cumulative_256, 128), 128));
        };
        lp.last_block_timestamp = now;
        // event
        let events = borrow_global_mut<Events<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS);
        event::emit_event(&mut events.sync_event, SyncEvent {
            reserve_x: balance_x,
            reserve_y: balance_y,
        });
    }

    fun mint_fee_interval<CoinType1, CoinType2>(
        lp: &mut LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>,
        admin_data: &AdminData
    ): bool {
        let fee_on = admin_data.dao_fee_on;
        let k_last = lp.k_last;
        if (fee_on) {
            if (k_last != 0) {
                let reserve_x = coin::value(&lp.coin_x_reserve);
                let reserve_y = coin::value(&lp.coin_y_reserve);
                let root_k = AnimeSwapPoolV1Library::sqrt(reserve_x, reserve_y);
                let root_k_last = AnimeSwapPoolV1Library::sqrt_128(k_last);
                let total_supply = AnimeSwapPoolV1Library::get_lpcoin_total_supply<CoinType1, CoinType2>();
                if (root_k > root_k_last) {
                    let numerator = u256::mul(u256::from_u128(total_supply), u256::from_u64(root_k - root_k_last));
                    let denominator = u256::add(u256::mul(u256::from_u64(root_k), u256::from_u64((admin_data.dao_fee as u64))), u256::from_u64(root_k_last));
                    let liquidity = u256::as_u64(u256::div(numerator, denominator));
                    if (liquidity > 0) {
                        mint_coin<CoinType1, CoinType2>(&account::create_signer_with_capability(&admin_data.signer_cap), liquidity, &lp.lp_mint_cap);
                    };
                }
            }
        } else if (k_last != 0) {
            lp.k_last = 0;
        };
        fee_on
    }

    // mint coin with MintCapability
    fun mint_coin<CoinType1, CoinType2>(
        account: &signer,
        amount: u64,
        mint_cap: &MintCapability<LPCoin<CoinType1, CoinType2>>
    ) {
        let acc_addr = signer::address_of(account);
        if (!coin::is_account_registered<LPCoin<CoinType1, CoinType2>>(acc_addr)) {
            coin::register<LPCoin<CoinType1, CoinType2>>(account);
        };
        let coins = coin::mint<LPCoin<CoinType1, CoinType2>>(amount, mint_cap);
        coin::deposit(acc_addr, coins);
    }

    fun mint<CoinType1, CoinType2>(
        account: &signer,
        coin_x: Coin<CoinType1>,
        coin_y: Coin<CoinType2>
    ): Coin<LPCoin<CoinType1, CoinType2>> acquires LiquidityPool, AdminData, Events {
        assert_lp_unlocked<CoinType1, CoinType2>();
        let amount_x = coin::value(&coin_x);
        let amount_y = coin::value(&coin_y);
        // get reserve
        let lp = borrow_global_mut<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_x, reserve_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        let admin_data = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        // feeOn
        let fee_on = mint_fee_interval<CoinType1, CoinType2>(lp, admin_data);
        coin::merge(&mut lp.coin_x_reserve, coin_x);
        coin::merge(&mut lp.coin_y_reserve, coin_y);
        let (balance_x, balance_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));

        let total_supply = AnimeSwapPoolV1Library::get_lpcoin_total_supply<CoinType1, CoinType2>();
        let liquidity;
        if (total_supply == 0) {
            liquidity = AnimeSwapPoolV1Library::sqrt(amount_x, amount_y) - MINIMUM_LIQUIDITY;
            mint_coin<CoinType1, CoinType2>(&get_resource_account_signer(), MINIMUM_LIQUIDITY, &lp.lp_mint_cap);
        } else {
            let amount_1 = u256::as_u64(u256::div(u256::mul( u256::from_u64(amount_x), u256::from_u128(total_supply)), u256::from_u64(reserve_x)));
            let amount_2 = u256::as_u64(u256::div(u256::mul( u256::from_u64(amount_y), u256::from_u128(total_supply)), u256::from_u64(reserve_y)));
            liquidity = AnimeSwapPoolV1Library::min(amount_1, amount_2);
        };
        assert!(liquidity > 0, INSUFFICIENT_LIQUIDITY_MINT);
        let coins = coin::mint<LPCoin<CoinType1, CoinType2>>(liquidity, &lp.lp_mint_cap);
        // update interval
        update_internal(lp, balance_x, balance_y, reserve_x, reserve_y);
        // feeOn
        if (fee_on) lp.k_last = (balance_x as u128) * (balance_y as u128);
        // event
        let events = borrow_global_mut<Events<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS);
        event::emit_event(&mut events.mint_event, MintEvent {
            sender_address: signer::address_of(account),
            amount_x,
            amount_y,
        });
        coins
    }

    fun burn<CoinType1, CoinType2>(
        account: &signer,
        liquidity: Coin<LPCoin<CoinType1, CoinType2>>
    ): (Coin<CoinType1>, Coin<CoinType2>) acquires LiquidityPool, AdminData, Events {
        assert_lp_unlocked<CoinType1, CoinType2>();
        let liquidity_amount = coin::value(&liquidity);
        // get lp
        let lp = borrow_global_mut<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let (reserve_x, reserve_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        let admin_data = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        // feeOn
        let fee_on = mint_fee_interval<CoinType1, CoinType2>(lp, admin_data);

        let total_supply = AnimeSwapPoolV1Library::get_lpcoin_total_supply<CoinType1, CoinType2>();
        let amount_x = ((liquidity_amount as u128) * (reserve_x as u128) / total_supply as u64);
        let amount_y = ((liquidity_amount as u128) * (reserve_y as u128) / total_supply as u64);
        let x_coin_to_return = coin::extract(&mut lp.coin_x_reserve, amount_x);
        let y_coin_to_return = coin::extract(&mut lp.coin_y_reserve, amount_y);
        assert!(amount_x > 0 && amount_y > 0, INSUFFICIENT_LIQUIDITY_BURN);
        let (balance_x, balance_y) = (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve));
        coin::burn<LPCoin<CoinType1, CoinType2>>(liquidity, &lp.lp_burn_cap);

        // update interval
        update_internal(lp, balance_x, balance_y, reserve_x, reserve_y);
        // feeOn
        if (fee_on) lp.k_last = (balance_x as u128) * (balance_y as u128);
        // event
        let events = borrow_global_mut<Events<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS);
        event::emit_event(&mut events.burn_event, BurnEvent {
            sender_address: signer::address_of(account),
            amount_x,
            amount_y,
        });
        (x_coin_to_return, y_coin_to_return)
    }

    /**
     *  public functions for other contract
     */

    // price oracle for other contract
    public fun get_last_price_cumulative<CoinType1, CoinType2>(): (u128, u128) acquires LiquidityPool {
        if (!AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            return get_last_price_cumulative<CoinType2, CoinType1>()
        };
        let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        (lp.last_price_x_cumulative, lp.last_price_y_cumulative)
    }

    public fun get_reserves<CoinType1, CoinType2>(): (u64, u64, u64) acquires LiquidityPool {
        if (!AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            return get_reserves<CoinType2, CoinType1>()
        };
        let lp = borrow_global<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        (coin::value(&lp.coin_x_reserve), coin::value(&lp.coin_y_reserve), lp.last_block_timestamp)
    }

    public fun check_pair_exist<CoinType1, CoinType2>(): bool {
        if (!AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>()) {
            return check_pair_exist<CoinType2, CoinType1>()
        };
        exists<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS)
    }

    public fun get_admin_data(): (u64, u8, bool, bool) acquires AdminData {
        let admin_data = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS);
        (admin_data.swap_fee, admin_data.dao_fee, admin_data.dao_fee_on, admin_data.is_pause_flash)
    }

    public fun get_pair_list(): vector<PairMeta> acquires PairInfo {
        let pair_info = borrow_global<PairInfo>(RESOURCE_ACCOUNT_ADDRESS);
        pair_info.pair_list
    }

    /**
     *  flash swap
     *  assert CoinType1 < CoinType2
     */
    public fun flash_swap<CoinType1, CoinType2>(
        loan_coin_1: u64,
        loan_coin_2: u64
    ): (Coin<CoinType1>, Coin<CoinType2>, FlashSwap<CoinType1, CoinType2>) acquires LiquidityPool, AdminData {
        // assert check
        assert!(AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>() == true, PAIR_ORDER_ERROR);
        when_not_paused();
        assert!(loan_coin_1 > 0 || loan_coin_2 > 0, LOAN_ERROR);
        assert_lp_unlocked<CoinType1, CoinType2>();

        let lp = borrow_global_mut<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp.coin_x_reserve) >= loan_coin_1 && coin::value(&lp.coin_y_reserve) >= loan_coin_2, INSUFFICIENT_AMOUNT);
        lp.locked = true;

        let loaned_coin_1 = coin::extract(&mut lp.coin_x_reserve, loan_coin_1);
        let loaned_coin_2 = coin::extract(&mut lp.coin_y_reserve, loan_coin_2);

        // Return loaned amount.
        (loaned_coin_1, loaned_coin_2, FlashSwap<CoinType1, CoinType2> {loan_coin_1, loan_coin_2})
    }

    public fun pay_flash_swap<CoinType1, CoinType2>(
        account: &signer,
        x_in: Coin<CoinType1>,
        y_in: Coin<CoinType2>,
        flash_swap: FlashSwap<CoinType1, CoinType2>
    ) acquires LiquidityPool, AdminData, Events {
        // assert check
        assert!(AnimeSwapPoolV1Library::compare<CoinType1, CoinType2>() == true, PAIR_ORDER_ERROR);
        when_not_paused();
        assert!(exists<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS), PAIR_NOT_EXIST);

        let FlashSwap { loan_coin_1, loan_coin_2 } = flash_swap;
        let amount_x_in = coin::value(&x_in);
        let amount_y_in = coin::value(&y_in);

        assert!(amount_x_in > 0 || amount_y_in > 0, LOAN_ERROR);

        let lp = borrow_global_mut<LiquidityPool<CoinType1, CoinType2, LPCoin<CoinType1, CoinType2>>>(RESOURCE_ACCOUNT_ADDRESS);
        let reserve_x = coin::value(&lp.coin_x_reserve);
        let reserve_y = coin::value(&lp.coin_y_reserve);

        // reserve size before loan out
        reserve_x = reserve_x + loan_coin_1;
        reserve_y = reserve_y + loan_coin_2;

        coin::merge(&mut lp.coin_x_reserve, x_in);
        coin::merge(&mut lp.coin_y_reserve, y_in);

        let balance_x = coin::value(&lp.coin_x_reserve);
        let balance_y = coin::value(&lp.coin_y_reserve);

        let swap_fee = borrow_global<AdminData>(RESOURCE_ACCOUNT_ADDRESS).swap_fee;
        let balance_x_adjusted = (balance_x as u128) * 10000 - (amount_x_in as u128) * (swap_fee as u128);
        let balance_y_adjusted = (balance_y as u128) * 10000 - (amount_y_in as u128) * (swap_fee as u128);
        // use u256 to prevent overflow
        // should be: balance_x * balance_y >= reserve_x * reserve_y
        assert!(u256::compare(&u256::add(u256::mul(u256::from_u128(balance_x_adjusted), u256::from_u128(balance_y_adjusted)), u256::from_u64(1)),
            &u256::mul(u256::mul(u256::from_u64(reserve_x), u256::from_u64(reserve_y)), u256::from_u64(100000000))) == 2, K_ERROR);
        // update internal
        update_internal(lp, balance_x, balance_y, reserve_x, reserve_y);

        lp.locked = false;
        // event
        let events = borrow_global_mut<Events<CoinType1, CoinType2>>(RESOURCE_ACCOUNT_ADDRESS);
        event::emit_event(&mut events.flash_swap_event, FlashSwapEvent {
            sender_address: signer::address_of(account),
            loan_coin_1,
            loan_coin_2,
            repay_coin_1: amount_x_in,
            repay_coin_2: amount_y_in,
        });
    }

    #[test_only]
    use aptos_framework::genesis;
    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use SwapDeployer::TestCoinsV1::{Self, BTC, USDT};
    #[test_only]
    const TEST_ERROR:u64 = 10000;
    #[test_only]
    const ADD_LIQUIDITY_ERROR:u64 = 10003;
    #[test_only]
    const CONTRACTOR_BALANCE_ERROR:u64 = 10004;
    #[test_only]
    const USER_LP_BALANCE_ERROR:u64 = 10005;
    #[test_only]
    const INIT_FAUCET_COIN:u64 = 1000000000;
    #[test_only]
    const DEADLINE:u64 = 1000;

    #[test_only]
    struct Aptos has store {}
    #[test_only]
    struct Caps<phantom Aptos> has key {
        mint: MintCapability<Aptos>,
        freeze: FreezeCapability<Aptos>,
        burn: BurnCapability<Aptos>,
    }
    #[test_only]
    struct AptosB has store {}
    #[test_only]
    struct CapsB<phantom AptosB> has key {
        mint: MintCapability<AptosB>,
        freeze: FreezeCapability<AptosB>,
        burn: BurnCapability<AptosB>,
    }

    #[test_only]
    fun init_module_test(resource_account: &signer) acquires AdminData, PairInfo {
        move_to(resource_account, AdminData {
            signer_cap: account::create_test_signer_cap(signer::address_of(resource_account)),
            dao_fee_to: DEPLOYER_ADDRESS,
            admin_address: DEPLOYER_ADDRESS,
            dao_fee: 5,         // 1/6 to dao fee
            swap_fee: 30,       // 0.3%
            dao_fee_on: false,  // default false
            is_pause_flash: false,    // default false
        });
        move_to(resource_account, PairInfo{
            pair_list: vector::empty(),
        });
        // create default 3 pairs
        create_pair<BTC, USDT>(resource_account);
        create_pair<BTC, std::aptos_coin::AptosCoin>(resource_account);
        create_pair<USDT, std::aptos_coin::AptosCoin>(resource_account);
    }

    #[test_only]
    fun test_init(creator: &signer, resource_account: &signer, someone_else: &signer) acquires AdminData, PairInfo {
        genesis::setup();
        create_account_for_test(signer::address_of(creator));
        create_account_for_test(signer::address_of(resource_account));
        create_account_for_test(signer::address_of(someone_else));
        // init creator
        TestCoinsV1::initialize(creator);
        init_module_test(resource_account);
        // init someone_else
        TestCoinsV1::register_coins_all(someone_else);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(someone_else), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(someone_else), INIT_FAUCET_COIN);

        // init timestamp
        timestamp::update_global_time_for_test(100);

        {
            // init self-defined Aptos
            let (apt_b, apt_f, apt_m) = coin::initialize<Aptos>(creator, utf8(b"Aptos"), utf8(b"APT"), 6, true);
            coin::register<Aptos>(resource_account);
            coin::register<Aptos>(someone_else);
            let coins = coin::mint<Aptos>(INIT_FAUCET_COIN, &apt_m);
            coin::deposit(signer::address_of(someone_else), coins);
            move_to(resource_account, Caps<Aptos> { mint: apt_m, freeze: apt_f, burn: apt_b });
        };

        {
            // init self-defined AptosB
            let (apt_b, apt_f, apt_m) = coin::initialize<AptosB>(creator, utf8(b"AptosB"), utf8(b"APTB"), 6, true);
            coin::register<AptosB>(resource_account);
            coin::register<AptosB>(someone_else);
            let coins = coin::mint<AptosB>(INIT_FAUCET_COIN, &apt_m);
            coin::deposit(signer::address_of(someone_else), coins);
            move_to(resource_account, CapsB<AptosB> { mint: apt_m, freeze: apt_f, burn: apt_b });
        };

        create_pair<BTC, Aptos>(resource_account);
        create_pair<USDT, Aptos>(resource_account);
        create_pair<Aptos, AptosB>(resource_account);
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_add_remove_liquidity_basic_1_1(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000, USER_LP_BALANCE_ERROR);
        };

        // should takes 100/100 coin and gives 100 LPCoin
        add_liquidity_entry<BTC, USDT>(someone_else, 1000, 100, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10100, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10100, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9100, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10100, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10100, USER_LP_BALANCE_ERROR);
        };

        // should takes 9000 LPCoin and gives 9000/9000 coin
        remove_liquidity_entry<BTC, USDT>(someone_else, 9000, 9000, 9000, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 1100, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 1100, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 100, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 1100, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 1100, USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_add_remove_liquidity_basic_1_100(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 1000/100000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(1000*100000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 1000, 100000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 1000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 100000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
        };

        // should takes 10/1000 coin and gives 100 LPCoin
        add_liquidity_entry<BTC, USDT>(someone_else, 1000, 1000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 1010, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 101000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9100, USER_LP_BALANCE_ERROR);
        };

        // should takes 9000 LPCoin and gives 900/90000 coin
        remove_liquidity_entry<BTC, USDT>(someone_else, 9000, 900, 90000, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 110, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 11000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 100, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 110, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 11000, USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_add_remove_liquidity_basic_1_2(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 1000/2000 coin and gives 414 LPCoin (AnimeSwapPoolV1Library::sqrt(1000*2000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 1000, 2000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 1000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 2000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 414, USER_LP_BALANCE_ERROR);
        };

        // should takes 1000/2000 coin and gives 1414 LPCoin
        add_liquidity_entry<BTC, USDT>(someone_else, 2000, 2000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 2000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 4000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 1828, USER_LP_BALANCE_ERROR);
        };

        // should takes 1828 LPCoin and gives 1828/2828*2000=1292|1828/2828*4000=2585 coin
        remove_liquidity_entry<BTC, USDT>(someone_else, 1828, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 2000-1292, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 4000-2585, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 0, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - (2000-1292), USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - (4000-2585), USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_swap_basic_1(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000, USER_LP_BALANCE_ERROR);
        };

        swap_exact_coins_for_coins_entry<BTC, USDT>(someone_else, 1000, 1, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 11000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9094, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 - 1000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 + 906, USER_LP_BALANCE_ERROR);
        };

        swap_exact_coins_for_coins_entry<USDT, BTC>(someone_else, 1000, 1, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 9914, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10094, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 - 1000 + 1086, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 + 906 - 1000, USER_LP_BALANCE_ERROR);
        };

        // should takes 1000 LPCoin and gives 1000/10000*9914=991|1000/10000*10094=1009 coin
        remove_liquidity_entry<BTC, USDT>(someone_else, 1000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 9914 - 991, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10094 - 1009, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 8000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 - 1000 + 1086 + 991, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 + 906 - 1000 + 1009, USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_swap_basic_2(creator: &signer, resource_account: &signer, someone_else: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000, USER_LP_BALANCE_ERROR);
        };

        swap_coins_for_exact_coins_entry<BTC, USDT>(someone_else, 1000, 100000, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 11115, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 - 1115, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 + 1000, USER_LP_BALANCE_ERROR);
        };

        swap_coins_for_exact_coins_entry<USDT, BTC>(someone_else, 1000, 100000, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10115, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9893, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 - 1115 + 1000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000 + 1000 - 893, USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_swap_multiple_pair_1_1(creator: &signer, resource_account: &signer, someone_else: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);
        add_liquidity_entry<USDT, Aptos>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);

        swap_exact_coins_for_coins_2_pair_entry<BTC, USDT, Aptos>(someone_else, 10000, 1, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_2 = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10010000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9990040, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_x_reserve) == 10009960, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_y_reserve) == 9990080, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 - 10000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 20000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<Aptos>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 + 9920, USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_swap_multiple_pair_1_2(creator: &signer, resource_account: &signer, someone_else: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);
        add_liquidity_entry<USDT, Aptos>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);
        add_liquidity_entry<Aptos, AptosB>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);

        swap_exact_coins_for_coins_3_pair_entry<BTC, USDT, Aptos, AptosB>(someone_else, 10000, 1, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_2 = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_3 = borrow_global<LiquidityPool<Aptos, AptosB, LPCoin<Aptos, AptosB>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10010000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9990040, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_x_reserve) == 10009960, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_y_reserve) == 9990080, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_x_reserve) == 10009920, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_y_reserve) == 9990120, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 - 10000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 20000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<Aptos>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 20000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<AptosB>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 + 9880, USER_LP_BALANCE_ERROR);
        };
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_swap_multiple_pair_2_1(creator: &signer, resource_account: &signer, someone_else: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        // std::aptos_coin::mint(signer::address_of(someone_else), 10000000);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);
        add_liquidity_entry<USDT, Aptos>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);

        swap_coins_for_exact_coins_2_pair_entry<BTC, USDT, Aptos>(someone_else, 10000, 1000000, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_2 = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10010082, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9989959, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_x_reserve) == 10010041, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_y_reserve) == 9990000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 - 10082, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 20000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<Aptos>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 + 10000, USER_LP_BALANCE_ERROR);
        }
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_swap_multiple_pair_2_2(creator: &signer, resource_account: &signer, someone_else: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);
        add_liquidity_entry<USDT, Aptos>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);
        add_liquidity_entry<Aptos, AptosB>(someone_else, 10000000, 10000000, 1, 1, DEADLINE);

        swap_coins_for_exact_coins_3_pair_entry<BTC, USDT, Aptos, AptosB>(someone_else, 10000, 1000000, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_2 = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_3 = borrow_global<LiquidityPool<Aptos, AptosB, LPCoin<Aptos, AptosB>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10010123, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 9989918, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_x_reserve) == 10010082, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_y_reserve) == 9989959, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_x_reserve) == 10010041, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_y_reserve) == 9990000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 - 10123, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 20000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<Aptos>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 20000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<AptosB>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 10000000 + 10000, USER_LP_BALANCE_ERROR);
        };
    }

    // test remove more than expected
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    #[expected_failure(abort_code = 65542)]
    public entry fun test_add_remove_liquidity_error_1(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);

        // only have 9000 LP, should fail
        remove_liquidity_entry<BTC, USDT>(someone_else, 9200, 9200, 9200, DEADLINE);
    }

    // test remove more than expected
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    #[expected_failure(abort_code = 109)]
    public entry fun test_add_remove_liquidity_error_2(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);

        // should takes 9000 LPCoin and gives 900/90000 coin, but expect more
        remove_liquidity_entry<BTC, USDT>(someone_else, 9000, 1000, 100000, DEADLINE);
    }

    // test beyond deadline
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    #[expected_failure(abort_code = 101)]
    public entry fun test_add_remove_liquidity_error_3(creator: &signer, resource_account: &signer, someone_else: &signer) 
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // should take no effect when called only
        let (amount_x, amount_y) = add_liquidity_internal<BTC, USDT>(100, 1000, 1, 1);
        assert!(amount_x == 100, ADD_LIQUIDITY_ERROR);
        assert!(amount_y == 1000, ADD_LIQUIDITY_ERROR);

        timestamp::update_global_time_for_test((DEADLINE + 1) * 1000000);

        // beyong deadline
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11)]
    public entry fun test_add_multiple_liquidity(creator: &signer, resource_account: &signer, someone_else: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);

        // add 3 LPs
        add_liquidity_entry<USDT, Aptos>(someone_else, 1000000, 10000, 1, 1, DEADLINE);
        add_liquidity_entry<BTC, Aptos>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 1000000, 1, 1, DEADLINE);

        {
            let lp = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_2 = borrow_global<LiquidityPool<BTC, Aptos, LPCoin<BTC, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_3 = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 1000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_y_reserve) == 1000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<USDT, Aptos>>(signer::address_of(someone_else)) == 99000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, Aptos>>(signer::address_of(someone_else)) == 9000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 99000, USER_LP_BALANCE_ERROR);
        };

        let lp_1 = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp_1.coin_x_reserve) == 1000000, CONTRACTOR_BALANCE_ERROR);
        assert!(coin::value(&lp_1.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
        let lp_2 = borrow_global<LiquidityPool<BTC, Aptos, LPCoin<BTC, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp_2.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
        assert!(coin::value(&lp_2.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
        let lp_3 = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp_3.coin_x_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
        assert!(coin::value(&lp_3.coin_y_reserve) == 1000000, CONTRACTOR_BALANCE_ERROR);

        // add 3 LPs
        add_liquidity_entry<USDT, Aptos>(someone_else, 1000000, 10000, 1, 1, DEADLINE);
        add_liquidity_entry<BTC, Aptos>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 1000000, 1, 1, DEADLINE);

        {
            let lp = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_2 = borrow_global<LiquidityPool<BTC, Aptos, LPCoin<BTC, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
            let lp_3 = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 2000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_x_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_2.coin_y_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_x_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp_3.coin_y_reserve) == 2000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<USDT, Aptos>>(signer::address_of(someone_else)) == 199000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, Aptos>>(signer::address_of(someone_else)) == 19000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 199000, USER_LP_BALANCE_ERROR);
        };

        let lp_1 = borrow_global<LiquidityPool<USDT, Aptos, LPCoin<USDT, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp_1.coin_x_reserve) == 2000000, CONTRACTOR_BALANCE_ERROR);
        assert!(coin::value(&lp_1.coin_y_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
        let lp_2 = borrow_global<LiquidityPool<BTC, Aptos, LPCoin<BTC, Aptos>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp_2.coin_x_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
        assert!(coin::value(&lp_2.coin_y_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
        let lp_3 = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
        assert!(coin::value(&lp_3.coin_x_reserve) == 20000, CONTRACTOR_BALANCE_ERROR);
        assert!(coin::value(&lp_3.coin_y_reserve) == 2000000, CONTRACTOR_BALANCE_ERROR);
    }

    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, dao_fee_to = @0x99)]
    public entry fun test_dao_fee(creator: &signer, resource_account: &signer, someone_else: &signer, dao_fee_to: &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(dao_fee_to));
        set_dao_fee(creator, 1);
        set_dao_fee_to(creator, signer::address_of(dao_fee_to));

        // should takes 10000/10000 coin and gives 9000 LPCoin (AnimeSwapPoolV1Library::sqrt(10000*10000)-1000)
        add_liquidity_entry<BTC, USDT>(someone_else, 100000000, 100000000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 100000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 100000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 100000000 - 1000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 100000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 100000000, USER_LP_BALANCE_ERROR);
        };

        swap_exact_coins_for_coins_entry<BTC, USDT>(someone_else, 10000000, 1, signer::address_of(someone_else), DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 110000000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 90933892, CONTRACTOR_BALANCE_ERROR);   // 1e8-floor(1e8-1e8**2/(1e8+0.0997e8))
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 100000000 - 1000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 100000000 - 10000000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 100000000 + 9066108, USER_LP_BALANCE_ERROR);
        };

        // admin_data should have some dao LPCoins
        remove_liquidity_entry<BTC, USDT>(someone_else, 1000000, 1, 1, DEADLINE);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 108900076, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 90024616, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(someone_else)) == 98999000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<BTC>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 108900076, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<USDT>(signer::address_of(someone_else)) == INIT_FAUCET_COIN - 90024616, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(RESOURCE_ACCOUNT_ADDRESS) == 1000 + 6819, USER_LP_BALANCE_ERROR);
        };

        // dao withdraw fee
        withdraw_dao_fee<BTC, USDT>(dao_fee_to);
        {
            assert!(coin::balance<LPCoin<BTC, USDT>>(RESOURCE_ACCOUNT_ADDRESS) == 1000, USER_LP_BALANCE_ERROR);
            assert!(coin::balance<LPCoin<BTC, USDT>>(signer::address_of(dao_fee_to)) == 6819, USER_LP_BALANCE_ERROR);
        };
    }

    // test to address not registered
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    #[expected_failure(abort_code = 114)]
    public entry fun test_swap_to_address_not_register(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));

        add_liquidity_entry<BTC, USDT>(someone_else, 100000000, 100000000, 1, 1, DEADLINE);
        swap_exact_coins_for_coins_entry<BTC, USDT>(someone_else, 10000000, 1, signer::address_of(another_one), DEADLINE);
    }

    // test resource account equal
    #[test(deployer = @SwapDeployer)]
    public entry fun test_resource_account(deployer: &signer) {
        genesis::setup();
        create_account_for_test(signer::address_of(deployer));
        let addr = account::create_resource_address(&signer::address_of(deployer), x"30");
        assert!(addr == @ResourceAccountDeployer, TEST_ERROR);
    }

    // borrow on boin and repay the other coin, greater than swap fee
    // borrow BTC and repay USDT
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    public entry fun test_flash_swap_a(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        // if swap 1000 coin, should be 10000-1000/100000+11145 remain
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 100000, 1, 1, DEADLINE);
        let amount_out = 1000;
        let amount_in = get_amounts_in_1_pair<USDT, BTC>(amount_out);
        assert!(amount_in == 11145, TEST_ERROR);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(amount_out, 0);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin = coin::withdraw<USDT>(another_one, amount_in);
        pay_flash_swap<BTC, USDT>(another_one, coin::zero<BTC>(), repay_coin, flash_swap);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10000 - 1000, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 100000 + 11145, CONTRACTOR_BALANCE_ERROR);
        };
    }

    // borrow on boin and repay the other coin, greater than swap fee
    // borrow USDT and repay BTC
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    public entry fun test_flash_swap_b(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        // if swap 1000 coin, should be 10000+102/100000-1000 remain
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 100000, 1, 1, DEADLINE);
        let amount_out = 1000;
        let amount_in = get_amounts_in_1_pair<BTC, USDT>(amount_out);
        assert!(amount_in == 102, TEST_ERROR);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(0, amount_out);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin = coin::withdraw<BTC>(another_one, amount_in);
        pay_flash_swap<BTC, USDT>(another_one, repay_coin, coin::zero<USDT>(), flash_swap);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10000 + 102, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 100000 - 1000, CONTRACTOR_BALANCE_ERROR);
        };
    }

    // K_ERROR, not enough coin repay
    // borrow on boin and repay the other coin but less equal than swap fee
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    #[expected_failure(abort_code = 112)]
    public entry fun test_flash_swap_error(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        // if swap 1000 coin, should be 9000/11115 remain
        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(1000, 0);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin = coin::withdraw<USDT>(another_one, 1114);
        pay_flash_swap<BTC, USDT>(another_one, coin::zero<BTC>(), repay_coin, flash_swap);
    }

    // borrow both boins and repay greater than swap fee
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    public entry fun test_flash_swap_2(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(1000, 1000);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin_1 = coin::withdraw<BTC>(another_one, 1004);
        let repay_coin_2 = coin::withdraw<USDT>(another_one, 1003);
        pay_flash_swap<BTC, USDT>(another_one, repay_coin_1, repay_coin_2, flash_swap);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10004, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10003, CONTRACTOR_BALANCE_ERROR);
        };
    }

    // K_ERROR, not enough coin repay
    // borrow both boins and repay less equal than swap fee
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    #[expected_failure(abort_code = 112)]
    public entry fun test_flash_swap_error_2(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(1000, 1000);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin_1 = coin::withdraw<BTC>(another_one, 1003);
        let repay_coin_2 = coin::withdraw<USDT>(another_one, 1003);
        pay_flash_swap<BTC, USDT>(another_one, repay_coin_1, repay_coin_2, flash_swap);
    }

    // borrow one boin and repay the same coin, greater than swap fee
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    public entry fun test_flash_swap_3(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(1000, 0);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin_1 = coin::withdraw<BTC>(another_one, 1004);
        pay_flash_swap<BTC, USDT>(another_one, repay_coin_1, coin::zero<USDT>(), flash_swap);
        {
            let lp = borrow_global<LiquidityPool<BTC, USDT, LPCoin<BTC, USDT>>>(RESOURCE_ACCOUNT_ADDRESS);
            assert!(coin::value(&lp.coin_x_reserve) == 10004, CONTRACTOR_BALANCE_ERROR);
            assert!(coin::value(&lp.coin_y_reserve) == 10000, CONTRACTOR_BALANCE_ERROR);
        };
    }

    // K_ERROR, not enough coin repay
    // borrow one boin and repay the same coin, but less equal than swap fee
    #[test(creator = @SwapDeployer, resource_account = @ResourceAccountDeployer, someone_else = @0x11, another_one = @0x12)]
    #[expected_failure(abort_code = 112)]
    public entry fun test_flash_swap_error_3(creator: &signer, resource_account: &signer, someone_else: &signer, another_one : &signer)
            acquires LiquidityPool, AdminData, PairInfo, Events {
        // init
        test_init(creator, resource_account, someone_else);
        create_account_for_test(signer::address_of(another_one));
        TestCoinsV1::register_coins_all(another_one);
        TestCoinsV1::mint_coin<BTC>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);
        TestCoinsV1::mint_coin<USDT>(creator, signer::address_of(another_one), INIT_FAUCET_COIN);

        add_liquidity_entry<BTC, USDT>(someone_else, 10000, 10000, 1, 1, DEADLINE);
        let (coin_out_1, coin_out_2, flash_swap) = flash_swap<BTC, USDT>(1000, 0);
        coin::deposit<BTC>(signer::address_of(another_one), coin_out_1);
        coin::deposit<USDT>(signer::address_of(another_one), coin_out_2);
        let repay_coin_1 = coin::withdraw<BTC>(another_one, 1003);
        pay_flash_swap<BTC, USDT>(another_one, repay_coin_1, coin::zero<USDT>(), flash_swap);
    }
}