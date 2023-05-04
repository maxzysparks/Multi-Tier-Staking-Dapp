// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

contract MultiTierStaking {
    uint256 public constant minimumStake = 100 ether;
    uint256 public constant maximumStakeDuration = 365 days;
    uint256 public constant minimumStakeTime = 7 days;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public timeStaked;
    mapping(address => uint256) public totalRewards;

    uint256 public rewardRate;

    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardsClaimed(address indexed staker, uint256 amount);

    function stake() public payable {
        require(msg.value >= minimumStake, "Staking amount must be at least 100 ether");
        balances[msg.sender] += msg.value;
        timeStaked[msg.sender] = block.timestamp;
        emit Staked(msg.sender, msg.value);
    }

    function extendStakeDuration() public {
        uint256 _timeStaked = timeStaked[msg.sender];
        uint256 timeElapsed = block.timestamp - _timeStaked;
        require(timeElapsed < maximumStakeDuration, "You cannot extend your stake duration any further");
        uint256 remainingTime = maximumStakeDuration - timeElapsed;
        require(remainingTime >= minimumStakeTime, "You must wait at least 7 days before extending your stake duration again");
        uint256 extensionReward = rewardRate * remainingTime;
        balances[msg.sender] += extensionReward;
        timeStaked[msg.sender] = block.timestamp;
    }

    function splitStake(uint256[] memory amounts) public {
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] >= minimumStake, "Staking amount must be at least 100 ether");
            totalAmount += amounts[i];
        }
        require(totalAmount == balances[msg.sender], "Invalid stake amounts");
        balances[msg.sender] = 0;
        timeStaked[msg.sender] = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            balances[msg.sender] += amounts[i];
            timeStaked[msg.sender] = block.timestamp;
            emit Staked(msg.sender, amounts[i]);
        }
    }

    function unstake() public {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "You do not have any staked balance to unstake");
        balances[msg.sender] = 0;
        timeStaked[msg.sender] = 0;
        uint256 reward = rewardRate * (block.timestamp - timeStaked[msg.sender]);
        totalRewards[msg.sender] += reward;
        (bool success,) = msg.sender.call{value: amount + reward}("");
        require(success, "Failed to send staked balance and rewards to user");
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() public {
        uint256 reward = totalRewards[msg.sender];
        require(reward > 0, "You do not have any unclaimed rewards");
        totalRewards[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: reward}("");
        require(success, "Failed to send rewards to user");
        emit RewardsClaimed(msg.sender, reward);
    }

    function setRewardRate(uint256 _rewardRate) public {
        rewardRate = _rewardRate;
    }
}
