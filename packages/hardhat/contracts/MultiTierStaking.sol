// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract MultiTierStaking is 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    using SafeMath for uint256;
    using Address for address;

    // Version control
    string public constant VERSION = "2.0.0";
    uint256 public constant UPGRADE_TIMELOCK = 2 days;
    uint256 public lastUpgradeTimestamp;

    // Roles
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Constants
    uint256 public constant MAX_TIER_REWARD_RATE = 3000; // 30% max APY
    uint256 public constant MIN_STAKE_DURATION = 1 days;
    uint256 public constant MAX_STAKE_DURATION = 365 days;
    uint256 public constant COOLDOWN_PERIOD = 1 days;
    uint256 public constant MAX_FEE = 1000; // 10% max fee
    uint256 public constant PROPOSAL_EXECUTION_DELAY = 2 days;
    uint256 public constant MAX_TOKENS = 10;
    uint256 public constant MINIMUM_PROPOSAL_DESCRIPTION_LENGTH = 100;

    // Staking tiers
    struct Tier {
        uint256 minimumStake;
        uint256 rewardRate; // basis points per year
        uint256 lockPeriod; // in seconds
        uint256 maxRewardCap; // maximum reward possible
        bool active;
        bool compoundingAllowed;
    }

    // Enhanced stake information
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        uint256 lastClaimTime;
        uint256 accumulatedRewards;
        uint8 tierId;
        bool locked;
        bool compounding;
        uint256 cooldownEnd;
    }

    // Treasury
    struct TreasuryInfo {
        address treasury;
        uint96 fee; // basis points (1/10000)
        uint256 collectedFees;
        bool feesEnabled;
        uint256 rewardPool;
        uint256 totalStaked;
        uint256 lastUpdateTime;
    }

    // Recovery
    struct RecoveryRequest {
        address newAddress;
        uint256 requestTime;
        bool pending;
        bytes32 requestHash;
        uint256 securityDelay;
    }

    // Enhanced governance
    struct Proposal {
        bytes32 proposalHash;
        uint256 votingEnds;
        uint256 executionTime;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotes;
        bool executed;
        bool cancelled;
        bool vetoed;
        address proposer;
        string description;
        address target;
        bytes data;
        mapping(address => bool) hasVoted;
        mapping(address => uint256) delegatedPower;
    }

    // Reward pool tracking
    struct RewardPoolInfo {
        uint256 totalRewards;
        uint256 distributedRewards;
        uint256 lastUpdateBlock;
        mapping(address => uint256) userRewardDebt;
    }

    // State variables
    mapping(uint8 => Tier) public tiers;
    mapping(address => Stake) public stakes;
    mapping(address => mapping(address => uint256)) public tokenBalances;
    address[] public supportedTokens;
    mapping(address => bool) public isTokenSupported;
    mapping(address => bool) public hasBeenUsed;
    mapping(address => address) public delegations;
    mapping(address => uint256) public slashingHistory;
    
    TreasuryInfo public treasuryInfo;
    address public recoveryAdmin;
    uint256 public recoveryDelay;
    mapping(address => RecoveryRequest) public recoveryRequests;
    
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    RewardPoolInfo public rewardPool;
    
    // Circuit breakers
    uint256 public constant MAX_DAILY_STAKE = 10000 ether;
    uint256 public dailyStakeAmount;
    uint256 public lastStakeReset;
    bool public emergencyShutdown;
    
    // Rate limiting
    mapping(address => uint256) public lastActionTime;
    mapping(address => uint256) public upgradeProposalTimestamp;

    // Events
    event TierCreated(uint8 tierId, uint256 minimumStake, uint256 rewardRate, uint256 lockPeriod, uint256 maxRewardCap);
    event TierUpdated(uint8 tierId, uint256 minimumStake, uint256 rewardRate, uint256 lockPeriod, uint256 maxRewardCap);
    event Staked(address indexed user, uint256 amount, uint8 tierId, bool compounding);
    event Unstaked(address indexed user, uint256 amount, uint256 rewards);
    event RewardsClaimed(address indexed user, uint256 amount, uint8 tierId);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event RecoveryRequested(address indexed account, address indexed newAddress, bytes32 requestHash);
    event RecoveryCancelled(address indexed account);
    event RecoveryExecuted(address indexed oldAddress, address indexed newAddress);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, bytes32 proposalHash, string description);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event ProposalVoted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId, address indexed admin);
    event DelegationUpdated(address indexed delegator, address indexed delegatee);
    event RewardPoolUpdated(uint256 amount, bool isAddition);
    event EmergencyShutdown(bool enabled);
    event Slashed(address indexed user, uint256 amount, string reason);
    event CompoundingUpdated(address indexed user, bool enabled);
    event UpgradeProposed(address indexed newImplementation);
    event TreasuryFeeUpdated(uint256 newFee);
    event TreasuryFeesToggled(bool enabled);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event RewardsAdded(uint256 amount);
    event TierUpgraded(address indexed user, uint8 oldTierId, uint8 newTierId);

    // Modifiers
    modifier notUsedAddress(address _address) {
        require(!hasBeenUsed[_address], "Address previously used");
        require(_address != address(0), "Invalid address");
        require(!_address.isContract(), "Contract addresses not allowed");
        _;
    }

    modifier validQuorum(uint256 proposalId) {
        require(
            proposals[proposalId].totalVotes >= MINIMUM_QUORUM,
            "Quorum not reached"
        );
        _;
    }

    modifier rateLimit() {
        require(
            block.timestamp >= lastActionTime[msg.sender].add(ACTION_DELAY),
            "Action too frequent"
        );
        lastActionTime[msg.sender] = block.timestamp;
        _;
    }

    modifier circuitBreaker(uint256 amount) {
        if (block.timestamp >= lastStakeReset.add(1 days)) {
            dailyStakeAmount = 0;
            lastStakeReset = block.timestamp;
        }
        require(
            dailyStakeAmount.add(amount) <= MAX_DAILY_STAKE,
            "Daily stake limit reached"
        );
        _;
        dailyStakeAmount = dailyStakeAmount.add(amount);
    }

    modifier notEmergency() {
        require(!emergencyShutdown, "Contract is in emergency shutdown");
        _;
    }

    modifier onlyValidTier(uint8 tierId) {
        require(tiers[tierId].active, "Invalid or inactive tier");
        _;
    }

    modifier onlyValidToken(address token) {
        require(isTokenSupported[token], "Token not supported");
        _;
    }

    // Initialization
    function initialize(
        address _treasury,
        address _recoveryAdmin,
        uint256 _recoveryDelay
    ) public initializer {
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(UPGRADER_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
        _setupRole(TREASURY_ROLE, _treasury);
        _setupRole(EMERGENCY_ROLE, msg.sender);

        treasuryInfo.treasury = _treasury;
        treasuryInfo.fee = 100; // 1% default fee
        treasuryInfo.feesEnabled = true;
        
        recoveryAdmin = _recoveryAdmin;
        recoveryDelay = _recoveryDelay;
        lastStakeReset = block.timestamp;
        
        rewardPool.lastUpdateBlock = block.number;
        emergencyShutdown = false;
    }

    // Core staking functions
    function createTier(
        uint8 _tierId,
        uint256 _minimumStake,
        uint256 _rewardRate,
        uint256 _lockPeriod,
        uint256 _maxRewardCap,
        bool _compoundingAllowed
    ) external onlyRole(ADMIN_ROLE) {
        require(!tiers[_tierId].active, "Tier exists");
        require(_rewardRate <= MAX_TIER_REWARD_RATE, "Rate too high");
        require(_lockPeriod >= MIN_STAKE_DURATION && _lockPeriod <= MAX_STAKE_DURATION, "Invalid lock period");
        require(_minimumStake > 0, "Invalid minimum stake");

        tiers[_tierId] = Tier({
            minimumStake: _minimumStake,
            rewardRate: _rewardRate,
            lockPeriod: _lockPeriod,
            maxRewardCap: _maxRewardCap,
            active: true,
            compoundingAllowed: _compoundingAllowed
        });

        emit TierCreated(_tierId, _minimumStake, _rewardRate, _lockPeriod, _maxRewardCap);
    }

    function stake(
        uint256 amount,
        uint8 tierId,
        bool enableCompounding
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        notEmergency
        rateLimit 
        circuitBreaker(amount)
        onlyValidTier(tierId)
    {
        require(amount >= tiers[tierId].minimumStake, "Below minimum");
        require(!stakes[msg.sender].locked, "Already staked");
        require(
            block.timestamp >= stakes[msg.sender].cooldownEnd,
            "Cooldown period active"
        );

        if (enableCompounding) {
            require(
                tiers[tierId].compoundingAllowed,
                "Compounding not allowed for this tier"
            );
        }

        // Transfer tokens
        require(
            IERC20(supportedTokens[0]).transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        // Calculate fees
        uint256 fee = 0;
        if (treasuryInfo.feesEnabled) {
            fee = amount.mul(treasuryInfo.fee).div(10000);
            treasuryInfo.collectedFees = treasuryInfo.collectedFees.add(fee);
        }

        uint256 stakeAmount = amount.sub(fee);
        treasuryInfo.totalStaked = treasuryInfo.totalStaked.add(stakeAmount);

        // Create stake
        stakes[msg.sender] = Stake({
            amount: stakeAmount,
            startTime: block.timestamp,
            endTime: block.timestamp.add(tiers[tierId].lockPeriod),
            lastClaimTime: block.timestamp,
            accumulatedRewards: 0,
            tierId: tierId,
            locked: true,
            compounding: enableCompounding,
            cooldownEnd: 0
        });

        emit Staked(msg.sender, stakeAmount, tierId, enableCompounding);
    }

    function unstake() 
        external 
        nonReentrant 
        rateLimit 
    {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.locked, "No active stake");
        require(
            block.timestamp >= userStake.endTime || emergencyShutdown,
            "Lock not expired"
        );

        uint256 amount = userStake.amount;
        uint256 rewards = calculateRewards(msg.sender);
        require(rewards <= tiers[userStake.tierId].maxRewardCap, "Reward cap exceeded");

        // Update reward pool
        rewardPool.distributedRewards = rewardPool.distributedRewards.add(rewards);
        require(
            rewardPool.distributedRewards <= rewardPool.totalRewards,
            "Insufficient reward pool"
        );

        // Reset stake
        userStake.locked = false;
        userStake.amount = 0;
        userStake.accumulatedRewards = 0;
        userStake.cooldownEnd = block.timestamp.add(COOLDOWN_PERIOD);

        treasuryInfo.totalStaked = treasuryInfo.totalStaked.sub(amount);

        // Transfer tokens and rewards
        require(
            IERC20(supportedTokens[0]).transfer(msg.sender, amount.add(rewards)),
            "Transfer failed"
        );

        emit Unstaked(msg.</antArtifact>