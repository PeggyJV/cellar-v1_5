// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { MockCellar, Cellar, ERC4626, ERC20 } from "src/mocks/MockCellar.sol";
import { ReentrancyERC4626 } from "src/mocks/ReentrancyERC4626.sol";
import { LockedERC4626 } from "src/mocks/LockedERC4626.sol";
import { Registry, PriceRouter, SwapRouter, IGravity } from "src/base/Cellar.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniswapV2Router, IUniswapV3Router } from "src/modules/swap-router/SwapRouter.sol";
import { MockExchange } from "src/mocks/MockExchange.sol";
import { MockPriceRouter } from "src/mocks/MockPriceRouter.sol";
import { MockERC4626 } from "src/mocks/MockERC4626.sol";
import { MockGravity } from "src/mocks/MockGravity.sol";
import { MockERC20 } from "src/mocks/MockERC20.sol";

import { Test, stdStorage, StdStorage, stdError } from "@forge-std/Test.sol";
import { Math } from "src/utils/Math.sol";

contract CellarTest is Test {
    using SafeERC20 for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    MockCellar private cellar;
    MockGravity private gravity;

    MockExchange private exchange;
    MockPriceRouter private priceRouter;
    SwapRouter private swapRouter;

    Registry private registry;

    ERC20 private USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    MockERC4626 private usdcCLR;

    ERC20 private WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    MockERC4626 private wethCLR;

    ERC20 private WBTC = ERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    MockERC4626 private wbtcCLR;

    ERC20 private LINK = ERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);

    ERC20 private USDT = ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    address private immutable strategist = vm.addr(0xBEEF);

    address private immutable cosmos = vm.addr(0xCAAA);

    function setUp() external {
        usdcCLR = new MockERC4626(USDC, "USDC Cellar LP Token", "USDC-CLR", 6);
        vm.label(address(usdcCLR), "usdcCLR");

        wethCLR = new MockERC4626(WETH, "WETH Cellar LP Token", "WETH-CLR", 18);
        vm.label(address(wethCLR), "wethCLR");

        wbtcCLR = new MockERC4626(WBTC, "WBTC Cellar LP Token", "WBTC-CLR", 8);
        vm.label(address(wbtcCLR), "wbtcCLR");

        // Setup Registry and modules:
        priceRouter = new MockPriceRouter();
        exchange = new MockExchange(priceRouter);
        swapRouter = new SwapRouter(IUniswapV2Router(address(exchange)), IUniswapV3Router(address(exchange)));
        gravity = new MockGravity();

        registry = new Registry(
            // Set this contract to the Gravity Bridge for testing to give the permissions usually
            // given to the Gravity Bridge to this contract.
            address(this),
            address(swapRouter),
            address(priceRouter)
        );

        // Setup exchange rates:
        // USDC Simulated Price: $1
        // WETH Simulated Price: $2000
        // WBTC Simulated Price: $30,000

        priceRouter.setExchangeRate(USDC, USDC, 1e6);
        priceRouter.setExchangeRate(WETH, WETH, 1e18);
        priceRouter.setExchangeRate(WBTC, WBTC, 1e8);

        priceRouter.setExchangeRate(USDC, WETH, 0.0005e18);
        priceRouter.setExchangeRate(WETH, USDC, 2000e6);

        priceRouter.setExchangeRate(USDC, WBTC, 0.00003333e8);
        priceRouter.setExchangeRate(WBTC, USDC, 30_000e6);

        priceRouter.setExchangeRate(WETH, WBTC, 0.06666666e8);
        priceRouter.setExchangeRate(WBTC, WETH, 15e18);

        priceRouter.supportAsset(USDC);
        priceRouter.supportAsset(WETH);
        priceRouter.supportAsset(WBTC);

        // Setup Cellar:
        address[] memory positions = new address[](5);
        positions[0] = address(USDC);
        positions[1] = address(usdcCLR);
        positions[2] = address(wethCLR);
        positions[3] = address(wbtcCLR);
        positions[4] = address(WETH);

        Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](5);
        positionTypes[0] = Cellar.PositionType.ERC20;
        positionTypes[1] = Cellar.PositionType.ERC4626;
        positionTypes[2] = Cellar.PositionType.ERC4626;
        positionTypes[3] = Cellar.PositionType.ERC4626;
        positionTypes[4] = Cellar.PositionType.ERC20;

        cellar = new MockCellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.ORDERLY,
            "Multiposition Cellar LP Token",
            "multiposition-CLR",
            strategist
        );
        vm.label(address(cellar), "cellar");
        vm.label(strategist, "strategist");

        // Mint enough liquidity to swap router for swaps.
        deal(address(USDC), address(exchange), type(uint224).max);
        deal(address(WETH), address(exchange), type(uint224).max);
        deal(address(WBTC), address(exchange), type(uint224).max);

        // Approve cellar to spend all assets.
        USDC.approve(address(cellar), type(uint256).max);
        WETH.approve(address(cellar), type(uint256).max);
        WBTC.approve(address(cellar), type(uint256).max);

        // Manipulate  test contracts storage so that minimum shareLockPeriod is zero blocks.
        stdstore.target(address(cellar)).sig(cellar.shareLockPeriod.selector).checked_write(uint256(0));
    }

    // ========================================= INITIALIZATION TEST =========================================

    function testInitialization() external {
        assertEq(address(cellar.registry()), address(registry), "Should initialize registry to test registry.");

        address[] memory expectedPositions = new address[](5);
        expectedPositions[0] = address(USDC);
        expectedPositions[1] = address(usdcCLR);
        expectedPositions[2] = address(wethCLR);
        expectedPositions[3] = address(wbtcCLR);
        expectedPositions[4] = address(WETH);

        Cellar.PositionType[] memory expectedPositionTypes = new Cellar.PositionType[](5);
        expectedPositionTypes[0] = Cellar.PositionType.ERC20;
        expectedPositionTypes[1] = Cellar.PositionType.ERC4626;
        expectedPositionTypes[2] = Cellar.PositionType.ERC4626;
        expectedPositionTypes[3] = Cellar.PositionType.ERC4626;
        expectedPositionTypes[4] = Cellar.PositionType.ERC20;

        address[] memory positions = cellar.getPositions();

        assertEq(cellar.getPositions().length, 5, "Position length should be 5.");

        for (uint256 i; i < positions.length; i++) {
            assertEq(positions[i], expectedPositions[i], "Position should be initialized in order.");
            assertEq(
                uint256(cellar.getPositionType(positions[i])),
                uint256(expectedPositionTypes[i]),
                "Position type should be initialized."
            );
        }

        assertEq(address(cellar.asset()), address(USDC), "Should initialize asset to be USDC.");
        assertEq(cellar.holdingPosition(), address(USDC), "Should initialize holding position to be USDC.");
        assertEq(
            uint256(cellar.withdrawType()),
            uint256(Cellar.WithdrawType.ORDERLY),
            "Should initialize withdraw type."
        );
        assertEq(
            cellar.lastAccrual(),
            uint64(block.timestamp),
            "Should initialize last accrual timestamp to current block timestamp."
        );

        (
            uint256 highWatermark,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            bytes32 feeDistributor,
            address strategistPayoutAddress
        ) = cellar.feeData();
        assertEq(highWatermark, 0, "High watermark should be zero.");
        assertEq(strategistPerformanceCut, 0.75e18, "Performance cut should be set to 0.75e18.");
        assertEq(strategistPlatformCut, 0.75e18, "Platform cut should be set to 0.75e18.");
        assertEq(performanceFee, 0.1e18, "Performance fee should be set to 0.1e18.");
        assertEq(platformFee, 0.01e18, "Platform fee should be set to 0.01e18.");
        assertEq(
            feeDistributor,
            hex"000000000000000000000000b813554b423266bbd4c16c32fa383394868c1f55",
            "Fee Distributor should be set to 0x000000000000000000000000b813554b423266bbd4c16c32fa383394868c1f55."
        );
        assertEq(strategistPayoutAddress, strategist, "Strategist payout address should be equal to strategist.");

        assertEq(cellar.liquidityLimit(), type(uint256).max, "Liquidity Limit should be max uint256.");
        assertEq(cellar.depositLimit(), type(uint256).max, "Deposit Limit should be max uint256.");

        assertEq(cellar.owner(), address(this), "Should initialize owner to this contract.");
    }

    // ========================================= DEPOSIT/WITHDRAW TEST =========================================

    function testDepositAndWithdraw(uint256 assets) external {
        assets = bound(assets, 1, type(uint72).max);

        deal(address(USDC), address(this), assets);

        (uint256 highWatermarkBeforeDeposit, , , , , , ) = cellar.feeData();

        // Try depositing more assets than balance.
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        cellar.deposit(assets + 1, address(this));

        // Test single deposit.
        uint256 expectedShares = cellar.previewDeposit(assets);
        uint256 shares = cellar.deposit(assets, address(this));

        uint256 expectedHighWatermark = highWatermarkBeforeDeposit + assets;

        (uint256 highWatermarkAfterDeposit, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterDeposit,
            expectedHighWatermark,
            "High watermark should equal high watermark before deposit plus assets deposited by user."
        );

        assertEq(shares, assets.changeDecimals(6, 18), "Should have 1:1 exchange rate for initial deposit.");
        assertEq(cellar.previewWithdraw(assets), shares, "Withdrawing assets should burn shares given.");
        assertEq(shares, expectedShares, "Depositing assets should mint shares given.");
        assertEq(cellar.totalSupply(), shares, "Should have updated total supply with shares minted.");
        assertEq(cellar.totalAssets(), assets, "Should have updated total assets with assets deposited.");
        assertEq(cellar.balanceOf(address(this)), shares, "Should have updated user's share balance.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Should not have minted fees because no gains.");
        assertEq(cellar.convertToAssets(cellar.balanceOf(address(this))), assets, "Should return all user's assets.");
        assertEq(USDC.balanceOf(address(this)), 0, "Should have deposited assets from user.");

        (uint256 highWatermarkBeforeWithdraw, , , , , , ) = cellar.feeData();

        // Try withdrawing more assets than allowed.
        vm.expectRevert("ERC20: burn amount exceeds balance");
        cellar.withdraw(assets + 1, address(this), address(this));

        // Test single withdraw.
        cellar.withdraw(assets, address(this), address(this));

        expectedHighWatermark = highWatermarkBeforeWithdraw - assets;

        (uint256 highWatermarkAfterWithdraw, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterWithdraw,
            expectedHighWatermark,
            "High watermark should equal high watermark before withdraw minus assets withdrawn by user."
        );

        assertEq(cellar.totalAssets(), 0, "Should have updated total assets with assets withdrawn.");
        assertEq(cellar.balanceOf(address(this)), 0, "Should have redeemed user's share balance.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Should not have minted fees because no gains.");
        assertEq(cellar.convertToAssets(cellar.balanceOf(address(this))), 0, "Should return zero assets.");
        assertEq(USDC.balanceOf(address(this)), assets, "Should have withdrawn assets to user.");
    }

    function testMintAndRedeem(uint256 shares) external {
        shares = bound(shares, 1e18, type(uint112).max);

        // Change decimals from the 18 used by shares to the 6 used by USDC.
        deal(address(USDC), address(this), shares.changeDecimals(18, 6));

        (uint256 highWatermarkBeforeMint, , , , , , ) = cellar.feeData();

        // Try minting more assets than balance.
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        cellar.mint(shares + 1e18, address(this));

        // Test single mint.
        uint256 assets = cellar.mint(shares, address(this));

        uint256 expectedHighWatermark = highWatermarkBeforeMint + assets;

        (uint256 highWatermarkAfterMint, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterMint,
            expectedHighWatermark,
            "High watermark should equal high watermark before mint plus assets deposited by user."
        );

        assertEq(shares.changeDecimals(18, 6), assets, "Should have 1:1 exchange rate for initial deposit.");
        assertEq(cellar.previewRedeem(shares), assets, "Redeeming shares should withdraw assets owed.");
        assertEq(cellar.previewMint(shares), assets, "Minting shares should deposit assets owed.");
        assertEq(cellar.totalSupply(), shares, "Should have updated total supply with shares minted.");
        assertEq(cellar.totalAssets(), assets, "Should have updated total assets with assets deposited.");
        assertEq(cellar.balanceOf(address(this)), shares, "Should have updated user's share balance.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Should not have minted fees because no gains.");
        assertEq(cellar.convertToAssets(cellar.balanceOf(address(this))), assets, "Should return all user's assets.");
        assertEq(USDC.balanceOf(address(this)), 0, "Should have deposited assets from user.");

        (uint256 highWatermarkBeforeRedeem, , , , , , ) = cellar.feeData();

        // Test single redeem.
        cellar.redeem(shares, address(this), address(this));

        expectedHighWatermark = highWatermarkBeforeRedeem - assets;

        (uint256 highWatermarkAfterRedeem, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterRedeem,
            expectedHighWatermark,
            "High watermark should equal high watermark before redeem minus assets redeemed by user."
        );

        assertEq(cellar.balanceOf(address(this)), 0, "Should have redeemed user's share balance.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Should not have minted fees because no gains.");
        assertEq(cellar.convertToAssets(cellar.balanceOf(address(this))), 0, "Should return zero assets.");
        assertEq(USDC.balanceOf(address(this)), assets, "Should have withdrawn assets to user.");
    }

    function testWithdrawInOrder() external {
        cellar.depositIntoPosition(address(wethCLR), 1e18); // $2000
        cellar.depositIntoPosition(address(wbtcCLR), 1e8); // $30,000
        assertEq(cellar.totalAssets(), 32_000e6, "Should have updated total assets with assets deposited.");

        // Mint shares to user to redeem.
        deal(address(cellar), address(this), cellar.previewWithdraw(32_000e6));

        // Withdraw from position.
        uint256 shares = cellar.withdraw(32_000e6, address(this), address(this));

        assertEq(cellar.balanceOf(address(this)), 0, "Should have redeemed all shares.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Should not have minted fees because no gains.");
        assertEq(shares, 32_000e18, "Should returned all redeemed shares.");
        assertEq(WETH.balanceOf(address(this)), 1e18, "Should have transferred position balance to user.");
        assertEq(WBTC.balanceOf(address(this)), 1e8, "Should have transferred position balance to user.");
        assertEq(WETH.balanceOf(address(wethCLR)), 0, "Should have transferred balance from WETH position.");
        assertEq(WBTC.balanceOf(address(wbtcCLR)), 0, "Should have transferred balance from BTC position.");
        assertEq(cellar.totalAssets(), 0, "Should have emptied cellar.");
    }

    function testWithdrawInProportion() external {
        cellar.depositIntoPosition(address(wethCLR), 1e18); // $2000
        cellar.depositIntoPosition(address(wbtcCLR), 1e8); // $30,000

        assertEq(cellar.totalAssets(), 32_000e6, "Should have updated total assets with assets deposited.");
        assertEq(cellar.totalSupply(), 32_000e18);

        // Mint shares to user to redeem.
        deal(address(cellar), address(this), cellar.previewWithdraw(16_000e6));

        // Withdraw from position.
        cellar.setWithdrawType(Cellar.WithdrawType.PROPORTIONAL);
        uint256 shares = cellar.withdraw(16_000e6, address(this), address(this));

        assertEq(cellar.balanceOf(address(this)), 0, "Should have redeemed all shares.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Should not have minted fees because no gains.");
        assertEq(shares, 16_000e18, "Should returned all redeemed shares.");
        assertEq(WETH.balanceOf(address(this)), 0.5e18, "Should have transferred position balance to user.");
        assertEq(WBTC.balanceOf(address(this)), 0.5e8, "Should have transferred position balance to user.");
        assertEq(WETH.balanceOf(address(wethCLR)), 0.5e18, "Should have transferred balance from WETH position.");
        assertEq(WBTC.balanceOf(address(wbtcCLR)), 0.5e8, "Should have transferred balance from WBTC position.");
        assertEq(cellar.totalAssets(), 16_000e6, "Should have half of assets remaining in cellar.");
    }

    function testWithdrawWithDuplicateReceivedAssets() external {
        MockERC4626 wethVault = new MockERC4626(WETH, "WETH Vault LP Token", "WETH-VLT", 18);
        priceRouter.supportAsset(WETH);
        cellar.trustPosition(address(wethVault), Cellar.PositionType.ERC4626);
        cellar.pushPosition(address(wethVault));

        cellar.depositIntoPosition(address(wethCLR), 1e18); // $2000
        cellar.depositIntoPosition(address(wethVault), 0.5e18); // $1000

        assertEq(cellar.totalAssets(), 3000e6, "Should have updated total assets with assets deposited.");
        assertEq(cellar.totalSupply(), 3000e18);

        // Mint shares to user to redeem.
        deal(address(cellar), address(this), cellar.previewWithdraw(3000e6));

        // Withdraw from position.
        uint256 shares = cellar.withdraw(3000e6, address(this), address(this));

        assertEq(cellar.balanceOf(address(this)), 0, "Should have redeemed all shares.");
        assertEq(shares, 3000e18, "Should returned all redeemed shares.");
        assertEq(WETH.balanceOf(address(this)), 1.5e18, "Should have transferred position balance to user.");
        assertEq(WETH.balanceOf(address(wethCLR)), 0, "Should have transferred balance from WETH cellar position.");
        assertEq(WETH.balanceOf(address(wethVault)), 0, "Should have transferred balance from WETH vault position.");
        assertEq(cellar.totalAssets(), 0, "Should have no assets remaining in cellar.");
    }

    function testDepositMintWithdrawRedeemWithZeroInputs() external {
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ZeroShares.selector)));
        cellar.deposit(0, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ZeroAssets.selector)));
        cellar.mint(0, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ZeroAssets.selector)));
        cellar.redeem(0, address(this), address(this));

        // Deal cellar 1 wei of USDC to check that above explanation is correct.
        deal(address(USDC), address(cellar), 1);
        cellar.withdraw(0, address(this), address(this));
        assertEq(USDC.balanceOf(address(this)), 0, "Cellar should not have sent any assets to this address.");
    }

    // ========================================== POSITIONS TEST ==========================================

    function testManagingPositions() external {
        uint256 positionLength = cellar.getPositions().length;

        // Check that `removePosition` actually removes it.
        cellar.removePosition(4);

        assertEq(
            positionLength - 1,
            cellar.getPositions().length,
            "Cellar positions array should be equal to previous length minus 1."
        );

        assertFalse(cellar.isPositionUsed(address(WETH)), "`isPositionUsed` should be false for WETH.");

        // Check that `addPosition` actually adds it.
        cellar.addPosition(4, address(WETH));

        assertEq(
            positionLength,
            cellar.getPositions().length,
            "Cellar positions array should be equal to previous length."
        );

        assertEq(cellar.positions(4), address(WETH), "`positions[4]` should be WETH.");
        assertTrue(cellar.isPositionUsed(address(WETH)), "`isPositionUsed` should be true for WETH.");

        // Remove WETH position.
        cellar.removePosition(4);

        // Check that `pushPosition` actually adds it.
        cellar.pushPosition(address(WETH));

        assertEq(
            positionLength,
            cellar.getPositions().length,
            "Cellar positions array should be equal to previous length."
        );

        assertEq(cellar.positions(4), address(WETH), "`positions[4]` should be WETH.");
        assertTrue(cellar.isPositionUsed(address(WETH)), "`isPositionUsed` should be true for WETH.");

        // Check that `pushPosition` reverts if position is already used.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__PositionAlreadyUsed.selector, address(WETH))));
        cellar.pushPosition(address(WETH));

        // Check that `addPosition` reverts if position is already used.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__PositionAlreadyUsed.selector, address(WETH))));
        cellar.addPosition(4, address(WETH));

        // Give Cellar 1 wei of WETH.
        deal(address(WETH), address(cellar), 1);

        // Check that `removePosition` reverts if position has any funds in it.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__PositionNotEmpty.selector,
                    address(WETH),
                    WETH.balanceOf(address(cellar))
                )
            )
        );
        cellar.removePosition(4);

        // Check that `pushPosition` reverts if position is not trusted.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__UntrustedPosition.selector, address(0))));
        cellar.pushPosition(address(0));

        // Check that `addPosition` reverts if position is not trusted.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__UntrustedPosition.selector, address(0))));
        cellar.addPosition(4, address(0));

        // Set Cellar WETH balance to 0.
        deal(address(WETH), address(cellar), 0);

        // Check that `swapPosition` works as expected.
        cellar.swapPositions(4, 2);
        assertEq(cellar.positions(4), address(wethCLR), "`positions[4]` should be wethCLR.");
        assertEq(cellar.positions(2), address(WETH), "`positions[2]` should be WETH.");

        // Check that removing the holding position reverts.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__RemoveHoldingPosition.selector)));
        cellar.removePosition(0);

        cellar.swapPositions(4, 0);

        // Check that setting holding position to unused position reverts.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidPosition.selector, address(0))));
        cellar.setHoldingPosition(address(0));

        // Check that setting holding position to position with mismatched assets reverts.
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Cellar.Cellar__AssetMismatch.selector, address(WETH), address(USDC)))
        );
        cellar.setHoldingPosition(address(WETH));
    }

    function testTrustingPositions() external {
        address newPosition = vm.addr(45);

        priceRouter.supportAsset(ERC20(newPosition));
        cellar.trustPosition(newPosition, Cellar.PositionType.ERC20);
        assertTrue(cellar.isTrusted(newPosition), "New position should now be trusted.");
        assertEq(
            uint256(cellar.getPositionType(newPosition)),
            uint256(Cellar.PositionType.ERC20),
            "New position's type should be ERC20."
        );
    }

    // ========================================== REBALANCE TEST ==========================================

    function testSettingBadRebalanceDeviation() external {
        // Max rebalance deviation value is 10%.
        uint256 deviation = 0.2e18;
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__InvalidRebalanceDeviation.selector,
                    deviation,
                    cellar.MAX_REBALANCE_DEVIATION()
                )
            )
        );
        cellar.setRebalanceDeviation(deviation);
    }

    function testRebalanceBetweenCellarOrERC4626Positions(uint256 assets) external {
        assets = bound(assets, 1e6, type(uint72).max);

        // Update allowed rebalance deviation to work with mock swap router.
        cellar.setRebalanceDeviation(0.051e18);

        cellar.depositIntoPosition(address(usdcCLR), assets);

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        (uint256 highWatermarkBeforeRebalance, , , , , , ) = cellar.feeData();

        uint256 assetsTo = cellar.rebalance(
            address(usdcCLR),
            address(wethCLR),
            assets,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(path, assets, 0, address(cellar), address(cellar))
        );

        (uint256 highWatermarkAfterRebalance, , , , , , ) = cellar.feeData();

        assertEq(highWatermarkBeforeRebalance, highWatermarkAfterRebalance, "Should not change highwatermark.");
        assertEq(assetsTo, exchange.quote(assets, path), "Should received expected assets from swap.");
        assertEq(usdcCLR.balanceOf(address(cellar)), 0, "Should have rebalanced from position.");
        assertEq(wethCLR.balanceOf(address(cellar)), assetsTo, "Should have rebalanced to position.");
    }

    function testRebalanceBetweenERC20Positions(uint256 assets) external {
        assets = bound(assets, 1e6, type(uint72).max);

        // Update allowed rebalance deviation to work with mock swap router.
        cellar.setRebalanceDeviation(0.051e18);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), assets);

        // Deposit USDC into Cellar.
        cellar.deposit(assets, address(this));

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        uint256 assetsTo = cellar.rebalance(
            address(USDC),
            address(WETH),
            assets,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(path, assets, 0, address(cellar), address(cellar))
        );

        assertEq(assetsTo, exchange.quote(assets, path), "Should received expected assets from swap.");
        assertEq(USDC.balanceOf(address(cellar)), 0, "Should have rebalanced from position.");
        assertEq(WETH.balanceOf(address(cellar)), assetsTo, "Should have rebalanced to position.");
    }

    function testRebalanceToSamePosition(uint256 assets) external {
        assets = bound(assets, 1, type(uint72).max);

        cellar.depositIntoPosition(address(usdcCLR), assets);

        uint256 assetsTo = cellar.rebalance(
            address(usdcCLR),
            address(usdcCLR),
            assets,
            SwapRouter.Exchange.UNIV2, // Will be ignored because no swap is necessary.
            abi.encode(0) // Will be ignored because no swap is necessary.
        );

        assertEq(assetsTo, assets, "Should received expected assets from swap.");
        assertEq(usdcCLR.balanceOf(address(cellar)), assets, "Should have not changed position balance.");
    }

    function testRebalancingToInvalidPosition() external {
        uint256 assets = 100e6;

        cellar.depositIntoPosition(address(usdcCLR), assets);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidPosition.selector, address(0))));
        cellar.rebalance(
            address(usdcCLR),
            address(0), // An Invalid Position
            assets,
            SwapRouter.Exchange.UNIV2, // Will be ignored because no swap is necessary.
            abi.encode(0) // Will be ignored because no swap is necessary.
        );
    }

    function testRebalanceWithInvalidSwapAmount() external {
        uint256 assets = 100e6;

        // Check that encoding the swap params with the wrong amount of assets
        // reverts the rebalance call.
        uint256 invalidAssets = assets - 1;

        cellar.depositIntoPosition(address(usdcCLR), assets);

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__WrongSwapParams.selector)));
        cellar.rebalance(
            address(usdcCLR),
            address(wethCLR),
            assets,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(path, invalidAssets, 0, address(cellar), address(cellar))
        );
    }

    // ======================================== EMERGENCY TESTS ========================================

    function testShutdown() external {
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractNotShutdown.selector)));
        cellar.liftShutdown();

        cellar.initiateShutdown();

        assertTrue(cellar.isShutdown(), "Should have initiated shutdown.");

        cellar.liftShutdown();

        assertFalse(cellar.isShutdown(), "Should have lifted shutdown.");
    }

    function testWithdrawingWhileShutdown() external {
        deal(address(USDC), address(this), 1);
        cellar.deposit(1, address(this));

        cellar.initiateShutdown();

        cellar.withdraw(1, address(this), address(this));

        assertEq(USDC.balanceOf(address(this)), 1, "Should withdraw while shutdown.");
    }

    function testProhibitedActionsWhileShutdown() external {
        uint256 assets = 100e6;

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), assets);

        // Deposit USDC into Cellar.
        cellar.deposit(assets, address(this));

        cellar.initiateShutdown();

        deal(address(USDC), address(this), 1);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.initiateShutdown();

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.deposit(1, address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.addPosition(5, address(0));

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.pushPosition(address(0));

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.rebalance(
            address(USDC),
            address(WETH),
            assets,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(path, assets, 0, address(cellar), address(cellar))
        );

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.initiateShutdown();
    }

    // ========================================= LIMITS TESTS =========================================

    function testLimits(uint256 amount) external {
        amount = bound(amount, 1, type(uint72).max);

        deal(address(USDC), address(this), amount);
        USDC.approve(address(cellar), amount);
        cellar.deposit(amount, address(this));

        assertEq(cellar.maxDeposit(address(this)), type(uint256).max, "Should have no max deposit.");
        assertEq(cellar.maxMint(address(this)), type(uint256).max, "Should have no max mint.");

        cellar.setDepositLimit(amount * 2);
        cellar.setLiquidityLimit(amount / 2);

        assertEq(cellar.depositLimit(), amount * 2, "Should have changed the deposit limit.");
        assertEq(cellar.liquidityLimit(), amount / 2, "Should have changed the liquidity limit.");
        assertEq(cellar.maxDeposit(address(this)), 0, "Should have reached new max deposit.");
        assertEq(cellar.maxMint(address(this)), 0, "Should have reached new max mint.");

        cellar.setLiquidityLimit(amount * 3);

        assertEq(cellar.maxDeposit(address(this)), amount, "Should not have reached new max deposit.");
        assertEq(cellar.maxMint(address(this)), amount.changeDecimals(6, 18), "Should not have reached new max mint.");

        address otherUser = vm.addr(1);

        assertEq(cellar.maxDeposit(otherUser), amount * 2, "Should have different max deposits for other user.");
        assertEq(
            cellar.maxMint(otherUser),
            (amount * 2).changeDecimals(6, 18),
            "Should have different max mint for other user."
        );

        // Hit global liquidity limit and deposit limit for other user.
        vm.startPrank(otherUser);
        deal(address(USDC), address(otherUser), amount * 2);
        USDC.approve(address(cellar), amount * 2);
        cellar.deposit(amount * 2, otherUser);
        vm.stopPrank();

        assertEq(cellar.maxDeposit(address(this)), 0, "Should have hit liquidity limit for max deposit.");
        assertEq(cellar.maxMint(address(this)), 0, "Should have hit liquidity limit for max mint.");

        // Reduce liquidity limit by withdrawing.
        cellar.withdraw(amount, address(this), address(this));

        assertEq(cellar.maxDeposit(address(this)), amount, "Should have reduced liquidity limit for max deposit.");
        assertEq(
            cellar.maxMint(address(this)),
            amount.changeDecimals(6, 18),
            "Should have reduced liquidity limit for max mint."
        );
        assertEq(
            cellar.maxDeposit(otherUser),
            0,
            "Should have not changed max deposit for other user because they are still at the deposit limit."
        );
        assertEq(
            cellar.maxMint(otherUser),
            0,
            "Should have not changed max mint for other user because they are still at the deposit limit."
        );

        cellar.initiateShutdown();

        assertEq(cellar.maxDeposit(address(this)), 0, "Should show no assets can be deposited when shutdown.");
        assertEq(cellar.maxMint(address(this)), 0, "Should show no shares can be minted when shutdown.");
    }

    function testDepositAboveDepositLimit(uint256 amount) external {
        // Depositing above the deposit limit should revert.
        amount = bound(amount, 101e6, type(uint112).max);

        uint256 limit = 100e6;
        cellar.setDepositLimit(limit);

        deal(address(USDC), address(this), amount);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__DepositRestricted.selector, amount, limit)));
        cellar.deposit(amount, address(this));
    }

    function testMintAboveDepositLimit(uint256 amount) external {
        // Minting above the deposit limit should revert.
        amount = bound(amount, 101, type(uint112).max);

        uint256 limit = 100e6;
        cellar.setDepositLimit(limit);

        deal(address(USDC), address(this), amount * 1e6);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__DepositRestricted.selector, amount * 1e6, limit)));
        cellar.mint(amount * 1e18, address(this));
    }

    function testDepositAboveLiquidityLimit(uint256 amount) external {
        // Depositing above the deposit limit should revert.
        amount = bound(amount, 101e6, type(uint112).max);

        uint256 limit = 100e6;
        cellar.setLiquidityLimit(limit);

        deal(address(USDC), address(this), amount);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__DepositRestricted.selector, amount, limit)));
        cellar.deposit(amount, address(this));
    }

    function testMintAboveLiquidityLimit(uint256 amount) external {
        // Minting above the deposit limit should revert.
        amount = bound(amount, 101, type(uint112).max);

        uint256 limit = 100e6;
        cellar.setLiquidityLimit(limit);

        deal(address(USDC), address(this), amount * 1e6);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__DepositRestricted.selector, amount * 1e6, limit)));
        cellar.mint(amount * 1e18, address(this));
    }

    function testChangingLimits() external {
        cellar.setLiquidityLimit(777);
        cellar.setDepositLimit(777_777);
        assertEq(cellar.liquidityLimit(), 777, "Liquidity limit should be set to 777.");
        assertEq(cellar.depositLimit(), 777_777, "Deposit limit should be set to 777,777.");
    }

    // =========================================== TOTAL ASSETS TEST ===========================================

    function testTotalAssets(
        uint256 usdcAmount,
        uint256 usdcCLRAmount,
        uint256 wethCLRAmount,
        uint256 wbtcCLRAmount,
        uint256 wethAmount
    ) external {
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000_000_000e6);
        usdcCLRAmount = bound(usdcCLRAmount, 1e6, 1_000_000_000_000e6);
        wethCLRAmount = bound(wethCLRAmount, 1e18, 200_000_000e18);
        wbtcCLRAmount = bound(wbtcCLRAmount, 1e8, 21_000_000e8);
        wethAmount = bound(wethAmount, 1e18, 200_000_000e18);
        uint256 totalAssets = cellar.totalAssets();

        assertEq(totalAssets, 0, "Cellar total assets should be zero.");

        cellar.depositIntoPosition(address(usdcCLR), usdcCLRAmount);
        cellar.depositIntoPosition(address(wethCLR), wethCLRAmount);
        cellar.depositIntoPosition(address(wbtcCLR), wbtcCLRAmount);
        deal(address(WETH), address(cellar), wethAmount);
        deal(address(USDC), address(cellar), usdcAmount);

        uint256 expectedTotalAssets = usdcAmount + usdcCLRAmount;
        expectedTotalAssets += (wethAmount + wethCLRAmount).mulDivDown(2_000e6, 1e18);
        expectedTotalAssets += wbtcCLRAmount.mulDivDown(30_000e6, 1e8);

        totalAssets = cellar.totalAssets();

        assertApproxEqAbs(
            totalAssets,
            expectedTotalAssets,
            1,
            "`totalAssets` should equal all asset values summed together."
        );
        (uint256 getDataTotalAssets, , , , ) = cellar.getData();
        assertEq(getDataTotalAssets, totalAssets, "`getData` total assets should be the same as cellar `totalAssets`.");
    }

    // ====================================== PERFORMANCE/PLATFORM FEE TEST ======================================

    function testChangingFeeData() external {
        address newStrategistAddress = vm.addr(777);
        bytes32 validCosmosAddress = hex"000000000000000000000000ffffffffffffffffffffffffffffffffffffffff";
        cellar.setPlatformFee(0.2e18);
        cellar.setPerformanceFee(0.03e18);
        cellar.setFeesDistributor(validCosmosAddress);
        cellar.setStrategistPerformanceCut(0.8e18);
        cellar.setStrategistPlatformCut(0.8e18);
        cellar.setStrategistPayoutAddress(newStrategistAddress);
        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            bytes32 feeDistributor,
            address strategistPayoutAddress
        ) = cellar.feeData();
        assertEq(strategistPerformanceCut, 0.8e18, "Performance cut should be set to 0.8e18.");
        assertEq(strategistPlatformCut, 0.8e18, "Platform cut should be set to 0.8e18.");
        assertEq(platformFee, 0.2e18, "Platform fee should be set to 0.2e18.");
        assertEq(performanceFee, 0.03e18, "Performance fee should be set to 0.03e18.");
        assertEq(feeDistributor, validCosmosAddress, "Fee Distributor should be set to `validCosmosAddress`.");
        assertEq(
            strategistPayoutAddress,
            newStrategistAddress,
            "Strategist payout address should be set to `newStrategistAddress`."
        );

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidFee.selector)));
        cellar.setPlatformFee(0.21e18);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidFee.selector)));
        cellar.setPerformanceFee(0.51e18);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidCosmosAddress.selector)));
        cellar.setFeesDistributor(hex"0000000000000000000000010000000000000000000000000000000000000000");

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidFeeCut.selector)));
        cellar.setStrategistPerformanceCut(1.1e18);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidFeeCut.selector)));
        cellar.setStrategistPlatformCut(1.1e18);
    }

    function testPreviewFunctionsAccountForPerformanceFee(uint256 deposit, uint256 yield) external {
        deposit = bound(deposit, 1_000e6, 100_000_000e6);
        // Cap yield to 100x deposit
        uint256 yieldUpperBound = 100 * deposit;
        // Floor yield above 1e-6x of the deposit
        uint256 yieldLowerBound = deposit / 1_000_000;
        yield = bound(yield, yieldLowerBound, yieldUpperBound);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), type(uint256).max);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        (uint256 currentHWM, , , , , , ) = cellar.feeData();
        assertEq(currentHWM, deposit, "High Watermark should be equal to deposits.");

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), deposit + yield);

        assertApproxEqAbs(
            cellar.previewMint(100e18),
            cellar.mint(100e18, address(this)),
            1,
            "`previewMint` should return the same as `mint`."
        );

        assertApproxEqAbs(
            cellar.previewDeposit(100e6),
            cellar.deposit(100e6, address(this)),
            1,
            "`previewDeposit` should return the same as `deposit`."
        );

        cellar.approve(address(cellar), type(uint256).max);
        assertApproxEqAbs(
            cellar.previewWithdraw(100e6),
            cellar.withdraw(100e6, address(this), address(this)),
            1,
            "`previewWithdraw` should return the same as `withdraw`."
        );

        assertApproxEqAbs(
            cellar.previewRedeem(100e18),
            cellar.redeem(100e18, address(this), address(this)),
            1,
            "`previewRedeem` should return the same as `redeem`."
        );
    }

    function testFindMax() external {
        uint256 deposit = 1e6;

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), type(uint256).max);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // No yield has been earned.
        assertEq(cellar.maxWithdraw(address(this)), deposit, "Max withdraw should equal deposit.");
        uint256 expectedShares = 1e18;
        assertEq(cellar.maxRedeem(address(this)), expectedShares, "Max Redeem should be 1 share.");

        // Simulate yield.
        deal(address(USDC), address(cellar), 10e6);

        uint256 expectedAssets = 9.1e6; // initial $1 deposit + $9 of yield - 10% performance fees.
        assertEq(
            cellar.maxWithdraw(address(this)),
            expectedAssets,
            "Max withdraw should equal deposit + yield - fees."
        );
        assertEq(cellar.maxRedeem(address(this)), expectedShares, "Max Redeem should be 1 share.");

        // Strategist moves half of funds into an illiquid position.
        LockedERC4626 lockedUSDC = new LockedERC4626(USDC, "Locked USDC", "LUSDC", 1e18); // 100% of funds are locked.
        cellar.trustPosition(address(lockedUSDC), Cellar.PositionType.ERC4626);
        cellar.pushPosition(address(lockedUSDC));

        // Strategist rebalances into illiquid cellar.
        _rebalance(cellar, USDC, lockedUSDC, 5e6);

        assertEq(cellar.totalAssets(), 10e6, "Total assets should not have changed.");

        expectedAssets = 5e6; // Half the assets are locked, so maxWithdraw should be half of deposit + yield.
        expectedShares = cellar.previewWithdraw(expectedAssets);
        assertEq(cellar.maxWithdraw(address(this)), expectedAssets, "Max withdraw should equal expectedAssets.");
        assertApproxEqAbs(
            cellar.maxRedeem(address(this)),
            expectedShares,
            1,
            "Max Redeem should equal previewRedeem(maxWithdraw(user))."
        );

        // Strategist changes withdraw type to proportional.
        cellar.setWithdrawType(Cellar.WithdrawType.PROPORTIONAL);

        expectedAssets = 0; // 1 position is completely illiquid, so no funds can be taken from the cellar.
        expectedShares = 0;
        assertEq(cellar.maxWithdraw(address(this)), expectedAssets, "Max withdraw should equal 0.");
        assertApproxEqAbs(cellar.maxRedeem(address(this)), expectedShares, 1, "Max Redeem should equal 0.");
    }

    function testPerformanceFeesWithPositivePerformance(uint256 deposit, uint256 yield) external {
        deposit = bound(deposit, 100e6, 1_000_000e6);
        yield = bound(yield, 10e6, 10_000e6);
        (, , , , uint64 performanceFee, , ) = cellar.feeData();

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), 3 * deposit);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) + yield);

        // Deposit into cellar to trigger performance fee calculation.
        cellar.deposit(deposit, address(this));

        uint256 feeSharesInCellar = cellar.balanceOf(address(cellar));
        assertTrue(feeSharesInCellar > 0, "Cellar should have been minted fee shares.");

        uint256 performanceFeeInAssets = cellar.previewRedeem(feeSharesInCellar);
        uint256 expectedPerformanceFeeInAssets = yield.mulWadDown(performanceFee);
        // It is okay for actual performance fee in assets to be equal to or 1 wei less than expected.
        assertTrue(
            performanceFeeInAssets == expectedPerformanceFeeInAssets ||
                performanceFeeInAssets + 1 == expectedPerformanceFeeInAssets,
            "Actual performance fees should equal expected, or actual can be 1 less wei than expected."
        );

        // Deposit into cellar to trigger performance fee calculation.
        cellar.deposit(deposit, address(this));

        assertTrue(
            feeSharesInCellar == cellar.balanceOf(address(cellar)),
            "Cellar should not have been minted more fee shares."
        );
    }

    function testPerformanceFeesWithNegativePerformance(uint256 deposit, uint256 loss) external {
        deposit = bound(deposit, 100_000e6, 1_000_000e6);
        loss = bound(loss, 10e6, 10_000e6);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), 2 * deposit);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Simulate Cellar losing yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) - loss);

        // Deposit into cellar to trigger performance fee calculation.
        cellar.deposit(deposit, address(this));

        assertTrue(cellar.balanceOf(address(cellar)) == 0, "Cellar should not have any fee shares.");
    }

    function testPerformanceFeesWithNeutralPerformance(uint256 deposit, uint256 amount) external {
        deposit = bound(deposit, 100_000e6, 1_000_000e6);
        amount = bound(amount, 10e6, 10_000e6);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), 2 * deposit);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) + amount);

        // Simulate Cellar losing yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) - amount);

        // Deposit into cellar to trigger performance fee calculation.
        cellar.deposit(deposit, address(this)); //deposit into Cellar

        assertTrue(cellar.balanceOf(address(cellar)) == 0, "Cellar should not have any fee shares.");
    }

    function testPlatformFees(uint256 timePassed, uint256 deposit) external {
        // Cap time passed to 1 year. Platform fees will be collected on the
        // order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 1e6, 1_000_000_000e6);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Calculate expected platform fee.
        (, , uint64 strategistPlatformCut, uint64 platformFee, , , ) = cellar.feeData();
        uint256 expectedPlatformFee = (deposit * platformFee * timePassed) / (365 days * 1e18);

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Call `sendFees` to calculate pending platform fees, and distribute
        // them to strategist, and Cosmos.
        cellar.sendFees();

        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertEq(
            feesInAssetsSentToCosmos,
            expectedPlatformFee.mulWadDown(1e18 - strategistPlatformCut),
            "Platform fee sent to Cosmos should be equal to expectedPlatformFee * (1 - strategistPlatformCut)."
        );

        uint256 expectedPlatformFeeInAssetsSentToStrategist = expectedPlatformFee.mulWadDown(strategistPlatformCut);

        // It is okay for actual fees sent to strategist to be equal to or 1 wei less than expected.
        assertTrue(
            feesInAssetsSentToStrategist == expectedPlatformFeeInAssetsSentToStrategist ||
                feesInAssetsSentToStrategist + 1 == expectedPlatformFeeInAssetsSentToStrategist,
            "Platform fee sent to strategist should be equal to expectedPlatformFee * (strategistPlatformCut)."
        );

        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have burned all performance fee shares.");
    }

    function testPlatformAndPerformanceFees(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the
        // order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);
        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }
        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            ,

        ) = cellar.feeData();

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        deal(address(USDC), address(cosmos), 0);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        uint256 totalAssetsBeforeSendFees = USDC.balanceOf(address(cellar)) + yield;
        deal(address(USDC), address(cellar), totalAssetsBeforeSendFees);

        // Call `sendFees` to calculate pending performance and platform fees,
        // and distribute them to strategist, and Cosmos.
        cellar.sendFees();

        uint256 expectedPerformanceFees = yield.mulDivDown(performanceFee, 1e18);

        // Minting platform fees dilutes share price, so it also dilutes pending performance fees.
        uint256 expectedPerformanceFeesAdjustedForDilution = (expectedPerformanceFees *
            (1e18 - (platformFee * timePassed) / 365 days)) / 1e18;

        uint256 expectedPlatformFees = ((deposit + yield) * platformFee * timePassed) / (365 days * 1e18);

        uint256 expectedTotalFeesAdjustedForDilution = expectedPerformanceFeesAdjustedForDilution +
            expectedPlatformFees;

        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedTotalFeesAdjustedForDilution,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected total fees after dilution."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPlatformFees.mulWadDown(strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(strategistPerformanceCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut) + (total performance fees * strategist performance cut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPlatformFees.mulWadDown(1e18 - strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(1e18 - strategistPerformanceCut),
            2,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut)) + (total performance fees * (1-strategist performance cut))."
        );

        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have burned all fee shares.");

        uint256 expectedHighWatermark = totalAssetsBeforeSendFees - feesInAssetsSentToCosmos;

        (uint256 highWatermarkAfterSendFees, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterSendFees,
            expectedHighWatermark,
            "High watermark should equal high watermark before send fees minus assets sent to Cosmos."
        );
    }

    function testPerformanceFeesWithZeroPlatformFees(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);
        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setPlatformFee(0);
        (, uint64 strategistPerformanceCut, , , uint64 performanceFee, , ) = cellar.feeData();

        uint256 assetAmount = deposit / 2;
        uint256 sharesAmount = assetAmount.changeDecimals(6, 18);
        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        // Deposit into cellar.
        cellar.deposit(assetAmount, address(this));
        // Mint shares from the cellar.
        cellar.mint(sharesAmount, address(this));

        (uint256 highWatermark, , , , , , ) = cellar.feeData();
        assertEq(highWatermark, cellar.totalAssets(), "High watermark should equal totalAssets.");

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) + yield);

        cellar.sendFees();

        // Redeem all shares from the cellar.
        uint256 shares = cellar.balanceOf(address(this));
        cellar.redeem(shares, address(this), address(this));

        uint256 expectedPerformanceFees = yield.mulDivDown(performanceFee, 1e18);

        // Check that no fees are minted.
        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedPerformanceFees,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected performance fee."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPerformanceFees.mulWadDown(strategistPerformanceCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total performance fees * strategist performance cut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPerformanceFees.mulWadDown(1e18 - strategistPerformanceCut),
            2,
            "Assets sent to Cosmos should be equal to (total performance fees * (1-strategist performance cut))."
        );

        assertApproxEqAbs(
            cellar.previewRedeem(cellar.balanceOf(address(cellar))),
            0,
            1,
            "Cellar fee shares should be redeemable for zero assets."
        );
    }

    function testPlatformFeesWithZeroPerformanceFees(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);
        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setPerformanceFee(0);
        (, , uint64 strategistPlatformCut, uint64 platformFee, , , ) = cellar.feeData();

        uint256 assetAmount = deposit / 2;
        uint256 sharesAmount = assetAmount.changeDecimals(6, 18);
        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        // Deposit into cellar.
        cellar.deposit(assetAmount, address(this));
        // Mint shares from the cellar.
        cellar.mint(sharesAmount, address(this));

        (uint256 highWatermark, , , , , , ) = cellar.feeData();
        assertEq(highWatermark, cellar.totalAssets(), "High watermark should equal totalAssets.");

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) + yield);

        cellar.sendFees();

        // Redeem all shares from the cellar.
        uint256 shares = cellar.balanceOf(address(this));
        cellar.redeem(shares, address(this), address(this));

        uint256 expectedPlatformFees = ((deposit + yield) * platformFee * timePassed) / (365 days * 1e18);

        // Check that no fees are minted.
        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedPlatformFees,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected platform fees."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPlatformFees.mulWadDown(strategistPlatformCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPlatformFees.mulWadDown(1e18 - strategistPlatformCut),
            2,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut))."
        );

        assertApproxEqAbs(
            cellar.previewRedeem(cellar.balanceOf(address(cellar))),
            0,
            1,
            "Cellar fee shares should be redeemable for zero assets."
        );
    }

    function testPlatformAndPerformanceFeesWithZeroFees(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);
        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setPerformanceFee(0);
        cellar.setPlatformFee(0);

        uint256 assetAmount = deposit / 2;
        uint256 sharesAmount = assetAmount.changeDecimals(6, 18);
        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        // Deposit into cellar.
        cellar.deposit(assetAmount, address(this));
        // Mint shares from the cellar.
        cellar.mint(sharesAmount, address(this));

        (uint256 highWatermark, , , , , , ) = cellar.feeData();
        assertEq(highWatermark, cellar.totalAssets(), "High watermark should equal totalAssets.");

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) + yield);

        cellar.sendFees();

        // Redeem all shares from the cellar.
        uint256 shares = cellar.balanceOf(address(this));
        cellar.redeem(shares, address(this), address(this));

        // Check that no fees are minted.
        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));
        assertEq(feesInAssetsSentToCosmos, 0, "Fees sent to Cosmos should be zero.");
        assertEq(feesInAssetsSentToStrategist, 0, "Fees sent to strategist should be zero.");
        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have zero fee shares");

        (highWatermark, , , , , , ) = cellar.feeData();
        assertEq(highWatermark, 0, "High watermark should equal zero.");
    }

    function testResetHighWatermark(
        uint256 deposit,
        uint256 loss,
        uint256 gain
    ) external {
        deposit = bound(deposit, 100_000e6, 1_000_000e6);
        loss = bound(loss, 10e6, 10_000e6);
        gain = bound(gain, 10e6, 10_000e6);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), (2 * deposit) + 1);

        // Deposit into the Cellar.
        cellar.deposit(deposit, address(this)); //deposit into Cellar

        // Simulate Cellar losing yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) - loss);

        // Deposit into the Cellar to check if performance fees are minted.
        cellar.deposit(deposit, address(this));

        assertEq(
            cellar.balanceOf(address(cellar)),
            0,
            "Cellar should have not been minted any performance fee shares."
        );

        // Reset Cellar's High Watermark value.
        cellar.resetHighWatermark();

        (uint256 currentHighWatermark, , , , uint64 performanceFee, , ) = cellar.feeData();
        uint256 expectedHighWatermark = 2 * deposit - loss;
        assertEq(
            currentHighWatermark,
            expectedHighWatermark,
            "Cellar should have reset high watermark to the current assets."
        );

        // Simulate Cellar earning yield.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)) + gain);

        // Deposit into the Cellar to check that performance fees are minted.
        cellar.deposit(1, address(this));

        assertTrue(cellar.balanceOf(address(cellar)) > 0, "Cellar should have been minted performance fee shares.");

        uint256 expectedPerformanceFeeInAssets = gain.mulWadDown(performanceFee);

        // Cellars rounds down when using previewRedeem, so it is acceptable to be off by 1 wei.
        assertApproxEqAbs(
            cellar.previewRedeem(cellar.balanceOf(address(cellar))),
            expectedPerformanceFeeInAssets,
            1,
            "Cellar performance fee shares in assets should equal (gain * performanceFee)."
        );
    }

    function testPayoutNotSet() external {
        cellar.setStrategistPayoutAddress(address(0));
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__PayoutNotSet.selector)));
        cellar.sendFees();
    }

    function testMaliciousStrategistWithUnboundForLoop() external {
        // Initialize test Cellar.
        MockCellar multiPositionCellar;
        address[] memory positions;
        {
            // Create new cellar with WETH, USDC, and WBTC positions.
            positions = new address[](1);
            positions[0] = address(USDC);

            Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](1);
            positionTypes[0] = Cellar.PositionType.ERC20;

            multiPositionCellar = new MockCellar(
                registry,
                USDC,
                positions,
                positionTypes,
                address(USDC),
                Cellar.WithdrawType.ORDERLY,
                "Asset Management Cellar LP Token",
                "assetmanagement-CLR",
                strategist
            );
            stdstore
                .target(address(multiPositionCellar))
                .sig(multiPositionCellar.shareLockPeriod.selector)
                .checked_write(uint256(0));
        }

        MockERC20 position;
        for (uint256 i = 1; i < 32; i++) {
            position = new MockERC20("Howdy", 18);
            priceRouter.supportAsset(position);
            multiPositionCellar.trustPosition(address(position), Cellar.PositionType.ERC20);
            multiPositionCellar.pushPosition(address(position));
        }

        assertEq(multiPositionCellar.getPositions().length, 32, "Cellar should have 32 positions.");

        // Adding one more position should revert.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__PositionArrayFull.selector, uint256(32))));
        multiPositionCellar.addPosition(32, vm.addr(777));

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__PositionArrayFull.selector, uint256(32))));
        multiPositionCellar.pushPosition(vm.addr(777));

        // Check that users can still interact with the cellar even at max positions size.
        deal(address(USDC), address(this), 100e6);
        USDC.approve(address(multiPositionCellar), 100e6);
        uint256 gas = gasleft();
        multiPositionCellar.deposit(100e6, address(this));
        uint256 remainingGas = gasleft();
        assertLt(
            gas - remainingGas,
            500_000,
            "Gas used on deposit should be comfortably less than the block gas limit."
        );

        gas = gasleft();
        multiPositionCellar.withdraw(100e6, address(this), address(this));
        remainingGas = gasleft();
        assertLt(
            gas - remainingGas,
            500_000,
            "Gas used on withdraw should be comfortably less than the block gas limit."
        );

        // Now check a worst case scenario, SP maxes out positions, and evenly
        // distributes funds to every position, then user withdraws.
        deal(address(USDC), address(this), 32e6);
        USDC.approve(address(multiPositionCellar), 32e6);
        multiPositionCellar.deposit(32e6, address(this));

        uint256 totalAssets = multiPositionCellar.totalAssets();

        // Change the cellars USDC balance, so that we can deal cellar assets in
        // other positions and not change the share price.
        deal(address(USDC), address(multiPositionCellar), 1e6);

        positions = multiPositionCellar.getPositions();
        for (uint256 i = 1; i < positions.length; i++) {
            priceRouter.setExchangeRate(ERC20(positions[i]), USDC, 1e6);
            deal(positions[i], address(multiPositionCellar), 1e18);
        }

        assertEq(multiPositionCellar.totalAssets(), totalAssets, "Cellar total assets should be unchanged.");

        gas = gasleft();
        multiPositionCellar.withdraw(32e6, address(this), address(this));
        remainingGas = gasleft();
        assertLt(
            gas - remainingGas,
            1_400_000,
            "Gas used on worst case scenario withdraw should be comfortably less than the block gas limit."
        );
    }

    function testRebalanceDeviation(uint256 assets) external {
        assets = bound(assets, 1e6, type(uint72).max);

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), assets);

        // Deposit USDC into Cellar.
        cellar.deposit(assets, address(this));

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);

        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__TotalAssetDeviatedOutsideRange.selector,
                    assets.mulWadDown(0.95e18),
                    assets.mulDivUp(0.997e18, 1e18),
                    assets.mulWadDown(1.003e18)
                )
            )
        );
        cellar.rebalance(
            address(USDC),
            address(WETH),
            assets,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(path, assets, 0, address(cellar), address(cellar))
        );
    }

    function testRebalanceWithSharesMinted() external {
        // False specifies that this cellar tries to change the callers totalSupply on deposit calls.
        ReentrancyERC4626 maliciousCellar = new ReentrancyERC4626(USDC, "Bad Cellar", "BC", false);

        cellar.trustPosition(address(maliciousCellar), Cellar.PositionType.ERC4626);
        cellar.pushPosition(address(maliciousCellar));

        uint256 assets = 10000e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(maliciousCellar), assets);

        cellar.deposit(assets, address(this));

        // Try to rebalance into malicous cellar that will change this cellars totalSupply.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__TotalSharesMustRemainConstant.selector,
                    cellar.totalSupply() + 1,
                    cellar.totalSupply()
                )
            )
        );
        cellar.rebalance(
            address(USDC),
            address(maliciousCellar),
            assets,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(0)
        );
    }

    function testMaliciousRebalanceIntoUntrackedPosition() external {
        // Create a new Cellar with two positions USDC, and WETH.
        // Setup Cellar:
        address[] memory positions = new address[](2);
        positions[0] = address(USDC);
        positions[1] = address(WETH);

        Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](2);
        positionTypes[0] = Cellar.PositionType.ERC20;
        positionTypes[1] = Cellar.PositionType.ERC20;

        Cellar badCellar = new MockCellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.ORDERLY,
            "Multiposition Cellar LP Token",
            "multiposition-CLR",
            strategist
        );
        stdstore.target(address(badCellar)).sig(badCellar.shareLockPeriod.selector).checked_write(uint256(0));

        // User join bad cellar.
        address alice = vm.addr(77777);
        deal(address(USDC), alice, 1_000_000e6);
        vm.startPrank(alice);
        USDC.approve(address(badCellar), 1_000_000e6);
        badCellar.deposit(1_000_000e6, alice);
        vm.stopPrank();

        // Strategist calls rebalance with malicious swap data.
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WBTC);
        uint256 amount = 500_000e6;
        bytes memory params = abi.encode(path, amount, 0);

        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(SwapRouter.SwapRouter__AssetOutMisMatch.selector, address(WBTC), address(WETH))
            )
        );
        badCellar.rebalance(address(USDC), address(WETH), amount, SwapRouter.Exchange.UNIV2, params);
    }

    function testAllFeesToStrategist(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the
        // order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);

        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setStrategistPerformanceCut(1e18);
        cellar.setStrategistPlatformCut(1e18);

        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            ,

        ) = cellar.feeData();

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        deal(address(USDC), address(cosmos), 0);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        uint256 totalAssetsBeforeSendFees = USDC.balanceOf(address(cellar)) + yield;
        deal(address(USDC), address(cellar), totalAssetsBeforeSendFees);

        // Call `sendFees` to calculate pending performance and platform fees,
        // and distribute them to strategist, and Cosmos.
        cellar.sendFees();

        uint256 expectedPerformanceFees = yield.mulDivDown(performanceFee, 1e18);

        // Minting platform fees dilutes share price, so it also dilutes pending performance fees.
        uint256 expectedPerformanceFeesAdjustedForDilution = (expectedPerformanceFees *
            (1e18 - (platformFee * timePassed) / 365 days)) / 1e18;

        uint256 expectedPlatformFees = ((deposit + yield) * platformFee * timePassed) / (365 days * 1e18);

        uint256 expectedTotalFeesAdjustedForDilution = expectedPerformanceFeesAdjustedForDilution +
            expectedPlatformFees;

        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedTotalFeesAdjustedForDilution,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected total fees after dilution."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPlatformFees.mulWadDown(strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(strategistPerformanceCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut) + (total performance fees * strategist performance cut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPlatformFees.mulWadDown(1e18 - strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(1e18 - strategistPerformanceCut),
            2,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut)) + (total performance fees * (1-strategist performance cut))."
        );

        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have burned all fee shares.");

        uint256 expectedHighWatermark = totalAssetsBeforeSendFees - feesInAssetsSentToCosmos;

        (uint256 highWatermarkAfterSendFees, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterSendFees,
            expectedHighWatermark,
            "High watermark should equal high watermark before send fees minus assets sent to Cosmos."
        );

        vm.startPrank(strategist);
        cellar.redeem(cellar.balanceOf(strategist), strategist, strategist);
        vm.stopPrank();
    }

    function testAllFeesToPlatform(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the
        // order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);

        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setStrategistPerformanceCut(0);
        cellar.setStrategistPlatformCut(0);

        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            ,

        ) = cellar.feeData();

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        deal(address(USDC), address(cosmos), 0);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        uint256 totalAssetsBeforeSendFees = USDC.balanceOf(address(cellar)) + yield;
        deal(address(USDC), address(cellar), totalAssetsBeforeSendFees);

        // Call `sendFees` to calculate pending performance and platform fees,
        // and distribute them to strategist, and Cosmos.
        cellar.sendFees();

        uint256 expectedPerformanceFees = yield.mulDivDown(performanceFee, 1e18);

        // Minting platform fees dilutes share price, so it also dilutes pending
        // performance fees.
        uint256 expectedPerformanceFeesAdjustedForDilution = (expectedPerformanceFees *
            (1e18 - (platformFee * timePassed) / 365 days)) / 1e18;

        uint256 expectedPlatformFees = ((deposit + yield) * platformFee * timePassed) / (365 days * 1e18);

        uint256 expectedTotalFeesAdjustedForDilution = expectedPerformanceFeesAdjustedForDilution +
            expectedPlatformFees;

        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedTotalFeesAdjustedForDilution,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected total fees after dilution."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPlatformFees.mulWadDown(strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(strategistPerformanceCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut) + (total performance fees * strategist performance cut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPlatformFees.mulWadDown(1e18 - strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(1e18 - strategistPerformanceCut),
            2,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut)) + (total performance fees * (1-strategist performance cut))."
        );

        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have burned all fee shares.");

        uint256 expectedHighWatermark = totalAssetsBeforeSendFees - feesInAssetsSentToCosmos;

        (uint256 highWatermarkAfterSendFees, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterSendFees,
            expectedHighWatermark,
            "High watermark should equal high watermark before send fees minus assets sent to Cosmos."
        );
    }

    function testPerformanceFeesToStrategistPlatformFeesToPlatform(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the
        // order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);

        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setStrategistPerformanceCut(1e18);
        cellar.setStrategistPlatformCut(0);

        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            ,

        ) = cellar.feeData();

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        deal(address(USDC), address(cosmos), 0);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        uint256 totalAssetsBeforeSendFees = USDC.balanceOf(address(cellar)) + yield;
        deal(address(USDC), address(cellar), totalAssetsBeforeSendFees);

        // Call `sendFees` to calculate pending performance and platform fees,
        // and distribute them to strategist, and Cosmos.
        cellar.sendFees();

        uint256 expectedPerformanceFees = yield.mulDivDown(performanceFee, 1e18);

        // Minting platform fees dilutes share price, so it also dilutes pending performance fees.
        uint256 expectedPerformanceFeesAdjustedForDilution = (expectedPerformanceFees *
            (1e18 - (platformFee * timePassed) / 365 days)) / 1e18;

        uint256 expectedPlatformFees = ((deposit + yield) * platformFee * timePassed) / (365 days * 1e18);

        uint256 expectedTotalFeesAdjustedForDilution = expectedPerformanceFeesAdjustedForDilution +
            expectedPlatformFees;

        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedTotalFeesAdjustedForDilution,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected total fees after dilution."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPlatformFees.mulWadDown(strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(strategistPerformanceCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut) + (total performance fees * strategist performance cut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPlatformFees.mulWadDown(1e18 - strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(1e18 - strategistPerformanceCut),
            2,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut)) + (total performance fees * (1-strategist performance cut))."
        );

        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have burned all fee shares.");

        uint256 expectedHighWatermark = totalAssetsBeforeSendFees - feesInAssetsSentToCosmos;

        (uint256 highWatermarkAfterSendFees, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterSendFees,
            expectedHighWatermark,
            "High watermark should equal high watermark before send fees minus assets sent to Cosmos."
        );

        vm.startPrank(strategist);
        cellar.redeem(cellar.balanceOf(strategist), strategist, strategist);
        vm.stopPrank();
    }

    function testPlatformFeesToStrategistPerformanceFeesToPlatform(
        uint256 timePassed,
        uint256 deposit,
        uint256 yield
    ) external {
        // Cap time passed to 1 year. Platform fees will be collected on the
        // order of weeks possibly months.
        timePassed = bound(timePassed, 1 days, 365 days);
        deposit = bound(deposit, 100e6, 1_000_000_000e6);

        // Cap yield to 10,000% APR
        {
            uint256 yieldUpperBound = (100 * deposit * timePassed) / 365 days;
            // Floor yield above 0.01% APR
            uint256 yieldLowerBound = ((deposit * timePassed) / 365 days) / 10_000;
            yield = bound(yield, yieldLowerBound, yieldUpperBound);
        }

        cellar.setStrategistPerformanceCut(0);
        cellar.setStrategistPlatformCut(1e18);

        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            ,

        ) = cellar.feeData();

        // Give this address enough USDC to cover deposits.
        deal(address(USDC), address(this), deposit);

        deal(address(USDC), address(cosmos), 0);

        // Deposit into cellar.
        cellar.deposit(deposit, address(this));

        // Advance time by `timePassed` seconds.
        skip(timePassed);

        // Simulate Cellar earning yield.
        uint256 totalAssetsBeforeSendFees = USDC.balanceOf(address(cellar)) + yield;
        deal(address(USDC), address(cellar), totalAssetsBeforeSendFees);

        // Call `sendFees` to calculate pending performance and platform fees,
        // and distribute them to strategist, and Cosmos.
        cellar.sendFees();

        uint256 expectedPerformanceFees = yield.mulDivDown(performanceFee, 1e18);

        // Minting platform fees dilutes share price, so it also dilutes pending performance fees.
        uint256 expectedPerformanceFeesAdjustedForDilution = (expectedPerformanceFees *
            (1e18 - (platformFee * timePassed) / 365 days)) / 1e18;

        uint256 expectedPlatformFees = ((deposit + yield) * platformFee * timePassed) / (365 days * 1e18);

        uint256 expectedTotalFeesAdjustedForDilution = expectedPerformanceFeesAdjustedForDilution +
            expectedPlatformFees;

        uint256 feesInAssetsSentToCosmos = USDC.balanceOf(cosmos);
        uint256 feesInAssetsSentToStrategist = cellar.previewRedeem(cellar.balanceOf(strategist));

        assertApproxEqAbs(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedTotalFeesAdjustedForDilution,
            2,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected total fees after dilution."
        );

        assertApproxEqAbs(
            feesInAssetsSentToStrategist,
            expectedPlatformFees.mulWadDown(strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(strategistPerformanceCut),
            2,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut) + (total performance fees * strategist performance cut)."
        );

        assertApproxEqAbs(
            feesInAssetsSentToCosmos,
            expectedPlatformFees.mulWadDown(1e18 - strategistPlatformCut) +
                expectedPerformanceFeesAdjustedForDilution.mulWadDown(1e18 - strategistPerformanceCut),
            2,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut)) + (total performance fees * (1-strategist performance cut))."
        );

        assertEq(cellar.balanceOf(address(cellar)), 0, "Cellar should have burned all fee shares.");

        uint256 expectedHighWatermark = totalAssetsBeforeSendFees - feesInAssetsSentToCosmos;

        (uint256 highWatermarkAfterSendFees, , , , , , ) = cellar.feeData();

        assertEq(
            highWatermarkAfterSendFees,
            expectedHighWatermark,
            "High watermark should equal high watermark before send fees minus assets sent to Cosmos."
        );

        vm.startPrank(strategist);
        cellar.redeem(cellar.balanceOf(strategist), strategist, strategist);
        vm.stopPrank();
    }

    // ======================================== INTEGRATION TESTS ========================================

    function testCellarWithCellarPositions() external {
        // Cellar A's asset is USDC, holding position is Cellar B shares, whose holding asset is USDC.
        // Initialize test Cellars.
        MockCellar cellarA;
        MockCellar cellarB;

        address[] memory positions = new address[](1);
        positions[0] = address(USDC);

        Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](1);
        positionTypes[0] = Cellar.PositionType.ERC20;

        cellarB = new MockCellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.ORDERLY,
            "Ultimate Stablecoin cellar",
            "USC-CLR",
            strategist
        );

        stdstore.target(address(cellarB)).sig(cellarB.shareLockPeriod.selector).checked_write(uint256(0));

        positions[0] = address(cellarB);

        positionTypes[0] = Cellar.PositionType.Cellar;

        cellarA = new MockCellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(cellarB),
            Cellar.WithdrawType.ORDERLY,
            "Stablecoin cellar",
            "SC-CLR",
            strategist
        );

        stdstore.target(address(cellarA)).sig(cellarA.shareLockPeriod.selector).checked_write(uint256(0));

        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(cellarA), assets);
        cellarA.deposit(assets, address(this));

        uint256 withdrawAmount = cellarA.maxWithdraw(address(this));
        assertEq(assets, withdrawAmount, "Assets should not have changed.");
        assertEq(cellarA.totalAssets(), cellarB.totalAssets(), "Total assets should be the same.");

        cellarA.withdraw(withdrawAmount, address(this), address(this));
    }

    uint256 public saltIndex;

    /**
     * @notice Generates a random number between 1 and 1e9.
     */
    function _mutate(uint256 salt) internal returns (uint256) {
        saltIndex++;
        uint256 random = uint256(keccak256(abi.encode(salt, saltIndex)));
        random = bound(random, 1, 1_000_000_000);
        return random;
    }

    function _changeMarketPrices(ERC20[] memory assetsToAdjust, uint256[] memory newPricesInUSD) internal {
        uint256 quoteIndex;
        uint256 exchangeRate;
        for (uint256 i = 0; i < assetsToAdjust.length; i++) {
            for (uint256 j = 1; j < assetsToAdjust.length; j++) {
                quoteIndex = i + j;
                if (quoteIndex >= assetsToAdjust.length) quoteIndex -= assetsToAdjust.length;
                exchangeRate = (10**assetsToAdjust[quoteIndex].decimals()).mulDivDown(
                    newPricesInUSD[i],
                    newPricesInUSD[quoteIndex]
                );
                priceRouter.setExchangeRate(assetsToAdjust[i], assetsToAdjust[quoteIndex], exchangeRate);
            }
        }
    }

    enum Action {
        DEPOSIT,
        MINT,
        WITHDRAW,
        REDEEM
    }

    /**
     * @notice Helper function that performs 1 of 4 user actions.
     *         Validates that the preview function returns the same as the actual function.
     * @param target Cellar to work with.
     * @param user Address that is performing the action.
     * @param action Enum dictating what `Action` is performed.
     * @param amountOfAssets to deposit/withdraw to/from the cellar.
      @param amountOfShares to mint/redeem to/from the cellar.
     */
    function _userAction(
        Cellar target,
        address user,
        Action action,
        uint256 amountOfAssets,
        uint256 amountOfShares
    ) internal returns (uint256 assets, uint256 shares) {
        vm.startPrank(user);
        if (action == Action.DEPOSIT) {
            assets = amountOfAssets;
            assertApproxEqAbs(
                target.previewDeposit(amountOfAssets),
                shares = target.deposit(amountOfAssets, user),
                300, // When the amount being deposited is much larger than the TVL, because of how the preview deposit function works, there is much worse precision.
                "Deposit should be equal to previewDeposit"
            );
        } else if (action == Action.WITHDRAW) {
            assets = amountOfAssets;
            assertApproxEqAbs(
                target.previewWithdraw(amountOfAssets),
                shares = target.withdraw(amountOfAssets, user, user),
                10,
                "Withdraw should be equal to previewWithdraw"
            );
        } else if (action == Action.MINT) {
            shares = amountOfShares;
            assertApproxEqAbs(
                target.previewMint(amountOfShares),
                assets = target.mint(amountOfShares, user),
                10,
                "Mint should be equal to previewMint"
            );
        } else if (action == Action.REDEEM) {
            shares = amountOfShares;
            assertApproxEqAbs(
                target.previewRedeem(amountOfShares),
                assets = target.redeem(amountOfShares, user, user),
                10,
                "Redeem should be equal to previewRedeem"
            );
        }
        vm.stopPrank();
    }

    /**
     * @notice Helper function that calls `rebalance` for a cellar.
     * @param target Cellar to call `rebalance` on.
     * @param from Token to sell.
     * @param to Token to buy.
     * @param amount The amount of `from` token to sell.
     */
    function _rebalance(
        Cellar target,
        ERC20 from,
        ERC20 to,
        uint256 amount
    ) internal returns (uint256 assetsTo) {
        address[] memory path = new address[](2);
        path[0] = address(from);
        path[1] = address(to);

        assetsTo = target.rebalance(
            address(from),
            address(to),
            amount,
            SwapRouter.Exchange.UNIV2, // Using a mock exchange to swap, this param does not matter.
            abi.encode(path, amount, 0, address(target), address(target))
        );
    }

    /**
     * @notice Helper function that calls `sendFees` for a cellar, and validates
     *         performance fees, platform fees, and destination of them.
     * @param target Cellar to call `sendFees` on.
     * @param amountOfTimeToPass How much time should pass before `sendFees` is called.
     * @param yieldEarned The amount of yield earned since performance fees were last minted.
     */
    function _checkSendFees(
        Cellar target,
        uint256 amountOfTimeToPass,
        uint256 yieldEarned
    ) internal {
        skip(amountOfTimeToPass);

        (, , , uint64 platformFee, uint64 performanceFee, , address strategistPayoutAddress) = target.feeData();

        uint256 cellarTotalAssets = target.totalAssets();
        uint256 feesInAssetsSentToCosmos;
        uint256 feesInAssetsSentToStrategist;
        {
            uint256 cosmosFeeInAssetBefore = target.asset().balanceOf(cosmos);
            uint256 strategistFeeSharesBefore = target.balanceOf(strategistPayoutAddress);

            target.sendFees();

            feesInAssetsSentToCosmos = target.asset().balanceOf(cosmos) - cosmosFeeInAssetBefore;
            feesInAssetsSentToStrategist = target.previewRedeem(
                target.balanceOf(strategistPayoutAddress) - strategistFeeSharesBefore
            );
        }
        uint256 expectedPerformanceFeeInAssets;
        uint256 expectedPlatformFeeInAssets;

        // Check if performance fees should have been minted.
        if (yieldEarned > 0) {
            expectedPerformanceFeeInAssets = yieldEarned.mulWadDown(performanceFee);

            // When platform fee shares are minted all shares are diluted in value.
            // Account for share dilution.
            expectedPerformanceFeeInAssets =
                (expectedPerformanceFeeInAssets * ((1e18 - (platformFee * amountOfTimeToPass) / 365 days))) /
                1e18;
        }

        expectedPlatformFeeInAssets = (cellarTotalAssets * platformFee * amountOfTimeToPass) / 1e18 / 365 days;

        assertApproxEqRel(
            feesInAssetsSentToCosmos + feesInAssetsSentToStrategist,
            expectedPerformanceFeeInAssets + expectedPlatformFeeInAssets,
            0.0000001e18,
            "Fees in assets sent to Cosmos + fees in shares sent to strategist should equal the expected total fees after dilution."
        );

        (, uint64 strategistPerformanceCut, uint64 strategistPlatformCut, , , , ) = target.feeData();

        assertApproxEqRel(
            feesInAssetsSentToStrategist,
            expectedPlatformFeeInAssets.mulWadDown(strategistPlatformCut) +
                expectedPerformanceFeeInAssets.mulWadDown(strategistPerformanceCut),
            0.0000001e18,
            "Shares converted to assets sent to strategist should be equal to (total platform fees * strategistPlatformCut) + (total performance fees * strategist performance cut)."
        );
        assertApproxEqRel(
            feesInAssetsSentToCosmos,
            expectedPlatformFeeInAssets.mulWadDown(1e18 - strategistPlatformCut) +
                expectedPerformanceFeeInAssets.mulWadDown(1e18 - strategistPerformanceCut),
            0.0000001e18,
            "Assets sent to Cosmos should be equal to (total platform fees * (1-strategistPlatformCut)) + (total performance fees * (1-strategist performance cut))."
        );
    }

    /**
     * @notice Calculates the minimum assets required to complete sendFees call.
     */
    function previewAssetMinimumsForSendFee(
        Cellar target,
        uint256 amountOfTimeToPass,
        uint256 yieldEarned
    ) public view returns (uint256 assetReq) {
        (
            ,
            uint64 strategistPerformanceCut,
            uint64 strategistPlatformCut,
            uint64 platformFee,
            uint64 performanceFee,
            ,

        ) = target.feeData();

        uint256 expectedPerformanceFeeInAssets;
        uint256 expectedPlatformFeeInAssets;
        uint256 cellarTotalAssets = target.totalAssets();
        // Check if Performance Fees should have been minted.
        if (yieldEarned > 0) {
            expectedPerformanceFeeInAssets = yieldEarned.mulWadDown(performanceFee);
            // When platform fee shares are minted all shares are diluted in value.
            // Account for share dilution.
            expectedPerformanceFeeInAssets =
                (expectedPerformanceFeeInAssets * ((1e18 - (platformFee * amountOfTimeToPass) / 365 days))) /
                1e18;
        }
        expectedPlatformFeeInAssets = (cellarTotalAssets * platformFee * amountOfTimeToPass) / (365 days * 1e18);

        assetReq =
            expectedPlatformFeeInAssets.mulWadDown(1e18 - strategistPlatformCut) +
            expectedPerformanceFeeInAssets.mulWadDown(1e18 - strategistPerformanceCut) +
            // Add an extra asset to account for rounding errors, and insure
            // cellar has enough to cover sendFees.
            10**target.asset().decimals();
    }

    function _ensureEnoughAssetsToCoverSendFees(
        Cellar target,
        uint256 amountOfTimeToPass,
        uint256 yieldEarned,
        ERC20 assetToTakeFrom
    ) internal {
        {
            ERC20 asset = target.asset();
            uint256 assetsReq = previewAssetMinimumsForSendFee(target, amountOfTimeToPass, yieldEarned);
            uint256 cellarAssetBalance = asset.balanceOf(address(target));
            if (assetsReq > cellarAssetBalance) {
                // Mint cellar enough asset to cover sendFees.
                uint256 totalAssets = target.totalAssets();

                // Remove added value from assetToTakeFrom position to preserve totalAssets().
                assetsReq = assetsReq - cellarAssetBalance;
                uint256 remove = priceRouter.getValue(asset, assetsReq, assetToTakeFrom);
                deal(address(assetToTakeFrom), address(target), assetToTakeFrom.balanceOf(address(target)) - remove);

                deal(address(asset), address(target), cellarAssetBalance + totalAssets - target.totalAssets());
                assertEq(totalAssets, target.totalAssets(), "Function should not change the totalAssets.");
            }
        }
    }

    function testMultipleMintDepositRedeemWithdrawWithGainsLossAndSendFees(uint8 salt) external {
        // Initialize users.
        address alice = vm.addr(1);
        address bob = vm.addr(2);
        address sam = vm.addr(3);
        address mary = vm.addr(4);

        // Variable used to pass yield earned to _checkSendFees function.
        uint256 yieldEarned;

        // Initialize test Cellar.
        MockCellar assetManagementCellar;
        {
            // Create new cellar with WETH, USDC, and WBTC positions.
            address[] memory positions = new address[](3);
            positions[0] = address(USDC);
            positions[1] = address(WETH);
            positions[2] = address(WBTC);

            Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](3);
            positionTypes[0] = Cellar.PositionType.ERC20;
            positionTypes[1] = Cellar.PositionType.ERC20;
            positionTypes[2] = Cellar.PositionType.ERC20;

            assetManagementCellar = new MockCellar(
                registry,
                USDC,
                positions,
                positionTypes,
                address(USDC),
                Cellar.WithdrawType.ORDERLY,
                "Asset Management Cellar LP Token",
                "assetmanagement-CLR",
                strategist
            );
        }
        stdstore
            .target(address(assetManagementCellar))
            .sig(assetManagementCellar.shareLockPeriod.selector)
            .checked_write(uint256(0));

        // Update allowed rebalance deviation to work with mock swap router.
        assetManagementCellar.setRebalanceDeviation(0.05e18);

        // Give users USDC to interact with the Cellar.
        deal(address(USDC), alice, type(uint256).max);
        deal(address(USDC), bob, type(uint256).max);
        deal(address(USDC), sam, type(uint256).max);
        deal(address(USDC), mary, type(uint256).max);

        // Approve cellar to send user assets.
        vm.prank(alice);
        USDC.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(bob);
        USDC.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(sam);
        USDC.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(mary);
        USDC.approve(address(assetManagementCellar), type(uint256).max);

        // ====================== BEGIN SCENERIO ======================

        // Users join  cellar, cellar rebalances into WETH and WBTC positions, and sendFees is called.
        {
            uint256 amount = _mutate(salt) * 1e6;
            uint256 shares;
            uint256 assets;

            // Expected high watermark after 3 users each join cellar with `amount` of assets.
            uint256 expectedHighWatermark = amount * 3;

            // Alice joins cellar using deposit.
            (assets, shares) = _userAction(assetManagementCellar, alice, Action.DEPOSIT, amount, 0);
            assertEq(shares, assetManagementCellar.balanceOf(alice), "Alice should have got shares out from deposit.");

            // Bob joins cellar using Mint.
            uint256 bobAssets = USDC.balanceOf(bob);
            (assets, shares) = _userAction(assetManagementCellar, bob, Action.MINT, 0, shares);
            assertEq(
                assets,
                bobAssets - USDC.balanceOf(bob),
                "Bob should have `amount` of assets taken from his address."
            );

            // Sam joins cellar with deposit, withdraws half his assets, then adds them back in using mint.
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.DEPOSIT, amount, 0);
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.WITHDRAW, amount / 2, 0);
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.MINT, 0, shares);

            // High Watermark should be equal to amount * 3 and it should equal total assets.
            uint256 totalAssets = assetManagementCellar.totalAssets();
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(highWatermark, expectedHighWatermark, "High Watermark should equal expectedHighWatermark.");
            assertEq(
                highWatermark,
                totalAssets,
                "High Watermark should equal totalAssets because no yield was earned."
            );
        }
        {
            // Strategy providers swaps into WETH and WBTC using USDC, targeting a 20/40/40 split(USDC/WETH/WBTC).
            uint256 totalAssets = assetManagementCellar.totalAssets();

            // Swap 40% of Cellars USDC for WETH.
            uint256 usdcToSell = totalAssets.mulDivDown(4, 10);
            _rebalance(assetManagementCellar, USDC, WETH, usdcToSell);

            // Swap 40% of Cellars USDC for WBTC.
            _rebalance(assetManagementCellar, USDC, WBTC, usdcToSell);
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, WETH);
        _checkSendFees(assetManagementCellar, 7 days, 0);

        // WBTC price increases enough to create yield, Mary joins the cellar, and sendFees is called.
        {
            uint256 totalAssets = assetManagementCellar.totalAssets();
            uint256 wBTCValueBefore = priceRouter.getValue(WBTC, WBTC.balanceOf(address(assetManagementCellar)), USDC);
            // WBTC price goes up.
            {
                ERC20[] memory assetsToAdjust = new ERC20[](3);
                uint256[] memory prices = new uint256[](3);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                assetsToAdjust[2] = WBTC;
                prices[0] = 1e8;
                prices[1] = 2_000e8;
                prices[2] = 45_000e8;
                _changeMarketPrices(assetsToAdjust, prices);
            }

            uint256 newTotalAssets = assetManagementCellar.totalAssets();

            uint256 wBTCValueAfter = priceRouter.getValue(WBTC, WBTC.balanceOf(address(assetManagementCellar)), USDC);

            yieldEarned = wBTCValueAfter - wBTCValueBefore;

            assertEq(
                newTotalAssets,
                (totalAssets + yieldEarned),
                "totalAssets after price increased by amount of yield earned."
            );
        }
        {
            uint256 amount = _mutate(salt) * 1e6;
            uint256 shares;
            uint256 assets;
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();

            // Mary joins cellar using deposit.
            yieldEarned = assetManagementCellar.totalAssets() - highWatermark;
            (assets, shares) = _userAction(assetManagementCellar, mary, Action.DEPOSIT, amount, 0);
            (highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(
                highWatermark,
                assetManagementCellar.totalAssets(),
                "High watermark should be equal to totalAssets."
            );

            assertTrue(
                assetManagementCellar.balanceOf(address(assetManagementCellar)) > 0,
                "Cellar should have been minted performance fees."
            );
        }
        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, yieldEarned, WETH);
        _checkSendFees(assetManagementCellar, 7 days, yieldEarned);

        // Adjust fee variables, lower WBTC price but raise WETH price enough to
        // create yield, rebalance all positions into WETH, Bob and Sam join
        // cellar, and sendFees is called.
        {
            // Set platform fee to 2%.
            assetManagementCellar.setPlatformFee(0.02e18);

            // Set strategist platform cut to 80%.
            assetManagementCellar.setStrategistPlatformCut(0.8e18);

            // Set performance fee to 0%.
            assetManagementCellar.setPerformanceFee(0.2e18);

            // Set strategist performance cut to 85%.
            assetManagementCellar.setStrategistPerformanceCut(0.85e18);

            // Strategist rebalances all positions to only WETH
            uint256 assetBalanceToRemove = USDC.balanceOf(address(assetManagementCellar));
            _rebalance(assetManagementCellar, USDC, WETH, assetBalanceToRemove);

            assetBalanceToRemove = WBTC.balanceOf(address(assetManagementCellar));
            _rebalance(assetManagementCellar, WBTC, WETH, assetBalanceToRemove);

            // WBTC price goes down. WETH price goes up enough to create yield.
            {
                ERC20[] memory assetsToAdjust = new ERC20[](3);
                uint256[] memory prices = new uint256[](3);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                assetsToAdjust[2] = WBTC;
                prices[0] = 1e8;
                prices[1] = 4_000e8;
                prices[2] = 30_000e8;
                _changeMarketPrices(assetsToAdjust, prices);
            }
        }
        {
            // Bob enters cellar via `mint`.
            uint256 shares = _mutate(salt) * 1e18;
            uint256 totalAssets = assetManagementCellar.totalAssets();
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            yieldEarned = totalAssets - highWatermark;

            deal(address(USDC), bob, type(uint256).max);
            (, shares) = _userAction(assetManagementCellar, bob, Action.MINT, 0, shares);
            deal(address(USDC), bob, 0);
            uint256 feeSharesInCellar = assetManagementCellar.balanceOf(address(assetManagementCellar));
            deal(address(USDC), sam, type(uint256).max);
            (, shares) = _userAction(assetManagementCellar, sam, Action.MINT, 0, shares);
            deal(address(USDC), sam, 0);
            assertEq(
                feeSharesInCellar,
                assetManagementCellar.balanceOf(address(assetManagementCellar)),
                "Performance Fees should not have been minted."
            );

            _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 21 days, yieldEarned, WETH);
            _checkSendFees(assetManagementCellar, 21 days, yieldEarned);
        }

        // No yield was earned, and 28 days pass.
        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 28 days, 0, WETH);
        _checkSendFees(assetManagementCellar, 28 days, 0);

        // WETH price decreases, rebalance cellar so that USDC in Cellar can not
        // cover Alice's redeem. Alice redeems shares, and call sendFees.
        {
            //===== Start Bear Market ====
            // ETH price goes down.
            {
                ERC20[] memory assetsToAdjust = new ERC20[](3);
                uint256[] memory prices = new uint256[](3);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                assetsToAdjust[2] = WBTC;
                prices[0] = 1e8;
                prices[1] = 3_000e8;
                prices[2] = 30_000e8;
                _changeMarketPrices(assetsToAdjust, prices);
            }

            // Cellar has liquidity in USDC and WETH, rebalance cellar so it
            // must take from USDC, and WETH position to cover Alice's redeem.
            uint256 shares = assetManagementCellar.balanceOf(alice);
            uint256 assets = assetManagementCellar.previewRedeem(shares);

            // Manually rebalance Cellar so that it only has 10% of assets needed for Alice's Redeem.
            {
                uint256 targetUSDCBalance = assets / 10;
                uint256 currentUSDCBalance = USDC.balanceOf(address(assetManagementCellar));
                uint256 totalAssets = assetManagementCellar.totalAssets();
                deal(address(USDC), address(assetManagementCellar), 0);
                if (targetUSDCBalance > currentUSDCBalance) {
                    // Need to move assets too USDC.
                    uint256 wethToRemove = priceRouter.getValue(USDC, (targetUSDCBalance - currentUSDCBalance), WETH);
                    deal(
                        address(WETH),
                        address(assetManagementCellar),
                        WETH.balanceOf(address(assetManagementCellar)) - wethToRemove
                    );
                } else if (targetUSDCBalance < currentUSDCBalance) {
                    // Need to move assets from USDC.
                    uint256 wethToAdd = priceRouter.getValue(USDC, (currentUSDCBalance - targetUSDCBalance), WETH);
                    deal(
                        address(WETH),
                        address(assetManagementCellar),
                        WETH.balanceOf(address(assetManagementCellar)) + wethToAdd
                    );
                }
                // Give cellar target USDC Balance such that total assets remains unchanged.
                deal(address(USDC), address(assetManagementCellar), totalAssets - assetManagementCellar.totalAssets());

                assertEq(
                    assetManagementCellar.totalAssets(),
                    totalAssets,
                    "Cellar total assets should not be changed."
                );
            }

            uint256 assetsForShares = assetManagementCellar.convertToAssets(shares);

            // Set Alice's USDC balance to zero to avoid overflow on transfer.
            deal(address(USDC), alice, 0);

            // Alice redeems her shares.
            (assets, shares) = _userAction(assetManagementCellar, alice, Action.REDEEM, 0, shares);
            assertEq(assetsForShares, assets, "Assets out should be worth assetsForShares.");
            assertTrue(USDC.balanceOf(alice) > 0, "Alice should have gotten USDC.");
            assertTrue(WETH.balanceOf(alice) > 0, "Alice should have gotten WETH.");
            assertEq(WBTC.balanceOf(alice), 0, "Alice should not have gotten WBTC.");
            uint256 WETHworth = priceRouter.getValue(WETH, WETH.balanceOf(alice), USDC);
            assertApproxEqAbs(USDC.balanceOf(alice) + WETHworth, assets, 1, "Value of assets out should equal assets.");

            assertTrue(
                assetManagementCellar.balanceOf(address(assetManagementCellar)) == 0,
                "Cellar should have zero performance fees minted."
            );
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, WETH);
        _checkSendFees(assetManagementCellar, 7 days, 0);

        // Alice rejoins cellar, call sendFees.
        {
            // Alice rejoins via mint.
            uint256 sharesToMint = _mutate(salt) * 1e18;
            deal(address(USDC), alice, assetManagementCellar.previewMint(sharesToMint));
            _userAction(assetManagementCellar, alice, Action.MINT, 0, sharesToMint);
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 1 days, 0, WETH);
        _checkSendFees(assetManagementCellar, 1 days, 0);

        // Rebalance cellar to move assets from WETH to WBTC.
        _rebalance(assetManagementCellar, WETH, WBTC, WETH.balanceOf(address(assetManagementCellar)) / 2);

        // Reset high watermark.
        {
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            uint256 totalAssets = assetManagementCellar.totalAssets();
            // Cellar High Watermark is currently above totalAssets, so reset it.
            assertTrue(highWatermark > totalAssets, "High watermark should be greater than total assets in cellar.");
            assetManagementCellar.resetHighWatermark();
            (highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(highWatermark, totalAssets, "Should have reset high watermark to totalAssets.");

            // WBTC goes up a little, USDC depeggs to 0.95.

            ERC20[] memory assetsToAdjust = new ERC20[](3);
            uint256[] memory prices = new uint256[](3);
            assetsToAdjust[0] = USDC;
            assetsToAdjust[1] = WETH;
            assetsToAdjust[2] = WBTC;
            prices[0] = 0.95e8;
            prices[1] = 2_700e8;
            prices[2] = 45_000e8;
            _changeMarketPrices(assetsToAdjust, prices);

            totalAssets = assetManagementCellar.totalAssets();
            assertTrue(totalAssets > highWatermark, "Total Assets should be greater than high watermark.");
            yieldEarned = totalAssets - highWatermark;

            _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 14 days, yieldEarned, WETH);
            _checkSendFees(assetManagementCellar, 14 days, yieldEarned);

            // Strategists trusts LINK, and then adds it as a position.
            // No need to set LINK price since its assets will always be zero.
            priceRouter.supportAsset(LINK);
            assetManagementCellar.trustPosition(address(LINK), Cellar.PositionType.ERC20);
            assetManagementCellar.pushPosition(address(LINK));

            // Swap LINK position with USDC position.
            assetManagementCellar.swapPositions(3, 0);

            // Adjust asset prices such that the cellar's TVL drops below the high watermark.

            assetsToAdjust = new ERC20[](3);
            prices = new uint256[](3);
            assetsToAdjust[0] = USDC;
            assetsToAdjust[1] = WETH;
            assetsToAdjust[2] = WBTC;
            prices[0] = 0.97e8;
            prices[1] = 2_900e8;
            prices[2] = 30_000e8;
            _changeMarketPrices(assetsToAdjust, prices);

            (highWatermark, , , , , , ) = assetManagementCellar.feeData();
            totalAssets = assetManagementCellar.totalAssets();
            assertTrue(totalAssets < highWatermark, "Total Assets should be less than high watermark.");
            _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, WETH);
            _checkSendFees(assetManagementCellar, 7 days, 0);
        }
        {
            // Change price of assets to make manual rebalances easier.
            ERC20[] memory assetsToAdjust = new ERC20[](3);
            uint256[] memory prices = new uint256[](3);
            assetsToAdjust[0] = USDC;
            assetsToAdjust[1] = WETH;
            assetsToAdjust[2] = WBTC;
            prices[0] = 1e8;
            prices[1] = 1_000e8;
            prices[2] = 10_000e8;
            _changeMarketPrices(assetsToAdjust, prices);
        }

        // Have everyone completely exit cellar.
        _userAction(assetManagementCellar, alice, Action.REDEEM, 0, assetManagementCellar.balanceOf(alice));
        _userAction(assetManagementCellar, bob, Action.REDEEM, 0, assetManagementCellar.balanceOf(bob));
        _userAction(assetManagementCellar, sam, Action.REDEEM, 0, assetManagementCellar.balanceOf(sam));

        // Mary has a ton of USDC from the initial deal, zero out her balance so
        // she can redeem her shares.
        deal(address(USDC), mary, 0);
        _userAction(assetManagementCellar, mary, Action.REDEEM, 0, assetManagementCellar.balanceOf(mary));
        _userAction(assetManagementCellar, strategist, Action.REDEEM, 0, assetManagementCellar.balanceOf(strategist));

        assertEq(assetManagementCellar.totalSupply(), 0, "All cellar shares should be burned.");
        assertEq(assetManagementCellar.totalAssets(), 0, "All cellar assets should be removed.");

        //Have everyone join with the same amount of assets.
        uint256 assetsNeeded = _mutate(salt) * 1e6;
        uint256 sharesToJoinWith = assetManagementCellar.convertToShares(assetsNeeded);

        deal(address(USDC), alice, assetsNeeded);
        deal(address(WETH), alice, 0);
        deal(address(WBTC), alice, 0);
        _userAction(assetManagementCellar, alice, Action.DEPOSIT, assetsNeeded, 0);

        deal(address(USDC), bob, assetsNeeded);
        deal(address(WBTC), bob, 0);
        deal(address(WETH), bob, 0);
        _userAction(assetManagementCellar, bob, Action.DEPOSIT, assetsNeeded, 0);

        deal(address(USDC), sam, assetsNeeded);
        deal(address(WBTC), sam, 0);
        deal(address(WETH), sam, 0);
        _userAction(assetManagementCellar, sam, Action.DEPOSIT, assetsNeeded, 0);

        deal(address(USDC), mary, assetsNeeded);
        deal(address(WBTC), mary, 0);
        deal(address(WETH), mary, 0);
        _userAction(assetManagementCellar, mary, Action.DEPOSIT, assetsNeeded, 0);

        // Shutdown the cellar.
        assetManagementCellar.initiateShutdown();

        // At this point we know all 4 cellar users have 25% of the shares each.

        // Manually rebalance assets like so LINK/WETH/WBTC/USDC 0/10/0/90.
        deal(address(LINK), address(assetManagementCellar), 0);
        deal(address(WBTC), address(assetManagementCellar), 0);
        deal(address(USDC), address(assetManagementCellar), (4 * assetsNeeded).mulDivDown(9, 10));
        deal(address(WETH), address(assetManagementCellar), ((4 * assetsNeeded) / 10000).changeDecimals(6, 18));

        // Have Alice exit using withdraw.
        _userAction(assetManagementCellar, alice, Action.WITHDRAW, assetsNeeded, 0);

        // Have Bob exit using redeem.
        _userAction(assetManagementCellar, bob, Action.REDEEM, 0, sharesToJoinWith);

        // Rebalance asses like so LINK/WETH/WBTC/USDC 0/10/45/45
        deal(address(LINK), address(assetManagementCellar), 0);

        // Set WBTC balance in cellar to equal 45% of the cellars total assets.
        deal(address(WBTC), address(assetManagementCellar), ((2 * assetsNeeded * 45) / 1000000).changeDecimals(6, 8));
        deal(address(USDC), address(assetManagementCellar), (2 * assetsNeeded).mulDivDown(1, 10));

        // Set WETH balance in cellar to equal 45% of the cellars total assets.
        deal(address(WETH), address(assetManagementCellar), ((2 * assetsNeeded * 45) / 100000).changeDecimals(6, 18));

        // Change to withdraw in proportion
        assetManagementCellar.setWithdrawType(Cellar.WithdrawType.PROPORTIONAL);

        // Have Sam exit using withdraw.
        _userAction(assetManagementCellar, sam, Action.WITHDRAW, assetsNeeded, 0);

        // Have Mary exit using redeem.
        _userAction(assetManagementCellar, mary, Action.REDEEM, 0, sharesToJoinWith);

        // The total value we expect each user to have after redeeming their shares.
        uint256 expectedValue = assetsNeeded;

        // Alice should have some WETH and USDC.
        {
            uint256 aliceUSDCBalance = USDC.balanceOf(alice);
            uint256 aliceWETHBalance = WETH.balanceOf(alice);

            assertTrue(aliceUSDCBalance > 0, "Alice should have some USDC.");
            assertTrue(aliceWETHBalance > 0, "Alice should have some WETH.");
            assertEq(WBTC.balanceOf(alice), 0, "Alice should have zero WBTC.");
            assertEq(LINK.balanceOf(alice), 0, "Alice should have zero LINK.");

            assertApproxEqAbs(
                aliceUSDCBalance + priceRouter.getValue(WETH, aliceWETHBalance, USDC),
                expectedValue,
                0,
                "Alice's USDC and WETH worth should equal expectedValue."
            );
        }

        // Bob should only have USDC.
        {
            uint256 bobUSDCBalance = USDC.balanceOf(bob);
            uint256 bobWETHBalance = WETH.balanceOf(bob);

            assertTrue(bobUSDCBalance > 0, "Bob should have some USDC.");
            assertEq(bobWETHBalance, 0, "Bob should have zero WETH.");
            assertEq(WBTC.balanceOf(bob), 0, "Bob should have zero WBTC.");
            assertEq(LINK.balanceOf(bob), 0, "Bob should have zero LINK.");

            assertApproxEqAbs(bobUSDCBalance, expectedValue, 0, "Bob's USDC worth should equal expectedValue.");
        }

        //Sam should have USDC, WETH, and WBTC.
        {
            uint256 samUSDCBalance = USDC.balanceOf(sam);
            uint256 samWETHBalance = WETH.balanceOf(sam);
            uint256 samWBTCBalance = WBTC.balanceOf(sam);

            assertTrue(samUSDCBalance > 0, "Sam should have some USDC.");
            assertTrue(samWETHBalance > 0, "Sam should have some WETH.");
            assertTrue(samWBTCBalance > 0, "Sam should have some WBTC.");
            assertEq(LINK.balanceOf(sam), 0, "Sam should have zero LINK.");

            assertApproxEqAbs(
                samUSDCBalance +
                    priceRouter.getValue(WETH, samWETHBalance, USDC) +
                    priceRouter.getValue(WBTC, samWBTCBalance, USDC),
                expectedValue,
                0,
                "Sam's USDC, WETH, and WBTC worth should equal expectedValue."
            );
        }

        //Mary should have USDC, WETH, and WBTC.
        {
            uint256 maryUSDCBalance = USDC.balanceOf(mary);
            uint256 maryWETHBalance = WETH.balanceOf(mary);
            uint256 maryWBTCBalance = WBTC.balanceOf(mary);

            assertTrue(maryUSDCBalance > 0, "Mary should have some USDC.");
            assertTrue(maryWETHBalance > 0, "Mary should have some WETH.");
            assertTrue(maryWBTCBalance > 0, "Mary should have some WBTC.");
            assertEq(LINK.balanceOf(mary), 0, "Mary should have zero LINK.");

            assertApproxEqAbs(
                maryUSDCBalance +
                    priceRouter.getValue(WETH, maryWETHBalance, USDC) +
                    priceRouter.getValue(WBTC, maryWBTCBalance, USDC),
                expectedValue,
                0,
                "Mary's USDC, WETH, and WBTC worth should equal expectedValue."
            );
        }
    }

    function testWETHAsCellarAsset(uint8 salt) external {
        // Initialize users.
        address alice = vm.addr(1);
        address bob = vm.addr(2);
        address sam = vm.addr(3);
        address mary = vm.addr(4);

        // Variable used to pass yield earned to _checkSendFees function.
        uint256 yieldEarned;

        // Initialize test Cellar.
        MockCellar assetManagementCellar;
        {
            // Create new cellar with WETH, USDC, and WBTC positions.
            address[] memory positions = new address[](3);
            positions[0] = address(WETH);
            positions[1] = address(USDC);
            positions[2] = address(WBTC);

            Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](3);
            positionTypes[0] = Cellar.PositionType.ERC20;
            positionTypes[1] = Cellar.PositionType.ERC20;
            positionTypes[2] = Cellar.PositionType.ERC20;

            assetManagementCellar = new MockCellar(
                registry,
                WETH,
                positions,
                positionTypes,
                address(WETH),
                Cellar.WithdrawType.ORDERLY,
                "Asset Management Cellar LP Token",
                "assetmanagement-CLR",
                strategist
            );

            stdstore
                .target(address(assetManagementCellar))
                .sig(assetManagementCellar.shareLockPeriod.selector)
                .checked_write(uint256(0));
        }

        // Update allowed rebalance deviation to work with mock swap router.
        assetManagementCellar.setRebalanceDeviation(0.05e18);

        // Give users WETH to interact with the Cellar.
        deal(address(WETH), alice, type(uint256).max);
        deal(address(WETH), bob, type(uint256).max);
        deal(address(WETH), sam, type(uint256).max);
        deal(address(WETH), mary, type(uint256).max);

        // Approve cellar to send user assets.
        vm.prank(alice);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(bob);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(sam);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(mary);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        // ====================== BEGIN SCENERIO ======================

        // Users join  cellar, cellar rebalances into USDC and WBTC positions,
        // and sendFees is called.
        {
            uint256 amount = (_mutate(salt) * 1e18) / 2000;
            uint256 shares;
            uint256 assets;

            // Expected high watermark after 3 users each join cellar with `amount` of assets.
            uint256 expectedHighWatermark = amount * 3;

            // Alice joins cellar using deposit.
            (assets, shares) = _userAction(assetManagementCellar, alice, Action.DEPOSIT, amount, 0);
            assertEq(shares, assetManagementCellar.balanceOf(alice), "Alice should have got shares out from deposit.");

            // Bob joins cellar using Mint.
            uint256 bobAssets = WETH.balanceOf(bob);
            (assets, shares) = _userAction(assetManagementCellar, bob, Action.MINT, 0, shares);
            assertEq(
                assets,
                bobAssets - WETH.balanceOf(bob),
                "Bob should have `amount` of assets taken from his address."
            );

            // Sam joins cellar with deposit, withdraws half his assets, then adds them back in using mint.
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.DEPOSIT, amount, 0);
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.WITHDRAW, amount / 2, 0);
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.MINT, 0, shares);

            // High Watermark should be equal to amount * 3 and it should equal total assets.
            uint256 totalAssets = assetManagementCellar.totalAssets();
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(highWatermark, expectedHighWatermark, "High Watermark should equal expectedHighWatermark.");
            assertEq(
                highWatermark,
                totalAssets,
                "High Watermark should equal totalAssets because no yield was earned."
            );
        }
        {
            // Strategy providers swaps into USDC and WBTC using WETH, targeting a 20/40/40 split(WETH/USDC/WBTC).
            uint256 totalAssets = assetManagementCellar.totalAssets();

            // Swap 40% of Cellars WETH for USDC.
            uint256 wethToSell = totalAssets.mulDivDown(4, 10);
            _rebalance(assetManagementCellar, WETH, USDC, wethToSell);

            // Swap 40% of Cellars WETH for WBTC.
            _rebalance(assetManagementCellar, WETH, WBTC, wethToSell);
        }
        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, USDC);
        _checkSendFees(assetManagementCellar, 7 days, 0);

        // WBTC price increases enough to create yield, Mary joins the cellar, and sendFees is called.
        {
            uint256 totalAssets = assetManagementCellar.totalAssets();
            uint256 wBTCValueBefore = priceRouter.getValue(WBTC, WBTC.balanceOf(address(assetManagementCellar)), WETH);
            // WBTC price goes up.
            {
                ERC20[] memory assetsToAdjust = new ERC20[](3);
                uint256[] memory prices = new uint256[](3);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                assetsToAdjust[2] = WBTC;
                prices[0] = 1e8;
                prices[1] = 2_000e8;
                prices[2] = 45_000e8;
                _changeMarketPrices(assetsToAdjust, prices);
            }

            uint256 newTotalAssets = assetManagementCellar.totalAssets();

            uint256 wBTCValueAfter = priceRouter.getValue(WBTC, WBTC.balanceOf(address(assetManagementCellar)), WETH);

            yieldEarned = wBTCValueAfter - wBTCValueBefore;

            assertEq(
                newTotalAssets,
                (totalAssets + yieldEarned),
                "totalAssets after price increased by amount of yield earned."
            );
        }
        {
            uint256 amount = (_mutate(salt) * 1e18) / 2000;
            uint256 shares;
            uint256 assets;
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();

            // Mary joins cellar using deposit.
            yieldEarned = assetManagementCellar.totalAssets() - highWatermark;
            (assets, shares) = _userAction(assetManagementCellar, mary, Action.DEPOSIT, amount, 0);
            (highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(
                highWatermark,
                assetManagementCellar.totalAssets(),
                "High watermark should be equal to totalAssets."
            );

            assertTrue(
                assetManagementCellar.balanceOf(address(assetManagementCellar)) > 0,
                "Cellar should have been minted performance fees."
            );
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 0 days, yieldEarned, USDC);
        _checkSendFees(assetManagementCellar, 7 days, yieldEarned);

        // Adjust fee variables, lower WETH price but raise WBTC price enough to
        // create yield, rebalance all positions into WBTC, Bob and Sam join
        // cellar, and sendFees is called.
        {
            // Set platform fee to 2%.
            assetManagementCellar.setPlatformFee(0.02e18);

            // Set strategist platform cut to 80%.
            assetManagementCellar.setStrategistPlatformCut(0.8e18);

            // Set performance fee to 0%.
            assetManagementCellar.setPerformanceFee(0.2e18);

            // Set strategist performance cut to 85%.
            assetManagementCellar.setStrategistPerformanceCut(0.85e18);

            // Strategist rebalances all positions to only WBTC
            uint256 assetBalanceToRemove = USDC.balanceOf(address(assetManagementCellar));
            _rebalance(assetManagementCellar, USDC, WBTC, assetBalanceToRemove);

            assetBalanceToRemove = WETH.balanceOf(address(assetManagementCellar));
            _rebalance(assetManagementCellar, WETH, WBTC, assetBalanceToRemove);

            // WETH price goes down. WBTC price goes up enough to create yield.
            {
                uint256 totalAssets = assetManagementCellar.totalAssets();
                ERC20[] memory assetsToAdjust = new ERC20[](3);
                uint256[] memory prices = new uint256[](3);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                assetsToAdjust[2] = WBTC;
                prices[0] = 1e8;
                prices[1] = 1_500e8;
                prices[2] = 50_000e8;
                _changeMarketPrices(assetsToAdjust, prices);
                totalAssets = assetManagementCellar.totalAssets();
            }
        }

        {
            // Bob enters cellar via `mint`.
            uint256 shares = (_mutate(salt) * 1e18) / 2000;
            uint256 totalAssets = assetManagementCellar.totalAssets();
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            yieldEarned = totalAssets - highWatermark;

            deal(address(WETH), bob, type(uint256).max);
            (, shares) = _userAction(assetManagementCellar, bob, Action.MINT, 0, shares);
            deal(address(WETH), bob, 0);
            uint256 feeSharesInCellar = assetManagementCellar.balanceOf(address(assetManagementCellar));
            deal(address(WETH), sam, type(uint256).max);
            (, shares) = _userAction(assetManagementCellar, sam, Action.MINT, 0, shares);
            deal(address(WETH), sam, 0);
            assertEq(
                feeSharesInCellar,
                assetManagementCellar.balanceOf(address(assetManagementCellar)),
                "Performance Fees should not have been minted."
            );

            _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 21 days, yieldEarned, WBTC);
            _checkSendFees(assetManagementCellar, 21 days, yieldEarned);
        }

        // No yield was earned, and 28 days pass.
        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 28 days, 0, WBTC);
        _checkSendFees(assetManagementCellar, 28 days, 0);

        // WBTC price decreases, rebalance cellar so that WETH in Cellar can not
        // cover Alice's redeem. Alice redeems shares, and call sendFees.
        {
            //===== Start Bear Market ====
            // WBTC price goes down.
            {
                ERC20[] memory assetsToAdjust = new ERC20[](3);
                uint256[] memory prices = new uint256[](3);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                assetsToAdjust[2] = WBTC;
                prices[0] = 1e8;
                prices[1] = 1_500e8;
                prices[2] = 30_000e8;
                _changeMarketPrices(assetsToAdjust, prices);
            }

            // Cellar has liquidity in WBTC and WETH, rebalance cellar so it
            // must take from USDC, and WETH position to cover Alice's redeem.
            uint256 shares = assetManagementCellar.balanceOf(alice);
            uint256 assets = assetManagementCellar.previewRedeem(shares);

            // Manually rebalance Cellar so that it only has 10% of assets needed for Alice's Redeem.
            {
                uint256 targetWETHBalance = assets / 10;
                uint256 currentWETHBalance = WETH.balanceOf(address(assetManagementCellar));
                uint256 totalAssets = assetManagementCellar.totalAssets();
                deal(address(WETH), address(assetManagementCellar), 0);
                if (targetWETHBalance > currentWETHBalance) {
                    // Need to move assets too WETH.
                    uint256 wbtcToRemove = priceRouter.getValue(WETH, (targetWETHBalance - currentWETHBalance), WBTC);
                    deal(
                        address(WBTC),
                        address(assetManagementCellar),
                        WBTC.balanceOf(address(assetManagementCellar)) - wbtcToRemove
                    );
                } else if (targetWETHBalance < currentWETHBalance) {
                    //Need to move assets from WETH.
                    uint256 wbtcToAdd = priceRouter.getValue(WETH, (currentWETHBalance - targetWETHBalance), WBTC);
                    deal(
                        address(WBTC),
                        address(assetManagementCellar),
                        WBTC.balanceOf(address(assetManagementCellar)) + wbtcToAdd
                    );
                }
                // Give cellar target WETH Balance such that total assets remains unchanged.
                deal(address(WETH), address(assetManagementCellar), totalAssets - assetManagementCellar.totalAssets());

                assertEq(
                    assetManagementCellar.totalAssets(),
                    totalAssets,
                    "Cellar total assets should not be changed."
                );
            }

            uint256 assetsForShares = assetManagementCellar.convertToAssets(shares);

            // Set Alice's WETH balance to zero to avoid overflow on transfer.
            deal(address(WETH), alice, 0);

            // Alice redeems her shares.
            (assets, shares) = _userAction(assetManagementCellar, alice, Action.REDEEM, 0, shares);
            assertEq(assetsForShares, assets, "Assets out should be worth assetsForShares.");
            assertTrue(WBTC.balanceOf(alice) > 0, "Alice should have gotten WBTC.");
            assertTrue(WETH.balanceOf(alice) > 0, "Alice should have gotten WETH.");
            assertEq(USDC.balanceOf(alice), 0, "Alice should not have gotten USDC.");
            uint256 WBTCworth = priceRouter.getValue(WBTC, WBTC.balanceOf(alice), WETH);
            assertApproxEqRel(
                WETH.balanceOf(alice) + WBTCworth,
                assets,
                0.00000001e18,
                "Value of assets out should approximately equal assets."
            );

            assertTrue(
                assetManagementCellar.balanceOf(address(assetManagementCellar)) == 0,
                "Cellar should have zero performance fees minted."
            );
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, WBTC);
        _checkSendFees(assetManagementCellar, 7 days, 0);

        // Alice rejoins cellar, call sendFees.
        {
            // Alice rejoins via mint.
            uint256 sharesToMint = _mutate(salt) * 1e18;
            deal(address(WETH), alice, assetManagementCellar.previewMint(sharesToMint));
            _userAction(assetManagementCellar, alice, Action.MINT, 0, sharesToMint);
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 1 days, 0, WBTC);
        _checkSendFees(assetManagementCellar, 1 days, 0);

        // Rebalance cellar to move assets from WETH to WBTC.
        _rebalance(assetManagementCellar, WBTC, USDC, WBTC.balanceOf(address(assetManagementCellar)) / 2);

        // Reset high watermark.
        {
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            uint256 totalAssets = assetManagementCellar.totalAssets();
            // Cellar High Watermark is currently above totalAssets, so reset it.
            assertTrue(highWatermark > totalAssets, "High watermark should be greater than total assets in cellar.");
            assetManagementCellar.resetHighWatermark();
            (highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(highWatermark, totalAssets, "Should have reset high watermark to totalAssets.");

            // WBTC goes up a little, USDC depeggs to 1.05.

            ERC20[] memory assetsToAdjust = new ERC20[](3);
            uint256[] memory prices = new uint256[](3);
            assetsToAdjust[0] = USDC;
            assetsToAdjust[1] = WETH;
            assetsToAdjust[2] = WBTC;
            prices[0] = 1.05e8;
            prices[1] = 1_000e8;
            prices[2] = 45_000e8;
            _changeMarketPrices(assetsToAdjust, prices);

            totalAssets = assetManagementCellar.totalAssets();
            assertTrue(totalAssets > highWatermark, "Total Assets should be greater than high watermark.");
            yieldEarned = totalAssets - highWatermark;

            _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 14 days, yieldEarned, WBTC);
            _checkSendFees(assetManagementCellar, 14 days, yieldEarned);
        }
    }

    function testDepeggedAssetNotUsedByCellar() external {
        // Scenario 1: Depegged asset is not being used by the cellar.
        // Governance can remove it itself by calling `distrustPosition`.

        // Add asset that will be depegged.
        priceRouter.supportAsset(USDT);
        cellar.trustPosition(address(USDT), Cellar.PositionType.ERC20);
        cellar.pushPosition(address(USDT));
        priceRouter.setExchangeRate(USDT, USDC, 1e6);
        priceRouter.setExchangeRate(USDC, USDT, 1e6);

        deal(address(USDC), address(this), 200e6);
        cellar.deposit(100e6, address(this));

        // USDT depeggs to $0.90.
        priceRouter.setExchangeRate(USDT, USDC, 0.9e6);
        priceRouter.setExchangeRate(USDC, USDT, 1.111111e6);

        assertEq(cellar.totalAssets(), 100e6, "Cellar total assets should remain unchanged.");
        assertEq(cellar.deposit(100e6, address(this)), 100e18, "Cellar share price should not change.");
    }

    function testDepeggedAssetUsedByTheCellar() external {
        // Scenario 2: Depegged asset is being used by the cellar. Governance
        // uses multicall to rebalance cellar out of position, and to distrust
        // it.

        // Add asset that will be depegged.
        priceRouter.supportAsset(USDT);
        cellar.trustPosition(address(USDT), Cellar.PositionType.ERC20);
        cellar.pushPosition(address(USDT));
        priceRouter.setExchangeRate(USDT, USDC, 1e6);
        priceRouter.setExchangeRate(USDC, USDT, 1e6);

        deal(address(USDC), address(this), 200e6);
        cellar.deposit(100e6, address(this));

        //Change Cellar holdings manually to 50/50 USDC/USDT.
        deal(address(USDC), address(cellar), 50e6);
        deal(address(USDT), address(cellar), 50e6);

        // USDT depeggs to $0.90.
        priceRouter.setExchangeRate(USDT, USDC, 0.9e6);
        priceRouter.setExchangeRate(USDC, USDT, 1.111111e6);

        assertEq(cellar.totalAssets(), 95e6, "Cellar total assets should have gone down.");
        assertGt(cellar.deposit(100e6, address(this)), 100e18, "Cellar share price should have decreased.");

        // Governance votes to rebalance out of USDT, and distrust USDT.
        // Manually rebalance into USDC.
        deal(address(USDC), address(cellar), 95e6);
        deal(address(USDT), address(cellar), 0);
    }

    function testDepeggedHoldingPosition() external {
        // Scenario 3: Depegged asset is being used by the cellar, and it is the
        // holding position. Governance uses multicall to rebalance cellar out
        // of position, set a new holding position, and distrust it.

        cellar.setHoldingPosition(address(usdcCLR));

        // Rebalance into usdcCLR. No swap is made because both positions use
        // USDC.
        deal(address(USDC), address(this), 200e6);
        cellar.deposit(100e6, address(this));
        cellar.rebalance(address(usdcCLR), address(USDC), 50e6, SwapRouter.Exchange.UNIV2, abi.encode(0));

        // usdcCLR depeggs from USDC
        deal(address(USDC), address(usdcCLR), 45e6);

        assertEq(cellar.totalAssets(), 95e6, "Cellar total assets should have gone down.");
        assertGt(cellar.deposit(100e6, address(this)), 100e18, "Cellar share price should have decreased.");

        // Governance votes to rebalance out of usdcCLR, change the holding
        // position, and distrust usdcCLR. No swap is made because both
        // positions use USDC.
        cellar.rebalance(
            address(usdcCLR),
            address(USDC),
            usdcCLR.maxWithdraw(address(cellar)),
            SwapRouter.Exchange.UNIV2,
            abi.encode(0)
        );
        cellar.setHoldingPosition(address(USDC));
    }

    function testDepeggedCellarAsset() external {
        // Scenario 4: Depegged asset is the cellars asset. Worst case
        // scenario, rebalance out of position into some new stable position,
        // set fees to zero, initiate a shutdown, and have users withdraw funds
        // asap. Want to ensure that attackers can not join using the depegged
        // asset. Emergency governance proposal to move funds into some new
        // safety contract, shutdown old cellar, and allow users to withdraw
        // from the safety contract.
        priceRouter.supportAsset(USDT);
        cellar.trustPosition(address(USDT), Cellar.PositionType.ERC20);
        cellar.pushPosition(address(USDT));
        priceRouter.setExchangeRate(USDT, USDC, 1e6);
        priceRouter.setExchangeRate(USDC, USDT, 1e6);

        deal(address(USDC), address(this), 100e6);
        cellar.deposit(100e6, address(this));

        // USDC depeggs to $0.90.
        priceRouter.setExchangeRate(USDC, USDT, 0.9e6);
        priceRouter.setExchangeRate(USDT, USDC, 1.111111e6);

        assertEq(cellar.totalAssets(), 100e6, "Cellar total assets should remain unchanged.");

        // Governance rebalances to USDT, sets performance and platform fees to
        // zero, initiates a shutdown, and has users withdraw their funds.
        // Manually rebalance to USDT.
        deal(address(USDC), address(cellar), 0);
        deal(address(USDT), address(cellar), 90e6);

        // Important to set fees to zero, else performance fees are minted as
        // the cellars asset depeggs further.
        cellar.setPerformanceFee(0);
        cellar.setPlatformFee(0);
        cellar.initiateShutdown();

        // Attacker tries to join with depegged asset.
        address attacker = vm.addr(34534);
        deal(address(USDC), attacker, 1);
        vm.startPrank(attacker);
        USDC.approve(address(cellar), 1);
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ContractShutdown.selector)));
        cellar.deposit(1, attacker);
        vm.stopPrank();

        cellar.redeem(50e18, address(this), address(this));

        // USDC depeggs to $0.10.
        priceRouter.setExchangeRate(USDC, USDT, 0.1e6);
        priceRouter.setExchangeRate(USDT, USDC, 10e6);

        cellar.redeem(50e18, address(this), address(this));

        // Eventhough USDC depegged further, cellar rebalanced out of USDC
        // removing its exposure to it.  So users can expect to get the
        // remaining value out of the cellar.
        assertEq(
            USDT.balanceOf(address(this)),
            90e6,
            "Withdraws should total the amount of USDT in the cellar after rebalance."
        );

        // Governance can not distrust USDC, because it is the holding position,
        // and changing the holding position is pointless because the asset of
        // the new holding position must be USDC.  Therefore the cellar is lost,
        // and should be exitted completely.
    }

    /**
     * Some notes about the above tests:
     * It will be difficult for Governance to set some safe min asset amount
     * when rebalancing a cellar from a depegging asset. Ideally this would be
     * done by the strategist, but even then if the price is volatile enough,
     * strategists might not be able to set a fair min amount out value. We
     * might be able to use Chainlink price feeds to get around this, and rely
     * on the Chainlink oracle data in order to calculate a fair min amount out
     * on chain.
     *
     * Users will be able to exit the cellar as long as the depegged asset is
     * still within its price envelope defined in the price router as minPrice
     * and maxPrice. Once an asset is outside this envelope, or Chainlink stops
     * reporting pricing data, the situation becomes difficult. Any calls
     * involving `totalAssets()` will fail because the price router will not be
     * able to get a safe price for the depegged asset. With this in mind we
     * should consider creating some emergency fund protector contract, where in
     * the event a violent depegging occurs, Governance can vote to trust the
     * fund protector contract as a position, and all the cellars assets can be
     * converted into some safe asset then deposited into the fund protector
     * contract. Doing this decouples the depegged asset pricing data from
     * assets in the cellar. In order to get their funds out users would go to
     * the fund protector contract, and trade their shares (from the depegged
     * cellar) for assets in the fund protector.
     */

    // ========================================= GRAVITY FUNCTIONS =========================================

    // Since this contract is set as the Gravity Bridge, this will be called by
    // the Cellar's `sendFees` function to send funds Cosmos.
    function sendToCosmos(
        address asset,
        bytes32,
        uint256 assets
    ) external {
        ERC20(asset).transferFrom(msg.sender, cosmos, assets);
    }

    // ========================================= MACRO FINDINGS =========================================

    // H-1 done.

    // H-2 NA, cellars will not increase their TVL during rebalance calls.
    // In future versions this will be fixed by having all yield converted into the cellar's accounting asset, then put into a vestedERC20 contract which gradually releases rewards to the cellar.

    // M-1
    function testMaliciousStrategistFundsLocked() external {
        LockedERC4626 maliciousCellar = new LockedERC4626(USDC, "Bad Cellar", "BC", 1e18);

        cellar.trustPosition(address(maliciousCellar), Cellar.PositionType.ERC4626);
        cellar.pushPosition(address(maliciousCellar));

        // Deposit into cellar.
        uint256 assets = 10000e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(maliciousCellar), assets);
        cellar.deposit(assets, address(this));

        uint256 totalAssetsBefore = cellar.totalAssets();

        // Rebalance USDC deposit into maliciousCellar.
        cellar.rebalance(address(USDC), address(maliciousCellar), 1e6, SwapRouter.Exchange.UNIV2, abi.encode(0));

        uint256 totalAssetsAfter = cellar.totalAssets();
        // Eventhough withdrawable amount is assets -1, totalAssets should not change from rebalance.
        assertEq(totalAssetsAfter, totalAssetsBefore, "Total assets should not change from rebalance call.");

        // Strategist changes cellar withdrawType to proportional.
        cellar.setWithdrawType(Cellar.WithdrawType.PROPORTIONAL);

        // Strategist has effectively blocked all withdrawals because of chaning withdraw type to proportional.
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Cellar.Cellar__IlliquidWithdraw.selector, address(maliciousCellar)))
        );
        cellar.withdraw(1e6, address(this), address(this));

        // If a strategist is maliciously doing this, the best bet would be to remove them from power and change the withdraw type back to in order.
        // In addition new strategist might be able to unlock locked funds.
        cellar.setWithdrawType(Cellar.WithdrawType.ORDERLY);

        // User still can not withdraw all assets since some of them are still locked.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__IncompleteWithdraw.selector, 1e6)));
        cellar.withdraw(assets, address(this), address(this));

        // User can withdraw all their assets except for assets locked.
        cellar.withdraw(assets - 1e6, address(this), address(this));
    }

    function createCellarWithLockedFunds(uint256 assets)
        internal
        returns (
            MockCellar,
            LockedERC4626,
            LockedERC4626
        )
    {
        // New Cellar with positions in USDC, locked USDC, locked WETH, and  WETH
        LockedERC4626 lockedUSDC = new LockedERC4626(USDC, "Locked USDC", "LUSDC", 0.9e18); // 90% of funds are locked.
        LockedERC4626 lockedWETH = new LockedERC4626(WETH, "Locked WETH", "LWETH", 1e18); // 100% of funds are locked

        // Setup Cellar:
        address[] memory positions = new address[](4);
        positions[0] = address(USDC);
        positions[1] = address(lockedUSDC);
        positions[2] = address(lockedWETH);
        positions[3] = address(WETH);

        Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](4);
        positionTypes[0] = Cellar.PositionType.ERC20;
        positionTypes[1] = Cellar.PositionType.ERC4626;
        positionTypes[2] = Cellar.PositionType.ERC4626;
        positionTypes[3] = Cellar.PositionType.ERC20;

        MockCellar cellarWithLockedFunds = new MockCellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.ORDERLY,
            "Multiposition Cellar LP Token",
            "multiposition-CLR",
            strategist
        );

        stdstore
            .target(address(cellarWithLockedFunds))
            .sig(cellarWithLockedFunds.shareLockPeriod.selector)
            .checked_write(uint256(0));

        // Make initial deposit into cellar.
        deal(address(USDC), address(this), assets);
        USDC.approve(address(cellarWithLockedFunds), assets);
        cellarWithLockedFunds.deposit(assets, address(this));

        // Rebalance so 25% of assets are in each position.
        deal(address(USDC), address(cellarWithLockedFunds), assets / 2);

        uint256 WETHAssets = priceRouter.getValue(USDC, assets / 2, WETH);
        deal(address(WETH), address(cellarWithLockedFunds), WETHAssets);

        cellarWithLockedFunds.rebalance(
            address(USDC),
            address(lockedUSDC),
            assets / 4,
            SwapRouter.Exchange.UNIV2,
            abi.encode(0)
        );
        cellarWithLockedFunds.rebalance(
            address(WETH),
            address(lockedWETH),
            WETHAssets / 2,
            SwapRouter.Exchange.UNIV2,
            abi.encode(0)
        );

        assertEq(
            cellarWithLockedFunds.totalAssets(),
            assets,
            "Total assets should not have been changed during rebalance."
        );

        (uint256 getDataTotalAssets, , , , uint256[] memory withdrawable) = cellarWithLockedFunds.getData();

        assertEq(
            cellarWithLockedFunds.totalAssets(),
            getDataTotalAssets,
            "Total assets should equal getData total assets."
        );

        assertEq(withdrawable[0], assets / 4, "Everything should be withdrawable from the first position.");
        assertEq(withdrawable[1], assets / 40, "Only 10% of assets should be withdrawable from second position.");
        assertEq(withdrawable[2], 0, "No assets should be withdrawable from the third position.");
        assertEq(withdrawable[3], WETHAssets / 2, "Everything should be withdrawable from the fourth position.");

        return (cellarWithLockedFunds, lockedUSDC, lockedWETH);
    }

    function testCellarLockedAssetsOrderlyWithdraw() external {
        uint256 assets = 1_000_000e6;
        (MockCellar testCellar, , ) = createCellarWithLockedFunds(assets);

        assertEq(testCellar.maxWithdraw(address(this)), assets.mulWadDown(0.525e18));
        assertEq(testCellar.totalAssetsWithdrawable(), assets.mulWadDown(0.525e18));

        // User redeems 50% of their shares.
        testCellar.withdraw(assets / 2, address(this), address(this));

        // User should now have 27.5% of assets in USDC, and 22.5% of assets in WETH.
        assertEq(USDC.balanceOf(address(this)), assets.mulWadDown(0.275e18), "USDC balance should be 27.5% of assets.");
        uint256 WETHAssetsInUSDC = priceRouter.getValue(WETH, WETH.balanceOf(address(this)), USDC);
        assertEq(WETHAssetsInUSDC, assets.mulWadDown(0.225e18), "WETH balance should be 22.5% of assets.");

        assertEq(testCellar.totalAssets(), assets.mulWadDown(0.5e18), "Total assets should have decreased by 50%.");
    }

    function testCellarLockedAssetsProportionalWithdraw() external {
        uint256 assets = 1_000_000e6;
        (MockCellar testCellar, LockedERC4626 lockedUSDC, LockedERC4626 lockedWETH) = createCellarWithLockedFunds(
            assets
        );

        testCellar.setWithdrawType(Cellar.WithdrawType.PROPORTIONAL);

        // User can not redeem any of their tokens because some positions have funds locked in them.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__IlliquidWithdraw.selector, address(lockedUSDC))));
        testCellar.withdraw(assets / 2, address(this), address(this));

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__IlliquidWithdraw.selector, address(lockedWETH))));
        testCellar.withdraw(assets / 10, address(this), address(this));

        // In order to remedy this, if the the strategist can get funds out of the most restricting locked position they should.
        testCellar.rebalance(
            address(lockedWETH),
            address(WETH),
            WETH.balanceOf(address(lockedWETH)),
            SwapRouter.Exchange.UNIV2,
            abi.encode(0)
        );

        assertEq(testCellar.maxWithdraw(address(this)), assets / 10, "maxWithdraw should equal assets / 10.");
        // Now withdraws up to the next locked position can be performed.
        testCellar.withdraw(assets / 10, address(this), address(this));

        // Larger withdraws still fail because there is still a position with funds locked in it.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__IlliquidWithdraw.selector, address(lockedUSDC))));
        testCellar.withdraw(assets / 2, address(this), address(this));

        // If the strategist can not move funds out of this position, then they should change their Cellar back to an orderly withdraw.
        testCellar.setWithdrawType(Cellar.WithdrawType.ORDERLY);

        // Then move the illiquid position to the back of the position array to allow users to withdraw as much as they can from liquid positions.
        testCellar.swapPositions(1, 3);
        testCellar.withdraw(testCellar.maxWithdraw(address(this)), address(this), address(this));
    }

    function testMaxWithdraw() external {
        uint256 assets = 1_000_000e6;
        (MockCellar testCellar, , LockedERC4626 lockedWETH) = createCellarWithLockedFunds(assets);
        uint256 expectedMaxWithdraw = assets.mulWadDown(0.525e18);
        assertEq(testCellar.maxWithdraw(address(this)), expectedMaxWithdraw, "Max withdraw should equal expected.");

        testCellar.setWithdrawType(Cellar.WithdrawType.PROPORTIONAL);
        expectedMaxWithdraw = 0; // Since lockedWETH position has no withdrawable funds.
        assertEq(testCellar.maxWithdraw(address(this)), expectedMaxWithdraw, "Max withdraw should equal expected.");

        // Rebalance funds from lockedWETH to WETH.
        testCellar.rebalance(
            address(lockedWETH),
            address(WETH),
            WETH.balanceOf(address(lockedWETH)),
            SwapRouter.Exchange.UNIV2,
            abi.encode(0)
        );

        expectedMaxWithdraw = assets.mulWadDown(0.10e18);
        assertEq(testCellar.maxWithdraw(address(this)), expectedMaxWithdraw, "Max withdraw should equal expected.");

        // Give another user some shares worth less than 2.5% of assets.
        address otherUser = vm.addr(7777);
        uint256 shares = testCellar.convertToShares(assets.mulWadDown(0.02e18));
        testCellar.transfer(otherUser, shares);

        // Make sure that if max withdraw is less than the withdrawable funds, it returns the full share worth.
        expectedMaxWithdraw = assets.mulWadDown(0.02e18);
        assertEq(testCellar.maxWithdraw(otherUser), expectedMaxWithdraw, "Max withdraw should equal expected..");

        testCellar.setWithdrawType(Cellar.WithdrawType.ORDERLY);
        expectedMaxWithdraw = assets.mulWadDown(0.02e18);
        assertEq(testCellar.maxWithdraw(otherUser), expectedMaxWithdraw, "Max withdraw should equal expected..");

        expectedMaxWithdraw = assets.mulWadDown(0.775e18);
        assertEq(testCellar.maxWithdraw(address(this)), expectedMaxWithdraw, "Max withdraw should equal expected..");
    }

    // M5
    function testReentrancyAttack() external {
        // True means this cellar tries to re-enter caller on deposit calls.
        ReentrancyERC4626 maliciousCellar = new ReentrancyERC4626(USDC, "Bad Cellar", "BC", true);

        cellar.trustPosition(address(maliciousCellar), Cellar.PositionType.ERC4626);
        cellar.pushPosition(address(maliciousCellar));
        cellar.setHoldingPosition(address(maliciousCellar));

        uint256 assets = 10000e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(maliciousCellar), assets);

        vm.expectRevert(bytes("REENTRANCY"));
        cellar.deposit(assets, address(this));
    }

    // L-4 handle via using a centralized contract storing valid positions(to reduce num of governance props), and rely on voters to see mismatched position and types.
    //  Will not be added to this code.

    //M-6 handled offchain using a subgraph to verify no weird webs are happening
    // difficult bc we can control downstream, but can't control upstream. IE
    // Cellar A wants to add a position in Cellar B, but Cellar B already has a position in Cellar C. Cellar A could see this, but...
    // If Cellar A takes a postion in Cellar B, then Cellar B takes a position in Cellar C, Cellar B would need to look upstream to see the nested postions which is unreasonable,
    // and it means Cellar A can dictate what positions Cellar B takes which is not good.

    // M-4, change in mint function
    function testAttackOnFirstMint() external {
        // An attacker attacks as first minter
        address attacker = vm.addr(1337);

        vm.startPrank(attacker);

        deal(address(USDC), address(attacker), 10000e6);
        USDC.approve(address(cellar), 10000e6);

        // Attacker mints shares < 1e12 on first mint

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__ZeroAssets.selector)));
        cellar.mint(9e11, attacker);

        vm.stopPrank();
    }

    // M-2, changes in trustPosition.
    function testTrustPositionForUnsupportedAssetLocksAllFunds() external {
        // USDT is not a supported PriceRouter asset.

        uint256 assets = 10e18;

        deal(address(USDC), address(this), assets);

        // Deposit USDC
        cellar.previewDeposit(assets);
        cellar.deposit(assets, address(this));
        assertEq(USDC.balanceOf(address(this)), 0, "Should have deposited assets from user.");

        // USDT is added as a trusted Cellar position,
        // but is not supported by the PriceRouter.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__PositionPricingNotSetUp.selector, address(USDT))));
        cellar.trustPosition(address(USDT), Cellar.PositionType.ERC20);
    }

    function testMultiAssetCellarWithIlliquidPositions(uint8 salt) external {
        // Initialize users.
        address alice = vm.addr(1);
        address bob = vm.addr(2);
        address sam = vm.addr(3);
        address mary = vm.addr(4);

        // Variable used to pass yield earned to _checkSendFees function.
        uint256 yieldEarned;

        // Initialize test Cellar.
        MockCellar assetManagementCellar;

        // Create two ERC4626 positions one with fully locked funds, and one with 90% of funds locked.
        LockedERC4626 lockedUSDC = new LockedERC4626(USDC, "Locked USDC", "LUSDC", 0.9e18); // 90% of funds are locked.
        LockedERC4626 lockedWETH = new LockedERC4626(WETH, "Locked WETH", "LWETH", 1e18); // 100% of funds are locked
        {
            // Create new cellar with WETH, USDC, and WBTC positions.
            address[] memory positions = new address[](4);
            positions[0] = address(USDC);
            positions[1] = address(lockedWETH);
            positions[2] = address(WETH);
            positions[3] = address(lockedUSDC);

            Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](4);
            positionTypes[0] = Cellar.PositionType.ERC20;
            positionTypes[1] = Cellar.PositionType.ERC4626;
            positionTypes[2] = Cellar.PositionType.ERC20;
            positionTypes[3] = Cellar.PositionType.ERC4626;

            assetManagementCellar = new MockCellar(
                registry,
                WETH,
                positions,
                positionTypes,
                address(WETH),
                Cellar.WithdrawType.ORDERLY,
                "Asset Management Cellar LP Token",
                "assetmanagement-CLR",
                strategist
            );

            stdstore
                .target(address(assetManagementCellar))
                .sig(assetManagementCellar.shareLockPeriod.selector)
                .checked_write(uint256(0));
        }

        // Update allowed rebalance deviation to work with mock swap router.
        assetManagementCellar.setRebalanceDeviation(0.05e18);

        // Give users WETH to interact with the Cellar.
        deal(address(WETH), alice, type(uint256).max);
        deal(address(WETH), bob, type(uint256).max);
        deal(address(WETH), sam, type(uint256).max);
        deal(address(WETH), mary, type(uint256).max);

        // Approve cellar to send user assets.
        vm.prank(alice);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(bob);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(sam);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        vm.prank(mary);
        WETH.approve(address(assetManagementCellar), type(uint256).max);

        // ====================== BEGIN SCENERIO ======================

        // Users join  cellar, cellar rebalances into USDC and WBTC positions,
        // and sendFees is called.
        {
            uint256 amount = (_mutate(salt) * 1e18) / 2000;
            uint256 shares;
            uint256 assets;

            // Expected high watermark after 3 users each join cellar with `amount` of assets.
            uint256 expectedHighWatermark = amount * 3;

            // Alice joins cellar using deposit.
            (assets, shares) = _userAction(assetManagementCellar, alice, Action.DEPOSIT, amount, 0);
            assertEq(shares, assetManagementCellar.balanceOf(alice), "Alice should have got shares out from deposit.");

            // Bob joins cellar using Mint.
            uint256 bobAssets = WETH.balanceOf(bob);
            (assets, shares) = _userAction(assetManagementCellar, bob, Action.MINT, 0, shares);
            assertEq(
                assets,
                bobAssets - WETH.balanceOf(bob),
                "Bob should have `amount` of assets taken from his address."
            );

            // Sam joins cellar with deposit, withdraws half his assets, then adds them back in using mint.
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.DEPOSIT, amount, 0);
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.WITHDRAW, amount / 2, 0);
            (assets, shares) = _userAction(assetManagementCellar, sam, Action.MINT, 0, shares);

            // High Watermark should be equal to amount * 3 and it should equal total assets.
            uint256 totalAssets = assetManagementCellar.totalAssets();
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(highWatermark, expectedHighWatermark, "High Watermark should equal expectedHighWatermark.");
            assertEq(
                highWatermark,
                totalAssets,
                "High Watermark should equal totalAssets because no yield was earned."
            );
        }
        {
            // Strategy providers swaps into USDC and WBTC using WETH, targeting a 20/40/40 split(WETH/USDC/WBTC).
            uint256 totalAssets = assetManagementCellar.totalAssets();

            // Swap 50% of Cellars WETH for USDC.
            uint256 wethToSell = totalAssets.mulDivDown(5, 10);
            _rebalance(assetManagementCellar, WETH, USDC, wethToSell);

            // Swap 40% of Cellars WETH for lockedWETH.
            wethToSell = totalAssets.mulDivDown(1, 10);
            _rebalance(assetManagementCellar, WETH, ERC20(address(lockedWETH)), wethToSell);

            // Move 80% of cellars  USDC into lockedUSDC.
            uint256 usdcBal = USDC.balanceOf(address(assetManagementCellar));
            _rebalance(assetManagementCellar, USDC, ERC20(address(lockedUSDC)), usdcBal.mulDivDown(4, 5));
        }
        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, USDC);
        _checkSendFees(assetManagementCellar, 7 days, 0);

        // WETH price decreases enough to create yield, Mary joins the cellar, and sendFees is called.
        {
            uint256 totalAssets = assetManagementCellar.totalAssets();
            // WETH price goes down.
            {
                ERC20[] memory assetsToAdjust = new ERC20[](2);
                uint256[] memory prices = new uint256[](2);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                prices[0] = 1e8;
                prices[1] = 1_500e8;
                _changeMarketPrices(assetsToAdjust, prices);
            }

            uint256 newTotalAssets = assetManagementCellar.totalAssets();

            yieldEarned = newTotalAssets - totalAssets;

            assertEq(
                newTotalAssets,
                (totalAssets + yieldEarned),
                "totalAssets after price increased by amount of yield earned."
            );
        }
        {
            uint256 amount = (_mutate(salt) * 1e18) / 2000;
            uint256 shares;
            uint256 assets;
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();

            // Mary joins cellar using deposit.
            yieldEarned = assetManagementCellar.totalAssets() - highWatermark;
            (assets, shares) = _userAction(assetManagementCellar, mary, Action.DEPOSIT, amount, 0);
            (highWatermark, , , , , , ) = assetManagementCellar.feeData();
            assertEq(
                highWatermark,
                assetManagementCellar.totalAssets(),
                "High watermark should be equal to totalAssets."
            );

            assertTrue(
                assetManagementCellar.balanceOf(address(assetManagementCellar)) > 0,
                "Cellar should have been minted performance fees."
            );
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 0 days, yieldEarned, USDC);
        _checkSendFees(assetManagementCellar, 7 days, yieldEarned);

        // Adjust fee variables, lower WETH price but raise WBTC price enough to
        // create yield, Bob and Sam join
        // cellar, and sendFees is called.
        {
            // Set platform fee to 2%.
            assetManagementCellar.setPlatformFee(0.02e18);

            // Set strategist platform cut to 80%.
            assetManagementCellar.setStrategistPlatformCut(0.8e18);

            // Set performance fee to 0%.
            assetManagementCellar.setPerformanceFee(0.2e18);

            // Set strategist performance cut to 85%.
            assetManagementCellar.setStrategistPerformanceCut(0.85e18);

            // WETH price goes down. USDC price goes down.
            {
                uint256 totalAssets = assetManagementCellar.totalAssets();
                ERC20[] memory assetsToAdjust = new ERC20[](2);
                uint256[] memory prices = new uint256[](2);
                assetsToAdjust[0] = USDC;
                assetsToAdjust[1] = WETH;
                prices[0] = 0.9998e8;
                prices[1] = 1_200e8;
                _changeMarketPrices(assetsToAdjust, prices);
                totalAssets = assetManagementCellar.totalAssets();
            }
        }

        {
            // Bob enters cellar via `mint`.
            uint256 shares = (_mutate(salt) * 1e18) / 2000;
            uint256 totalAssets = assetManagementCellar.totalAssets();
            (uint256 highWatermark, , , , , , ) = assetManagementCellar.feeData();
            yieldEarned = totalAssets - highWatermark;

            deal(address(WETH), bob, type(uint256).max);
            (, shares) = _userAction(assetManagementCellar, bob, Action.MINT, 0, shares);
            deal(address(WETH), bob, 0);
            uint256 feeSharesInCellar = assetManagementCellar.balanceOf(address(assetManagementCellar));
            deal(address(WETH), sam, type(uint256).max);
            (, shares) = _userAction(assetManagementCellar, sam, Action.MINT, 0, shares);
            deal(address(WETH), sam, 0);
            assertEq(
                feeSharesInCellar,
                assetManagementCellar.balanceOf(address(assetManagementCellar)),
                "Performance Fees should not have been minted."
            );

            _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 21 days, yieldEarned, USDC);
            _checkSendFees(assetManagementCellar, 21 days, yieldEarned);
        }

        // No yield was earned, and 28 days pass.
        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 28 days, 0, USDC);
        _checkSendFees(assetManagementCellar, 28 days, 0);

        // Alice redeems shares, and call sendFees.
        {
            // Cellar has liquidity in USDC,  WETH, locked WETH, and lockedUSDC,
            // Alice withdraws as much as she can.
            uint256 assets = assetManagementCellar.maxWithdraw(alice);

            // Set Alice's WETH balance to zero to avoid overflow on transfer.
            deal(address(WETH), alice, 0);
            deal(address(USDC), alice, 0);
            // Alice redeems her shares.
            _userAction(assetManagementCellar, alice, Action.WITHDRAW, assets, 0);
            assertTrue(USDC.balanceOf(alice) > 0, "Alice should have gotten USDC.");
            assertTrue(WETH.balanceOf(alice) > 0, "Alice should have gotten WETH.");
            uint256 USDCworth = priceRouter.getValue(USDC, USDC.balanceOf(alice), WETH);
            assertApproxEqRel(
                WETH.balanceOf(alice) + USDCworth,
                assets,
                0.00000001e18,
                "Value of assets out should approximately equal assets."
            );

            assertTrue(
                assetManagementCellar.balanceOf(address(assetManagementCellar)) == 0,
                "Cellar should have zero performance fees minted."
            );
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 7 days, 0, USDC);
        _checkSendFees(assetManagementCellar, 7 days, 0);

        // Alice rejoins cellar, call sendFees.
        {
            // Alice rejoins via mint.
            uint256 sharesToMint = _mutate(salt) * 1e18;
            deal(address(WETH), alice, assetManagementCellar.previewMint(sharesToMint));
            _userAction(assetManagementCellar, alice, Action.MINT, 0, sharesToMint);
        }

        _ensureEnoughAssetsToCoverSendFees(assetManagementCellar, 1 days, 0, USDC);
        _checkSendFees(assetManagementCellar, 1 days, 0);
        {
            // Everyone leaves  the cellar. Strategist must rebalance into liquid positions.
            uint256 assets = assetManagementCellar.maxWithdraw(bob);
            _userAction(assetManagementCellar, bob, Action.WITHDRAW, assets, 0);

            assets = assetManagementCellar.maxWithdraw(alice);
            _userAction(assetManagementCellar, alice, Action.WITHDRAW, assets, 0);

            // Mary and Sam leave the cellar using maxRedeem
            uint256 shares = assetManagementCellar.maxRedeem(mary);
            _userAction(assetManagementCellar, mary, Action.REDEEM, 0, shares);

            shares = assetManagementCellar.maxRedeem(sam);
            _userAction(assetManagementCellar, sam, Action.REDEEM, 0, shares);

            // Strategist rebalances into liquid positions.
            _rebalance(assetManagementCellar, ERC20(address(lockedWETH)), WETH, WETH.balanceOf(address(lockedWETH)));
            _rebalance(assetManagementCellar, ERC20(address(lockedUSDC)), USDC, USDC.balanceOf(address(lockedUSDC)));

            // Have everyone completely exit the cellar.
            shares = assetManagementCellar.maxRedeem(bob);
            if (shares > 0) _userAction(assetManagementCellar, bob, Action.REDEEM, 0, shares);

            shares = assetManagementCellar.maxRedeem(alice);
            if (shares > 0) _userAction(assetManagementCellar, alice, Action.REDEEM, 0, shares);

            shares = assetManagementCellar.maxRedeem(mary);
            if (shares > 0) _userAction(assetManagementCellar, mary, Action.REDEEM, 0, shares);

            shares = assetManagementCellar.maxRedeem(sam);
            if (shares > 0) _userAction(assetManagementCellar, sam, Action.REDEEM, 0, shares);

            assertLe(assetManagementCellar.balanceOf(alice), 1, "alice should have no more shares.");
            assertLe(assetManagementCellar.balanceOf(bob), 1, "bob should have no more shares.");
            assertLe(assetManagementCellar.balanceOf(sam), 1, "sam should have no more shares.");
            assertLe(assetManagementCellar.balanceOf(mary), 1, "mary should have no more shares.");
        }
    }

    //H-1
    function testChainlinkPriceFeedUpdateSandwichAttack() external {
        // Initialize test Cellar.

        // Create new cellar with WETH, and USDC positions.
        address[] memory positions = new address[](2);
        positions[0] = address(USDC);
        positions[1] = address(WETH);

        Cellar.PositionType[] memory positionTypes = new Cellar.PositionType[](2);
        positionTypes[0] = Cellar.PositionType.ERC20;
        positionTypes[1] = Cellar.PositionType.ERC20;

        MockCellar cellarA = new MockCellar(
            registry,
            USDC,
            positions,
            positionTypes,
            address(USDC),
            Cellar.WithdrawType.ORDERLY,
            "Asset Management Cellar LP Token",
            "assetmanagement-CLR",
            strategist
        );

        // Set up worst case scenario where
        // Cellar has all of its funds in mispriced asset(WETH)
        // Chainlink updates price because of max price deviation(1%)

        uint256 assets = 10_000e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(cellarA), assets);
        cellarA.deposit(assets, address(this));
        // Manually rebalance funds from USDC to WETH.
        deal(address(USDC), address(cellarA), 0);
        deal(address(WETH), address(cellarA), 5e18);

        // Attacker joins cellar right before price update.
        address attacker = vm.addr(8349058);
        deal(address(USDC), attacker, assets);
        vm.startPrank(attacker);
        USDC.approve(address(cellarA), assets);
        cellarA.deposit(assets, attacker);
        vm.stopPrank();

        // Price updates
        priceRouter.setExchangeRate(USDC, WETH, 0.000495e18);
        priceRouter.setExchangeRate(WETH, USDC, 2020e6);

        // Confirm attackers maxWithdraw is zero while shares are locked.
        assertEq(cellarA.maxWithdraw(attacker), 0, "Attackers maxWithdraw should be zero while shares are locked.");

        // Confirm attackers maxRedeem is zero while shares are locked.
        assertEq(cellarA.maxRedeem(attacker), 0, "Attackers maxRedeem should be zero while shares are locked.");

        vm.startPrank(attacker);
        uint256 shares = cellarA.balanceOf(attacker);
        // Attacker tries to redeem their shares.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellarA.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellarA.redeem(shares, attacker, attacker);

        // Attacker tries to transfer shares to another address.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellarA.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellarA.transfer(address(this), shares);
        vm.stopPrank();

        vm.roll(block.number + cellarA.shareLockPeriod());

        // Confirm attackers shares are worth more once shares are unlocked.
        assertGt(cellarA.maxWithdraw(attacker), assets, "Attackers shares should be worth more than deposit.");

        // Note the attacker was able to arbitrage the price feed update, but must wait the share lock period in order to capture profit.
    }

    function testShareLockUpPeriod() external {
        // Try to set lock period to illogical value.
        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidShareLockPeriod.selector)));
        cellar.setShareLockPeriod(type(uint32).max);

        vm.expectRevert(bytes(abi.encodeWithSelector(Cellar.Cellar__InvalidShareLockPeriod.selector)));
        cellar.setShareLockPeriod(0);

        // Set lock period to reasonable value.
        uint256 newLock = 8;
        cellar.setShareLockPeriod(newLock);
        assertEq(cellar.shareLockPeriod(), newLock, "Cellar share lock should equal newLock.");

        // Make sure user's who join with mint or deposit can not transfer, withdraw, or redeem for the shareLockPeriod.
        uint256 assets = 100e6;
        uint256 shares = 100e18;
        address depositUser = vm.addr(7777);
        address mintUser = vm.addr(77777);
        vm.startPrank(depositUser);
        deal(address(USDC), depositUser, assets);
        USDC.approve(address(cellar), assets);
        cellar.deposit(assets, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.withdraw(assets, depositUser, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.redeem(shares, depositUser, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.transfer(address(this), shares);
        vm.stopPrank();

        vm.startPrank(mintUser);
        deal(address(USDC), mintUser, assets);
        USDC.approve(address(cellar), assets);
        cellar.mint(shares, mintUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.withdraw(assets, mintUser, mintUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.redeem(shares, mintUser, mintUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.transfer(address(this), shares);
        vm.stopPrank();

        // Advance block number to end of share lock period.
        vm.roll(block.number + cellar.shareLockPeriod());

        // Users can withdraw.
        vm.prank(depositUser);
        cellar.withdraw(assets, depositUser, depositUser);

        // Users can transfer.
        vm.prank(mintUser);
        cellar.transfer(depositUser, shares);

        // Users can redeem.
        vm.prank(depositUser);
        cellar.redeem(shares, depositUser, depositUser);

        // Check that if a user has waited the lock period but then decides to deposit again, they must wait for the new lock period to end.
        vm.startPrank(depositUser);
        deal(address(USDC), depositUser, assets);
        USDC.approve(address(cellar), 2 * assets);
        cellar.deposit(assets, depositUser);
        // Advance block number to end of share lock period.
        vm.roll(block.number + cellar.shareLockPeriod());

        // If user joins again, they must wait the lock period again, even if withdrawing previous amount.
        deal(address(USDC), depositUser, assets);
        cellar.deposit(assets, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    Cellar.Cellar__SharesAreLocked.selector,
                    block.number + cellar.shareLockPeriod(),
                    block.number
                )
            )
        );
        cellar.withdraw(assets, depositUser, depositUser);
        vm.stopPrank();
    }

    function testDepositOnBehalf() external {
        address user = vm.addr(1111);
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(Cellar.Cellar__NotApprovedToDepositOnBehalf.selector, address(this)))
        );
        cellar.deposit(assets, user);

        // Add this address as an approved depositor.
        registry.setApprovedForDepositOnBehalf(address(this), true);
        // Deposits are now allowed.
        cellar.deposit(assets, user);
    }

    // Crowd Audit Tests
    //M-1 Accepted
    //M-2
    function testCellarDNOSPerformanceFeesWithZeroShares() external {
        //Attacker deposits 1 USDC into Cellar.
        uint256 assets = 1e6;
        address attacker = vm.addr(101);
        deal(address(USDC), attacker, assets);
        vm.prank(attacker);
        USDC.transfer(address(cellar), assets);

        address user = vm.addr(10101);
        deal(address(USDC), user, assets);

        vm.startPrank(user);
        USDC.approve(address(cellar), assets);
        cellar.deposit(assets, user);
        vm.stopPrank();

        assertEq(
            cellar.maxWithdraw(user),
            assets.mulWadDown(1.9e18),
            "User should be able to withdraw their assets and the attackers(minus performance fees)."
        );
    }

    //TODO add test that sees if maxWithdraw returns 0 when in the shrae lock period
}
