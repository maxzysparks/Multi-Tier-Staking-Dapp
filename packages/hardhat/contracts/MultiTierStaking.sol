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

/**
 * @title MultiTierStaking
 * @dev Implements upgradeable pattern, role-based access, and complete security measures
 * @custom:security-contact security@yourdomain.com
 */
contract MultiTierStaking is 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    using SafeMath for uint256;

    // Roles
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // Version control
    string public constant VERSION = "1.0.0";

    // Staking tiers
    struct Tier {
        uint256 minimumStake;
        uint256 rewardRate; // basis points per year
        uint256 lockPeriod; // in seconds
        bool active;
    }

    // Stake information
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        uint256 lastClaimTime;
        uint8 tierId;
        bool locked;
    }

    // Treasury
    struct TreasuryInfo {
        address treasury;
        uint96 fee; // basis points (1/10000)
        uint256 collectedFees;
        bool feesEnabled;
    }

    // Recovery
    struct RecoveryRequest {
        address newAddress;
        uint256 requestTime;
        bool pending;
    }

    // Governance
    struct Proposal {
        bytes32 proposalHash;
        uint256 votingEnds;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotes;
        bool executed;
        bool cancelled;
        address proposer;
        mapping(address => bool) hasVoted;
    }

    // State variables
    mapping(uint8 => Tier) public tiers;
    mapping(address => Stake) public stakes;
    mapping(address => mapping(address => uint256)) public tokenBalances;
    address[] public supportedTokens;
    mapping(address => bool) public isTokenSupported;
    mapping(address => bool) public hasBeenUsed;
    
    TreasuryInfo public treasuryInfo;
    address public recoveryAdmin;
    uint256 public recoveryDelay;
    mapping(address => RecoveryRequest) public recoveryRequests;
    
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant PROPOSAL_THRESHOLD = 100 ether;
    uint256 public constant MINIMUM_QUORUM = 1000 ether;
    
    // Circuit breakers
    uint256 public constant MAX_DAILY_STAKE = 10000 ether;
    uint256 public dailyStakeAmount;
    uint256 public lastStakeReset;
    
    // Rate limiting
    mapping(address => uint256) public lastActionTime;
    uint256 public constant ACTION_DELAY = 1 hours;

    // Events
    event TierCreated(uint8 tierId, uint256 minimumStake, uint256 rewardRate, uint256 lockPeriod);
    event TierUpdated(uint8 tierId, uint256 minimumStake, uint256 rewardRate, uint256 lockPeriod);
    event Staked(address indexed user, uint256 amount, uint8 tierId);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event RecoveryRequested(address indexed account, address indexed newAddress);
    event RecoveryCancelled(address indexed account);
    event RecoveryExecuted(address indexed oldAddress, address indexed newAddress);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, bytes32 proposalHash);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event ProposalVoted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event TreasuryFeeUpdated(uint256 newFee);
    event TreasuryFeesToggled(bool enabled);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // Modifiers
    modifier notUsedAddress(address _address) {
        require(!hasBeenUsed[_address], "Address previously used");
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

        treasuryInfo.treasury = _treasury;
        treasuryInfo.fee = 100; // 1% default fee
        treasuryInfo.feesEnabled = true;
        
        recoveryAdmin = _recoveryAdmin;
        recoveryDelay = _recoveryDelay;
        lastStakeReset = block.timestamp;
    }

    // Core staking functions
    function createTier(
        uint8 _tierId,
        uint256 _minimumStake,
        uint256 _rewardRate,
        uint256 _lockPeriod
    ) external onlyRole(ADMIN_ROLE) {
        require(!tiers[_tierId].active, "Tier exists");
        require(_rewardRate <= 10000, "Rate too high"); // Max 100%

        tiers[_tierId] = Tier({
            minimumStake: _minimumStake,
            rewardRate: _rewardRate,
            lockPeriod: _lockPeriod,
            active: true
        });

        emit TierCreated(_tierId, _minimumStake, _rewardRate, _lockPeriod);
    }

    function stake(uint256 amount, uint8 tierId) 
        external 
        nonReentrant 
        whenNotPaused 
        rateLimit 
        circuitBreaker(amount) 
    {
        require(tiers[tierId].active, "Invalid tier");
        require(amount >= tiers[tierId].minimumStake, "Below minimum");
        require(!stakes[msg.sender].locked, "Already staked");

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

        // Create stake
        stakes[msg.sender] = Stake({
            amount: stakeAmount,
            startTime: block.timestamp,
            endTime: block.timestamp.add(tiers[tierId].lockPeriod),
            lastClaimTime: block.timestamp,
            tierId: tierId,
            locked: true
        });

        emit Staked(msg.sender, stakeAmount, tierId);
    }

    function unstake() external nonReentrant rateLimit {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.locked, "No active stake");
        require(block.timestamp >= userStake.endTime, "Lock not expired");

        uint256 amount = userStake.amount;
        uint256 rewards = calculateRewards(msg.sender);

        // Reset stake
        userStake.locked = false;
        userStake.amount = 0;

        // Transfer tokens and rewards
        require(
            IERC20(supportedTokens[0]).transfer(msg.sender, amount.add(rewards)),
            "Transfer failed"
        );

        emit Unstaked(msg.sender, amount);
        if (rewards > 0) {
            emit RewardsClaimed(msg.sender, rewards);
        }
    }

    function claimRewards() external nonReentrant rateLimit {
        require(stakes[msg.sender].locked, "No active stake");
        
        uint256 rewards = calculateRewards(msg.sender);
        require(rewards > 0, "No rewards");

        stakes[msg.sender].lastClaimTime = block.timestamp;

        require(
            IERC20(supportedTokens[0]).transfer(msg.sender, rewards),
            "Transfer failed"
        );

        emit RewardsClaimed(msg.sender, rewards);
    }

    // Internal functions
    function calculateRewards(address user) internal view returns (uint256) {
        Stake storage userStake = stakes[user];
        if (!userStake.locked) return 0;

        uint256 duration = block.timestamp.sub(userStake.lastClaimTime);
        uint256 rate = tiers[userStake.tierId].rewardRate;

        return userStake.amount.mul(rate).mul(duration).div(365 days).div(10000);
    }

    // Recovery functions
    function requestRecovery(address newAddress) 
        external 
        notUsedAddress(newAddress) 
    {
        require(stakes[msg.sender].locked, "No active stake");
        require(!recoveryRequests[msg.sender].pending, "Recovery pending");
        
        recoveryRequests[msg.sender] = RecoveryRequest({
            newAddress: newAddress,
            requestTime: block.timestamp,
            pending: true
        });
        
        emit RecoveryRequested(msg.sender, newAddress);
    }

    function cancelRecoveryRequest() external {
        require(recoveryRequests[msg.sender].pending, "No recovery pending");
        delete recoveryRequests[msg.sender];
        emit RecoveryCancelled(msg.sender);
    }

    function executeRecovery(address oldAddress) external {
        require(msg.sender == recoveryAdmin, "Not recovery admin");
        RecoveryRequest storage request = recoveryRequests[oldAddress];
        require(request.pending, "No recovery request");
        require(
            block.timestamp >= request.requestTime.add(recoveryDelay),
            "Delay not passed"
        );

        address newAddress = request.newAddress;
        
        // Transfer stake
        stakes[newAddress] = stakes[oldAddress];
        delete stakes[oldAddress];
        
        // Transfer balances
        for (uint i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            tokenBalances[newAddress][token] = tokenBalances[oldAddress][token];
            delete tokenBalances[oldAddress][token];
        }

        hasBeenUsed[oldAddress] = true;
        delete recoveryRequests[oldAddress];
        
        emit RecoveryExecuted(oldAddress, newAddress);
    }

    // Governance functions
    function createProposal(bytes32 proposalHash) external {
        require(stakes[msg.sender].amount >= PROPOSAL_THRESHOLD, "Insufficient stake");
        
        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.proposalHash = proposalHash;
        proposal.votingEnds = block.timestamp.add(VOTING_PERIOD);
        proposal.proposer = msg.sender;
        
        emit ProposalCreated(proposalCount, msg.sender, proposalHash);
    }

    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp < proposal.votingEnds, "Voting ended");
        require(
            msg.sender == proposal.proposer || 
            hasRole(ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        require(!proposal.cancelled, "Already cancelled");
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp < proposal.votingEnds, "Voting ended");
        require(!proposal.cancelled, "Proposal cancelled");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        require(stakes[msg.sender].locked, "Must be staker");

        uint256 weight = stakes[msg.sender].amount;

        if (support) {
            proposal.votesFor = proposal.votesFor.add(weight);
        } else {
            proposal.votesAgainst = proposal.votesAgainst.add(weight);
        }
        
        proposal.totalVotes = proposal.totalVotes.add(weight);
        proposal.hasVoted[msg.sender] = true;
        
        emit ProposalVoted(proposalId, msg.sender, support, weight);
    }

    function executeProposal(
        uint256 proposalId,
        address target,
        bytes memory data
    )