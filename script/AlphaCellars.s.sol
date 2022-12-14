// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import { Registry } from "src/Registry.sol";
import { Cellar } from "src/base/Cellar.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Run
 *      `source .env && forge script script/AlphaCellars.s.sol:AlphaCellarsScript --rpc-url $MAINNET_RPC_URL  --private-key $PRIVATE_KEY --broadcast —optimize —optimizer-runs 200 --with-gas-price 20000000000 --verify --etherscan-api-key $ETHERSCAN_KEY`
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */

contract AlphaCellarsScript is Script {
    address private sommMultiSig = 0x7340D1FeCD4B64A4ac34f826B21c945d44d7407F;
    address private strategist = 0xA9962a5BfBea6918E958DeE0647E99fD7863b95A;

    ERC20 private USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 private WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 private WBTC = ERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    Registry private registry = Registry(0xDffa1443a72Fd3f4e935b93d0C3BFf8FE80cE083);

    function run() external {
        vm.startBroadcast();

        createMultiAssetCellars();

        vm.stopBroadcast();
    }

    function createMultiAssetCellars() internal {
        // Setup Cellar:
        address[] memory positions = new address[](2);
        positions[0] = address(USDC);
        positions[1] = address(WBTC);

        Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](2);
        positionTypes[0] = Cellar.PositionType.ERC20;
        positionTypes[1] = Cellar.PositionType.ERC20;

        new Cellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.PROPORTIONAL,
            "Alpha BTC",
            "AlphaBTC",
            strategist
        );

        positions[0] = address(USDC);
        positions[1] = address(WETH);

        new Cellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.PROPORTIONAL,
            "Alpha ETH",
            "AlphaETH",
            strategist
        );
    }
}
