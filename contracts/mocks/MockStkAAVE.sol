// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "./MockToken.sol";

contract MockStkAAVE is MockToken {
    MockToken public immutable AAVE; // AAVE
    uint256 public constant COOLDOWN_SECONDS = 864000; // 10 days
    uint256 public constant UNSTAKE_WINDOW = 172800; // 2 days
    mapping(address => uint256) public stakersCooldowns;

    constructor(MockToken _AAVE) MockToken("stkAAVE") {
        AAVE = _AAVE;
    }

    function cooldown() external {
        require(balanceOf(msg.sender) != 0, "INVALID_BALANCE_ON_COOLDOWN");
        stakersCooldowns[msg.sender] = block.timestamp;
    }

    function redeem(address to, uint256 amount) external {
        require(amount != 0, "INVALID_ZERO_AMOUNT");
        uint256 cooldownStartTimestamp = stakersCooldowns[msg.sender];
        require(block.timestamp > cooldownStartTimestamp + COOLDOWN_SECONDS, "INSUFFICIENT_COOLDOWN");
        require(
            block.timestamp - (cooldownStartTimestamp + COOLDOWN_SECONDS) <= UNSTAKE_WINDOW,
            "UNSTAKE_WINDOW_FINISHED"
        );

        uint256 balanceOfMessageSender = balanceOf(msg.sender);

        uint256 amountToRedeem = (amount > balanceOfMessageSender) ? balanceOfMessageSender : amount;

        // _updateCurrentUnclaimedRewards(msg.sender, balanceOfMessageSender, true);

        _burn(msg.sender, amountToRedeem);

        if (balanceOfMessageSender - amountToRedeem == 0) stakersCooldowns[msg.sender] = 0;

        AAVE.mint(to, amountToRedeem);
    }
}