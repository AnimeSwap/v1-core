#!/bin/sh

# deployer address
SwapDeployer = "0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c"
ResourceAccountDeployer = "0xe73ee18380b91e37906a728540d2c8ac7848231a26b99ee5631351b3543d7cf2"
# SwapDeployer is your account, you must have its private key
# ResourceAccountDeployer is derivatived by SwapDeployer, you can refer to swap::test_resource_account to get the exact address

# publish modules
aptos move publish --package-dir PATH_TO_REPO/uq64x64/
aptos move publish --package-dir PATH_TO_REPO/u256/
aptos move publish --package-dir PATH_TO_REPO/TestCoin/
aptos move publish --package-dir PATH_TO_REPO/Faucet/
aptos move publish --package-dir PATH_TO_REPO/LPResourceAccount/
# create resource account & publish LPCoin
# use this command to compile LPCoin
aptos move compile --package-dir PATH_TO_REPO/LPCoin/ --save-metadata
# get the first arg
hexdump -ve '1/1 "%02x"' PATH_TO_REPO/LPCoin/build/LPCoin/package-metadata.bcs
# get the second arg
hexdump -ve '1/1 "%02x"' PATH_TO_REPO/LPCoin/build/LPCoin/bytecode_modules/LPCoinV1.mv
# This command is to publish LPCoin contract, using ResourceAccountDeployer address. Note: replace two args with the above two hex
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::LPResourceAccount::initialize_lp_account \
--args hex:064c50436f696e0100000000000000004042323534463735453946414635413031364544383137433944444544453530304239443544323339394644394146383732344643394430313137443039353031b7021f8b08000000000002ff8d51b94ec34010edfd159669c17bf95823514444541488364ab13b3b4e8c8fb576ed4082f877bc21080a0aba39de7bf36666332a68d50eb7d1a07a8cefe2e4f1e9de3643121dd0f9c60ea144539ab2248a3606471c0c0ed0a0df4657ab71b2fec12dc457ebda05f91eef9a2930f6d334fa5b4296743feb146c4f5400df744afb4b08d661ba0092ebd8cfda342e10bf5abd3d20a9bf852ff89f7c61383c9c9d716026a31a046735cb852c0c4aa999d2a62a38a81a90d35c9749fc11fde1b6b3a0baa043f6b647723a9ddaf648d6e8dbc98e6474f60561fa6597fcc75e98156d94310ebd0f777a466f6707b802b0f330ad71ecec11cfebd2372c05229342525d311465450b55729967d470900a4a99492e98e285ae2ac4bc104ce44c8b3c13a6849a2f6ff904fcadfb82c401000001084c50436f696e56316b1f8b08000000000002ff5dc8b10a80201080e1bda7b80768b15122881a1b22a23deca0403d516f10f1dd2bdafab7ff3374b0465830107b85bd52c4368ee83425f4524ef34097dd04e40a9e42f4ac227cdaba73b7910cbcb32687a2863f351de452951b1e36ff316700000000000300000000000000000000000000000000000000000000000000000000000000010e4170746f734672616d65776f726b00000000000000000000000000000000000000000000000000000000000000010b4170746f735374646c696200000000000000000000000000000000000000000000000000000000000000010a4d6f76655374646c696200 \
hex:a11ceb0b0500000005010002020208070a1c0826200a460500000001000200010001084c50436f696e5631064c50436f696e0b64756d6d795f6669656c64e73ee18380b91e37906a728540d2c8ac7848231a26b99ee5631351b3543d7cf2000201020100
aptos move publish --package-dir PATH_TO_REPO/SwapLibrary/
aptos move publish --package-dir PATH_TO_REPO/Swap/

# admin steps
# TestCoinsV1
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::initialize
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::mint_coin \
--args address:0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c u64:20000000000000000 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::USDT
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::mint_coin \
--args address:0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c u64:2000000000000 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC
# FaucetV1
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::FaucetV1::create_faucet \
--args u64:10000000000000000 u64:100000000 u64:3600 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::USDT
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::FaucetV1::create_faucet \
--args u64:1000000000000 u64:1000000 u64:3600 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC
# AnimeSwapPool
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::add_liquidity_entry \
--args u64:10000000000 u64:100000000 u64:1 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::USDT 0x1::aptos_coin::AptosCoin
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::add_liquidity_entry \
--args u64:10000000 u64:100000000 u64:1 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x1::aptos_coin::AptosCoin
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::add_liquidity_entry \
--args u64:100000000 u64:100000000000 u64:1 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::USDT

# user
# fund
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::FaucetV1::request \
--args address:0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::USDT
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::FaucetV1::request \
--args address:0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC
# swap (type args shows the swap direction, in this example, swap BTC to APT)
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::swap_exact_coins_for_coins_entry \
--args u64:100 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x1::aptos_coin::AptosCoin
# swap
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::swap_coins_for_exact_coins_entry \
--args u64:100 u64:1000000000 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x1::aptos_coin::AptosCoin
# multiple pair swap (this example, swap 100 BTC->APT->USDT)
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::swap_exact_coins_for_coins_2_pair_entry \
--args u64:100 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x1::aptos_coin::AptosCoin 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::USDT
# add lp (if pair not exist, will auto create lp first)
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::add_liquidity_entry \
--args u64:1000 u64:10000 u64:1 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x1::aptos_coin::AptosCoin
aptos move run --function-id 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::AnimeSwapPoolV1::remove_liquidity_entry \
--args u64:1000 u64:1 u64:1 \
--type-args 0x16fe2df00ea7dde4a63409201f7f4e536bde7bb7335526a35d05111e68aa322c::TestCoinsV1::BTC 0x1::aptos_coin::AptosCoin
