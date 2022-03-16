// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.11;

import "./interfaces/IAaveStablecoinCellar.sol";
import "./interfaces/IAaveProtocolDataProvider.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interfaces/ILendingPool.sol";
import {ERC20} from "@rari-capital/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./utils/MathUtils.sol";
import "./interfaces/IAaveIncentivesController.sol";
import "./interfaces/IStakedTokenV2.sol";
import "./interfaces/IGravity.sol";

/**
 * @title Sommelier AaveStablecoinCellar contract
 * @notice AaveStablecoinCellar contract for Sommelier Network
 * @author Sommelier Finance
 */
contract AaveStablecoinCellar is
    IAaveStablecoinCellar,
    ERC20,
    Ownable
{
    using SafeTransferLib for ERC20;

    struct UserDeposit {
        uint256 assets;
        uint256 shares;
        uint256 timeDeposited;
    }

    // Uniswap Router V3 contract
    ISwapRouter public immutable swapRouter; // 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // Aave Lending Pool V2 contract
    ILendingPool public immutable lendingPool; // 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9
    // Aave Protocol Data Provider V2 contract
    IAaveProtocolDataProvider public immutable aaveDataProvider; // 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d
    // Aave Incentives Controller V2 contract
    IAaveIncentivesController public immutable incentivesController; // 0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5
    Gravity public immutable gravityBridge; // 0x69592e6f9d21989a043646fE8225da2600e5A0f7
    bytes32 public immutable feesDistributor; // TBD
    IStakedTokenV2 public immutable stkAAVE; // 0x4da27a545c0c5B758a6BA100e3a049001de870f5
    address public immutable AAVE; // 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9
    address public immutable WETH; // 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

    // Declare the variables and mappings
    address[] public inputTokensList;
    mapping(address => bool) internal inputTokens;
    // The address of the token of the current lending position
    address public currentLendingToken;
    address public currentAToken;
    // Track user user deposits to determine active/inactive shares.
    mapping(address => UserDeposit[]) public userDeposits;
    // Store the index of the user's last non-zero deposit to save gas on looping.
    mapping(address => uint256) public currentDepositIndex;
    // Last time inactive funds were entered into a strategy and made active.
    uint256 public lastTimeEnteredStrategy;

    uint24 public constant POOL_FEE = 3000;

    uint256 public constant DENOMINATOR = 10_000;
    uint256 public constant SECS_PER_YEAR = 31_556_952;
    uint256 public platformFee = 100;
    uint256 public performanceFee = 500;
    uint256 public lastTimeAccruedPlatformFees;
    // Fees are taken in shares and redeemed at the time they are transferred
    uint256 public accruedPlatformFees;
    uint256 public accruedPerformanceFees;

    /**
     * @param _swapRouter Uniswap V3 swap router address
     * @param _lendingPool Aave V2 lending pool address
     * @param _aaveDataProvider Aave Protocol Data Provider V2 contract address
     * @param _incentivesController _incentivesController
     * @param _stkAAVE _stkAAVE
     * @param _AAVE _AAVE
     * @param _WETH _WETH
     * @param _currentLendingToken token of lending pool where the cellar has its liquidity deposited
     * @param _name name of LP token
     * @param _symbol symbol of LP token
     */
    constructor(
        ISwapRouter _swapRouter,
        ILendingPool _lendingPool,
        IAaveProtocolDataProvider _aaveDataProvider,
        IAaveIncentivesController _incentivesController,
        Gravity _gravityBridge,
        bytes32 _feesDistributor,
        IStakedTokenV2 _stkAAVE,
        address _AAVE,
        address _WETH,
        address _currentLendingToken,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol, 18) Ownable() {
        swapRouter =  _swapRouter;
        lendingPool = _lendingPool;
        aaveDataProvider = _aaveDataProvider;
        incentivesController = _incentivesController;
        gravityBridge = _gravityBridge;
        feesDistributor = _feesDistributor;
        stkAAVE = _stkAAVE;
        AAVE = _AAVE;
        WETH = _WETH;

        currentLendingToken = _currentLendingToken;
        _updateCurrentAToken();
    }

    function _updateCurrentAToken() internal {
        (, , , , , , , address aTokenAddress, , , , ) = lendingPool.getReserveData(currentLendingToken);

        if (aTokenAddress == address(0)) revert TokenIsNotSupportedByAave();

        currentAToken = aTokenAddress;
    }

    /**
     * @notice Deposit supported tokens into the cellar.
     * @param token address of the supported token to deposit
     * @param assets amount of assets to deposit
     * @param minAssetsIn minimum amount of assets cellar should receive after swap (if applicable)
     * @param receiver address that should receive shares
     * @return shares amount of shares minted to receiver
     */
    function deposit(
        address token,
        uint256 assets,
        uint256 minAssetsIn,
        address receiver
    ) public returns (uint256 shares) {
        if (!inputTokens[token]) revert NonSupportedToken();

        ERC20(token).safeTransferFrom(msg.sender, address(this), assets);

        if (token != currentLendingToken) {
            assets = _swap(token, currentLendingToken, assets, minAssetsIn);
        }

        // Must calculate shares as if assets were not yet transfered in.
        if ((shares = _convertToShares(assets, assets)) == 0) revert ZeroAmount();

        _mint(receiver, shares);

        UserDeposit[] storage deposits = userDeposits[receiver];
        deposits.push(UserDeposit({
            assets: assets,
            shares: shares,
            timeDeposited: block.timestamp
        }));

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        return deposit(currentLendingToken, assets, assets, msg.sender);
    }

    /// @dev For ERC4626 compatibility.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        return deposit(currentLendingToken, assets, assets, receiver);
    }

    /**
     * @notice Withdraw from the cellar.
     * @param assets amount of assets to withdraw
     * @param receiver address that should receive assets
     * @param owner address that should own the shares
     * @return shares amount of shares burned from owner
     */
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        UserDeposit[] storage deposits = userDeposits[owner];
        if (deposits.length == 0 || currentDepositIndex[owner] > deposits.length - 1)
            revert NoNonemptyUserDeposits();

        uint256 withdrawnActiveShares;
        uint256 withdrawnInactiveShares;
        uint256 withdrawnInactiveAssets;
        uint256 originalDepositedAssets; // Used for calculating performance fees.

        // Saves gas by avoiding calling `convertToAssets` on active shares during each loop.
        uint256 exchangeRate = convertToAssets(1e18);

        uint256 leftToWithdraw = assets;
        uint256 currentIdx = currentDepositIndex[owner];
        for (uint256 i = currentIdx; i < deposits.length; i++) {
            UserDeposit storage d = deposits[i];

            uint256 withdrawnAssets;
            uint256 withdrawnShares;

            // Check if deposit shares are active or inactive.
            if (d.timeDeposited < lastTimeEnteredStrategy) {
                // Active:
                uint256 dAssets = exchangeRate * d.shares / 1e18;
                withdrawnAssets = MathUtils.min(leftToWithdraw, dAssets);
                withdrawnShares = MathUtils.mulDivUp(d.shares, withdrawnAssets, dAssets);

                uint256 originalDepositWithdrawn = MathUtils.mulDivUp(d.assets, withdrawnShares, d.shares);
                // Store to calculate performance fees on future withdraws.
                d.assets -= originalDepositWithdrawn;

                originalDepositedAssets += originalDepositWithdrawn;
                withdrawnActiveShares += withdrawnShares;
            } else {
                // Inactive:
                withdrawnAssets = MathUtils.min(leftToWithdraw, d.assets);
                withdrawnShares = MathUtils.mulDivUp(d.shares, withdrawnAssets, d.assets);

                d.assets -= withdrawnAssets;

                withdrawnInactiveShares += withdrawnShares;
                withdrawnInactiveAssets += withdrawnAssets;
            }

            d.shares -= withdrawnShares;

            leftToWithdraw -= withdrawnAssets;

            if (leftToWithdraw == 0) {
                currentDepositIndex[owner] = d.shares != 0 ? i : i+1;
                break;
            }
        }

        uint256 withdrawnActiveAssets = exchangeRate * withdrawnActiveShares / 1e18;

        if (withdrawnActiveAssets + withdrawnInactiveAssets != assets) revert FailedWithdraw();

        shares = withdrawnActiveShares + withdrawnInactiveShares;

        // Take performance fees.
        if (withdrawnActiveAssets > 0) {
            uint256 gain = withdrawnActiveAssets - originalDepositedAssets;
            uint256 feeInAssets = gain * performanceFee / DENOMINATOR;
            uint256 fees = convertToShares(feeInAssets);

            accruedPerformanceFees += fees;
            withdrawnActiveAssets -= feeInAssets;
            shares -= fees;

            // Take portion of shares that would have been burned as fees.
            ERC20(address(this)).safeTransferFrom(msg.sender, address(this), fees);
        }

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        _burn(owner, shares);

        if (withdrawnActiveAssets > 0) {
            // Withdraw tokens from Aave to receiver.
            lendingPool.withdraw(currentLendingToken, withdrawnActiveAssets, receiver);
        }

        if (withdrawnInactiveAssets > 0) {
            ERC20(currentLendingToken).transfer(receiver, withdrawnInactiveAssets);
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function withdraw(uint256 assets) external returns (uint256 shares) {
        return withdraw(assets, msg.sender, msg.sender);
    }

    /// @notice Total amount of inactive asset waiting in a holding pool to be entered into a strategy.
    function inactiveAssets() public view returns (uint256) {
        return ERC20(currentLendingToken).balanceOf(address(this));
    }

    /// @notice Total amount of active asset entered into a strategy.
    function activeAssets() public view returns (uint256) {
        // The aTokens' value is pegged to the value of the corresponding deposited
        // asset at a 1:1 ratio, so we can find the amount of assets active in a
        // strategy simply by taking balance of aTokens cellar holds.
        return ERC20(currentAToken).balanceOf(address(this));
    }

    /// @notice Total amount of the underlying asset that is managed by cellar.
    function totalAssets() public view returns (uint256) {
        return activeAssets() + inactiveAssets();
    }

    /**
     * @notice The amount of shares that the cellar would exchange for the amount of assets provided.
     * @param assets amount of assets to convert
     * @param offset amount to negatively offset total assets during calculation
     */
    function _convertToShares(uint256 assets, uint256 offset) internal view returns (uint256) {
        return totalSupply == 0 ? assets : MathUtils.mulDivDown(assets, totalSupply, totalAssets() - offset);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, 0);
    }

    /**
     * @notice The amount of assets that the cellar would exchange for the amount of shares provided.
     * @param shares amount of shares to convert
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalSupply == 0 ? shares : MathUtils.mulDivDown(shares, totalAssets(), totalSupply);
    }

    /**
     * @notice Swaps input token by Uniswap V3.
     * @param tokenIn the address of the incoming token
     * @param tokenOut the address of the outgoing token
     * @param amountIn the amount of tokens to be swapped
     * @param amountOutMinimum the minimum amount of tokens returned
     * @return amountOut the amount of tokens received after swap
     */
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        // Approve the router to spend tokenIn.
        ERC20(tokenIn).safeApprove(address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        // Executes the swap.
        amountOut = swapRouter.exactInputSingle(params);

        emit Swapped(tokenIn, amountIn, tokenOut, amountOut);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external onlyOwner returns (uint256 amountOut) {
        return _swap(tokenIn, tokenOut, amountIn, amountOutMinimum);
    }

    /**
     * @notice Swaps tokens by multihop swap in Uniswap V3.
     * @param path the token swap path (token addresses)
     * @param amountIn the amount of tokens to be swapped
     * @param amountOutMinimum the minimum amount of tokens returned
     * @return amountOut the amount of tokens received after swap
     */
    function _multihopSwap(
        address[] memory path,
        uint256 amountIn,
        uint256 amountOutMinimum

    ) internal returns (uint256 amountOut) {
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        if (path.length < 2) revert PathIsTooShort();

        // Approve the router to spend first token in path.
        ERC20(tokenIn).safeApprove(address(swapRouter), amountIn);

        bytes memory encodePackedPath = abi.encodePacked(tokenIn);
        for (uint256 i = 1; i < path.length; i++) {
            encodePackedPath = abi.encodePacked(
                encodePackedPath,
                POOL_FEE,
                path[i]
            );
        }

        // Multiple pool swaps are encoded through bytes called a `path`. A path
        // is a sequence of token addresses and poolFees that define the pools
        // used in the swaps. The format for pool encoding is (tokenIn, fee,
        // tokenOut/tokenIn, fee, tokenOut) where tokenIn/tokenOut parameter is
        // the shared token across the pools.
        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: encodePackedPath,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum
            });

        // Executes the swap.
        amountOut = swapRouter.exactInput(params);

        emit Swapped(tokenIn, amountIn, tokenOut, amountOut);
    }

    function multihopSwap(
        address[] memory path,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external onlyOwner returns (uint256) {
        return _multihopSwap(path, amountIn, amountOutMinimum);
    }

    /**
     * @notice Enters Aave stablecoin strategy.
     */
    function enterStrategy()
        external
        onlyOwner
    {
        _depositToAave(currentLendingToken, inactiveAssets());

        lastTimeEnteredStrategy = block.timestamp;
    }

    /**
     * @notice Reinvest stkAAVE rewards back into cellar's current position on Aave.
     * @dev Must be called in the 2 day unstake period started 10 days after claimAndUnstake was run.
     * @param amount amount of stkAAVE to redeem and reinvest
     * @param minAssetsOut minimum amount of assets cellar should receive after swap
     */
    function reinvest(uint256 amount, uint256 minAssetsOut) public onlyOwner {
        stkAAVE.redeem(address(this), amount);

        address[] memory path = new address[](3);
        path[0] = AAVE;
        path[1] = WETH;
        path[2] = currentLendingToken;

        uint256 amountIn = ERC20(AAVE).balanceOf(address(this));

        // NOTE: Due to the lack of liquidity for AAVE on Uniswap, we will
        // likely need change this to use Sushiswap instead for swaps.
        uint256 amountOut = _multihopSwap(path, amountIn, minAssetsOut);

        _depositToAave(currentLendingToken, amountOut);
    }

    function reinvest(uint256 minAssetsOut) external onlyOwner {
        reinvest(type(uint256).max, minAssetsOut);
    }

    /**
     * @notice Claim stkAAVE rewards from Aave and begin cooldown period to unstake.
     * @param amount amount of rewards to claim
     * @return claimed amount of rewards claimed from Aave
     */
    function claimAndUnstake(uint256 amount) public onlyOwner returns (uint256 claimed) {
        // Necessary as claimRewards accepts a dynamic array as first param.
        address[] memory aToken = new address[](1);
        aToken[0] = currentAToken;

        claimed = incentivesController.claimRewards(aToken, amount, address(this));

        stkAAVE.cooldown();
    }

    function claimAndUnstake() external onlyOwner returns (uint256) {
        return claimAndUnstake(type(uint256).max);
    }

    /**
     * @notice Deposits cellar holdings into Aave lending pool.
     * @param token the address of the token
     * @param assets the amount of token to be deposited
     */
    function _depositToAave(address token, uint256 assets) internal {
        if (!inputTokens[token]) revert NonSupportedToken();

        ERC20(token).safeApprove(address(lendingPool), assets);

        // Deposit token to Aave protocol.
        lendingPool.deposit(token, assets, address(this), 0);

        emit DepositToAave(token, assets);
    }

    /**
     * @notice Redeems a token from Aave protocol.
     * @param token the address of the token
     * @param amount the token amount being redeemed
     * @return withdrawnAmount the withdrawn amount from Aave
     */
    function redeemFromAave(address token, uint256 amount)
        public
        onlyOwner
        returns (
            uint256 withdrawnAmount
        )
    {
        if (!inputTokens[token]) revert NonSupportedToken();

        // Withdraw token from Aave protocol
        withdrawnAmount = lendingPool.withdraw(token, amount, address(this));

        emit RedeemFromAave(token, withdrawnAmount);
    }

    /**
     * @notice Rebalances of Aave lending position.
     * @param newLendingToken the address of the token of the new lending position
     */
    function rebalance(address newLendingToken, uint256 minNewLendingTokenAmount)
        external
        onlyOwner
    {
        if (!inputTokens[newLendingToken]) revert NonSupportedToken();

        if(newLendingToken == currentLendingToken) revert SameLendingToken();

        uint256 lendingPositionBalance = redeemFromAave(currentLendingToken, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = currentLendingToken;
        path[1] = newLendingToken;

        uint256 newLendingTokenAmount = _multihopSwap(
            path,
            lendingPositionBalance,
            minNewLendingTokenAmount
        );

        currentLendingToken = newLendingToken;
        _depositToAave(newLendingToken, newLendingTokenAmount);

        emit Rebalance(newLendingToken, newLendingTokenAmount);
    }

    /**
     * @notice Change the performance fee taken.
     * @param fee new performance fee
     */
    function setPerformanceFee(uint256 fee) external onlyOwner {
        if (fee > DENOMINATOR) revert GreaterThanMaxValue();

        performanceFee = fee;
    }

    /**
     * @notice Change the platform fee taken.
     * @param fee new platform fee
     */
    function setPlatformFee(uint256 fee) external onlyOwner {
        if (fee > DENOMINATOR) revert GreaterThanMaxValue();

        platformFee = fee;
    }

    /// @notice Take platform fees off of cellar's active assets.
    function accruePlatformFees() external {
        uint256 elapsedTime = block.timestamp - lastTimeAccruedPlatformFees;
        uint256 feeInAssets = (activeAssets() * elapsedTime * platformFee) / DENOMINATOR / SECS_PER_YEAR;
        uint256 fees = convertToShares(feeInAssets);

        _mint(address(this), fees);

        accruedPlatformFees += fees;
    }

    /// @notice Transfer accrued platform fees to Cosmos to distribute fees.
    function transferPlatformFees() external onlyOwner {
        uint256 feeInAssets = _sendFeesToCosmos(accruedPlatformFees);

        accruedPlatformFees = 0;

        emit TransferPlatformFees(feeInAssets);
    }

    /// @notice Transfer accrued performance fees to Cosmos to distribute fees.
    function transferPerformanceFees() external onlyOwner {
        uint256 feeInAssets = _sendFeesToCosmos(accruedPerformanceFees);

        accruedPerformanceFees = 0;

        emit TransferPerformanceFees(feeInAssets);
    }

    function _sendFeesToCosmos(uint256 shares) internal returns (uint256 feeInAssets) {
        feeInAssets = convertToShares(shares);

        // Only withdraw from Aave if holding pool does not contain enough funds.
        uint256 holdingPoolAssets = inactiveAssets();
        if (holdingPoolAssets < feeInAssets) {
            redeemFromAave(currentLendingToken, feeInAssets - holdingPoolAssets);
        }

        _burn(address(this), shares);

        gravityBridge.sendToCosmos(currentLendingToken, feesDistributor, feeInAssets);
    }

    /**
     * @notice Approve a supported token to be deposited into the cellar.
     * @param token the address of the supported token
     */
    function approveInputToken(address token) external onlyOwner {
        if (inputTokens[token]) revert TokenAlreadyInitialized();

        inputTokens[token] = true;
        inputTokensList.push(token);
    }
}
