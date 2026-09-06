// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    Cockroach AI ($ROACH)
    -----------------------------------------------------------------
    Enterprise-Grade BEP-20 Presale, Staking & Verifiable Incentive Suite.
    - Mathematically Exact 48-Week Linear Curve ($0.00100 to $0.05000 Freeze)
    - Cryptographically Bound Timelock Parameter Assertions
    - Segregated Accounting Reservoirs
    - Graceful Staking Settlement & 25% Early Unstake Penalty
    - O(k) Bounded Sparse VRF v2.5 Monthly Settlement
    - 300s Safe Oracle Heartbeat
*/

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// ================================================================
// Custom Errors
// ================================================================

error Roach__ZeroAddress();
error Roach__ZeroAmount();
error Roach__Unauthorized();
error Roach__TradingLocked();
error Roach__TradingAlreadyActive();
error Roach__PurchaseTooSmall();
error Roach__PresalePoolLow();
error Roach__ExceedsWalletCap();
error Roach__InvalidDuration();
error Roach__InvalidIndex();
error Roach__StakeLocked();
error Roach__AlreadyClaimed();
error Roach__MonthlyReserveLow();
error Roach__MonthDurationNotElapsed();
error Roach__DrawAlreadyRequested();
error Roach__StaleOrInvalidVRF();
error Roach__DrawNotActive();
error Roach__RandomnessAlreadyFulfilled();
error Roach__RandomnessNotFulfilled();
error Roach__AlreadyFinalized();
error Roach__TimeoutPeriodActive();
error Roach__NoRewardsToClaim();
error Roach__TimelockActive();
error Roach__ActionNotQueued();
error Roach__ActionAlreadyQueued();
error Roach__ActionAlreadyExecuted();
error Roach__ParameterMismatch();
error Roach__ExceedsFreeInventory();
error Roach__OracleInvalidPrice();
error Roach__OracleIncompleteRound();
error Roach__OracleFutureTimestamp();
error Roach__OracleStaleRound();
error Roach__OracleHeartbeatExpired();
error Roach__UnsupportedDecimals();
error Roach__InvalidMonthId();
error Roach__ETHTransferFailed();
error Roach__DirectPaymentNotAllowed();
error Roach__InvalidCall();

// ================================================================
// Chainlink Price Feed Interface
// ================================================================

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

// ================================================================
// CockroachAI Token Contract
// ================================================================

contract CockroachAI is ERC20, ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    bool public tradingOpen;
    address public presaleContract;

    mapping(address => bool) public isExempt;

    event TradingEnabled();
    event ExemptionUpdated(address indexed account, bool isExempt);
    event PresaleContractLinked(address indexed presale);

    constructor() ERC20("Cockroach AI", "ROACH") Ownable(msg.sender) {
        isExempt[msg.sender] = true;
        _mint(msg.sender, MAX_SUPPLY);
    }

    modifier onlyAuthorized() {
        if (msg.sender != owner() && msg.sender != presaleContract) {
            revert Roach__Unauthorized();
        }
        _;
    }

    function setPresaleContract(address _presale) external onlyOwner {
        if (_presale == address(0)) revert Roach__ZeroAddress();
        presaleContract = _presale;
        isExempt[_presale] = true;
        emit PresaleContractLinked(_presale);
    }

    function setExemption(address account, bool exempt) external onlyAuthorized {
        if (account == address(0)) revert Roach__ZeroAddress();
        isExempt[account] = exempt;
        emit ExemptionUpdated(account, exempt);
    }

    function enableTrading() external onlyOwner {
        if (tradingOpen) revert Roach__TradingAlreadyActive();
        tradingOpen = true;
        emit TradingEnabled();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!tradingOpen && from != address(0)) {
            if (!isExempt[from] && !isExempt[to]) {
                revert Roach__TradingLocked();
            }
        }
        super._update(from, to, value);
    }
}

// ================================================================
// RoachPresalePro Engine
// ================================================================

contract RoachPresalePro is ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    CockroachAI public immutable roachToken;
    IERC20Metadata public immutable usdtToken;
    AggregatorV3Interface public immutable priceFeed;
    address payable public treasuryWallet;

    // Chainlink VRF Configuration
    uint256 public s_subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 200_000;
    uint16 public requestConfirmations = 3;

    // Mathematically Exact 48-Week Linear Pricing
    uint256 public immutable presaleStartTime;
    uint256 public constant STEP_DURATION = 7 days;
    uint256 public constant TOTAL_PRESALE_WEEKS = 48;
    uint256 public baseTokensPerUSD = 1000;        // Start: $0.00100 (1000 ROACH/USD)
    uint256 public minTokensPerUSD = 20;            // Freeze: $0.05000 (20 ROACH/USD)
    uint256 public tokensPerUSD = 1000;

    uint8 public immutable usdtDecimals;
    uint256 public maxMonthlyContributionPerWallet;
    uint256 public oracleHeartbeatLimit = 300;

    // Global Raised Stats
    uint256 public totalUSDTRaised;
    uint256 public totalBNBRaised;
    uint256 public totalTokensSold;

    // 4-Way Segregated Accounting Reservoirs
    uint256 public totalStakedPrincipal;
    uint256 public stakingRewardReserve;
    uint256 public monthlyRewardReserve;
    uint256 public totalPendingRewards;

    // Monthly Campaign Engine
    uint256 public constant MONTH_DURATION = 30 days;
    uint256 public currentMonthId = 1;
    uint256 public monthStartTime;

    // 48-Hour Timelock
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public timelockNonce;

    struct QueuedAction {
        uint256 executableAfter;
        bool executed;
        bool exists;
    }

    mapping(bytes32 => QueuedAction) public queuedActions;

    // Staking Structures
    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lockDuration;
        uint256 yieldBasisPoints;
        bool claimed;
    }

    mapping(address => StakeInfo[]) public userStakes;

    // Monthly Data
    struct MonthlyData {
        uint256 totalUSDEquivalent;
        uint256 rewardPoolTokens;
        address[10] top10Buyers;
        uint256[10] top10Amounts;
        address[20] luckyWinners;
        bool drawRequested;
        bool randomnessFulfilled;
        bool finalized;
        uint256 activeRequestId;
        uint256 requestTimestamp;
        uint256 randomSeed;
    }

    mapping(uint256 => MonthlyData) public monthlyStats;
    mapping(uint256 => mapping(address => uint256)) public userMonthlyContribution;
    mapping(uint256 => address[]) private monthlyQualifiedParticipants;
    mapping(uint256 => mapping(address => bool)) private hasQualified;
    mapping(address => uint256) public pendingClaimableRewards;
    mapping(uint256 => uint256) public vrfRequestToMonthId;
    mapping(uint256 => mapping(uint256 => address)) private sparseShuffleMap;

    // Events
    event TokensPurchased(address indexed buyer, string payMethod, uint256 paidAmount, uint256 tokenAmount, uint256 rateApplied);
    event TokensStaked(address indexed user, uint256 amount, uint256 duration, uint256 flatYieldBps);
    event TokensUnstaked(address indexed user, uint256 index, uint256 principal, uint256 rewardClaimed, uint256 rewardShortfall);
    event EmergencyEarlyUnstaked(address indexed user, uint256 index, uint256 netPrincipal, uint256 penaltyDeducted);
    event StakingRewardPoolFunded(uint256 amount);
    event MonthlyRewardPoolFunded(uint256 amount);
    event MonthlyDrawRequested(uint256 indexed monthId, uint256 requestId, uint256 rewardTokens);
    event RandomnessReceived(uint256 indexed monthId, uint256 randomSeed);
    event MonthlySettled(uint256 indexed monthId, uint256 totalRaisedUSD, uint256 distributedTokens, uint256 refundedTokens);
    event MonthlyDrawCancelled(uint256 indexed monthId, uint256 refundedAmount);
    event RewardClaimed(address indexed user, uint256 amount);
    event PriceRateUpdated(uint256 newTokensPerUSD);
    event ActionQueued(bytes32 indexed actionHash, string action, uint256 executableAfter);
    event ActionExecuted(bytes32 indexed actionHash, string action);
    event ActionCancelled(bytes32 indexed actionHash, string action);
    event UnsoldTokensWithdrawn(uint256 amount);
    event MilestoneBurnExecuted(uint256 burnAmount, string milestone);
    event TreasuryUpdated(address indexed newTreasury);
    event OracleHeartbeatUpdated(uint256 newHeartbeat);

    constructor(
        address _roachToken,
        address _usdtToken,
        address _priceFeed,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subscriptionId,
        address payable _treasury,
        uint256 _heartbeat
    )
        VRFConsumerBaseV2Plus(_vrfCoordinator)
    {
        if (_roachToken == address(0) || _usdtToken == address(0) || _priceFeed == address(0) || _vrfCoordinator == address(0) || _treasury == address(0)) {
            revert Roach__ZeroAddress();
        }

        roachToken = CockroachAI(_roachToken);
        usdtToken = IERC20Metadata(_usdtToken);
        priceFeed = AggregatorV3Interface(_priceFeed);
        treasuryWallet = _treasury;

        uint8 dec = IERC20Metadata(_usdtToken).decimals();
        if (dec > 18) revert Roach__UnsupportedDecimals();
        usdtDecimals = dec;

        if (_heartbeat > 0) {
            oracleHeartbeatLimit = _heartbeat;
        }

        keyHash = _keyHash;
        s_subscriptionId = _subscriptionId;
        presaleStartTime = block.timestamp;
        monthStartTime = block.timestamp;
    }

    // ================================================================
    // Exact 48-Week Pricing Engine
    // ================================================================

    function getCurrentTokensPerUSD() public view returns (uint256) {
        if (block.timestamp < presaleStartTime) {
            return baseTokensPerUSD;
        }

        uint256 elapsedWeeks = (block.timestamp - presaleStartTime) / STEP_DURATION;
        if (elapsedWeeks >= TOTAL_PRESALE_WEEKS) {
            return minTokensPerUSD; // Exactly 20 tokens/USD ($0.05)
        }

        // Linear interpolation across 48 weeks without off-by-one errors
        uint256 totalSpan = baseTokensPerUSD - minTokensPerUSD;
        uint256 reduction = (totalSpan * elapsedWeeks) / TOTAL_PRESALE_WEEKS;
        return baseTokensPerUSD - reduction;
    }

    function availableUnsoldInventory() public view returns (uint256) {
        uint256 balance = roachToken.balanceOf(address(this));
        uint256 reserved = totalReservedTokens();
        if (balance <= reserved) {
            return 0;
        }
        return balance - reserved;
    }

    function totalReservedTokens() public view returns (uint256) {
        return totalStakedPrincipal +
            stakingRewardReserve +
            monthlyRewardReserve +
            totalPendingRewards;
    }

    function verifyContractSolvency() public view returns (bool) {
        return roachToken.balanceOf(address(this)) >= totalReservedTokens();
    }

    function getLatestBNBPrice() public view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (price <= 0) revert Roach__OracleInvalidPrice();
        if (updatedAt == 0) revert Roach__OracleIncompleteRound();
        if (updatedAt > block.timestamp) revert Roach__OracleFutureTimestamp();
        if (answeredInRound < roundId) revert Roach__OracleStaleRound();
        if (block.timestamp - updatedAt > oracleHeartbeatLimit) revert Roach__OracleHeartbeatExpired();

        uint8 feedDecimals = priceFeed.decimals();
        if (feedDecimals == 18) {
            return uint256(price);
        }
        if (feedDecimals < 18) {
            return uint256(price) * (10 ** (18 - feedDecimals));
        }
        return uint256(price) / (10 ** (feedDecimals - 18));
    }

    function buyWithBNB() external payable nonReentrant {
        if (msg.value == 0) revert Roach__ZeroAmount();

        uint256 currentRate = getCurrentTokensPerUSD();
        uint256 bnbPrice = getLatestBNBPrice();
        uint256 usdValue = (msg.value * bnbPrice) / 1 ether;
        uint256 tokenAmount = (msg.value * bnbPrice * currentRate) / 1 ether;

        if (tokenAmount == 0) revert Roach__PurchaseTooSmall();
        if (availableUnsoldInventory() < tokenAmount) revert Roach__PresalePoolLow();

        _checkAndRecordContribution(msg.sender, usdValue);

        totalBNBRaised += msg.value;
        totalTokensSold += tokenAmount;

        emit TokensPurchased(msg.sender, "BNB", msg.value, tokenAmount, currentRate);

        IERC20(address(roachToken)).safeTransfer(msg.sender, tokenAmount);

        (bool success, ) = treasuryWallet.call{value: msg.value}("");
        if (!success) revert Roach__ETHTransferFailed();
    }

    function buyWithUSDT(uint256 usdtAmount) external nonReentrant {
        uint256 minUsdt = 10 * (10 ** usdtDecimals);
        if (usdtAmount < minUsdt) revert Roach__PurchaseTooSmall();

        uint256 usdValue;
        if (usdtDecimals == 18) {
            usdValue = usdtAmount;
        } else {
            usdValue = usdtAmount * (10 ** (18 - usdtDecimals));
        }

        uint256 currentRate = getCurrentTokensPerUSD();
        uint256 tokenAmount = usdValue * currentRate;

        if (tokenAmount == 0) revert Roach__PurchaseTooSmall();
        if (availableUnsoldInventory() < tokenAmount) revert Roach__PresalePoolLow();

        _checkAndRecordContribution(msg.sender, usdValue);

        totalUSDTRaised += usdValue;
        totalTokensSold += tokenAmount;

        emit TokensPurchased(msg.sender, "USDT", usdtAmount, tokenAmount, currentRate);

        IERC20(address(usdtToken)).safeTransferFrom(msg.sender, treasuryWallet, usdtAmount);
        IERC20(address(roachToken)).safeTransfer(msg.sender, tokenAmount);
    }

    function _checkAndRecordContribution(address buyer, uint256 usdValue) internal {
        if (maxMonthlyContributionPerWallet > 0) {
            uint256 newMonthly = userMonthlyContribution[currentMonthId][buyer] + usdValue;
            if (newMonthly > maxMonthlyContributionPerWallet) revert Roach__ExceedsWalletCap();
        }
        _recordContribution(buyer, usdValue);
    }

    function _recordContribution(address buyer, uint256 usdValue) internal {
        MonthlyData storage month = monthlyStats[currentMonthId];
        userMonthlyContribution[currentMonthId][buyer] += usdValue;
        month.totalUSDEquivalent += usdValue;

        if (userMonthlyContribution[currentMonthId][buyer] >= 20 * 1e18 && !hasQualified[currentMonthId][buyer]) {
            hasQualified[currentMonthId][buyer] = true;
            monthlyQualifiedParticipants[currentMonthId].push(buyer);
        }

        uint256 total = userMonthlyContribution[currentMonthId][buyer];

        for (uint256 i = 0; i < 10; i++) {
            if (month.top10Buyers[i] == buyer) {
                month.top10Amounts[i] = total;
                _sortTop10(i);
                return;
            }
        }

        if (total > month.top10Amounts[9]) {
            month.top10Amounts[9] = total;
            month.top10Buyers[9] = buyer;
            _sortTop10(9);
        }
    }

    function _sortTop10(uint256 startIndex) internal {
        MonthlyData storage month = monthlyStats[currentMonthId];
        for (uint256 i = startIndex; i > 0; i--) {
            if (month.top10Amounts[i] > month.top10Amounts[i - 1]) {
                uint256 tempAmount = month.top10Amounts[i - 1];
                address tempAddress = month.top10Buyers[i - 1];

                month.top10Amounts[i - 1] = month.top10Amounts[i];
                month.top10Buyers[i - 1] = month.top10Buyers[i];

                month.top10Amounts[i] = tempAmount;
                month.top10Buyers[i] = tempAddress;
            } else {
                break;
            }
        }
    }

    function stakeTokens(uint256 amount, uint256 durationDays) external nonReentrant {
        if (amount == 0) revert Roach__ZeroAmount();
        uint256 flatYieldBps;

        if (durationDays == 60) {
            flatYieldBps = 300;
        } else if (durationDays == 90) {
            flatYieldBps = 500;
        } else if (durationDays == 180) {
            flatYieldBps = 900;
        } else if (durationDays == 270) {
            flatYieldBps = 1400;
        } else if (durationDays == 365) {
            flatYieldBps = 2000;
        } else {
            revert Roach__InvalidDuration();
        }

        IERC20(address(roachToken)).safeTransferFrom(msg.sender, address(this), amount);
        totalStakedPrincipal += amount;

        userStakes[msg.sender].push(
            StakeInfo({
                amount: amount,
                startTime: block.timestamp,
                lockDuration: durationDays * 1 days,
                yieldBasisPoints: flatYieldBps,
                claimed: false
            })
        );

        emit TokensStaked(msg.sender, amount, durationDays, flatYieldBps);
    }

    function unstakeTokens(uint256 index) external nonReentrant {
        StakeInfo[] storage stakes = userStakes[msg.sender];
        if (index >= stakes.length) revert Roach__InvalidIndex();
        StakeInfo storage stakeInfo = stakes[index];

        if (stakeInfo.claimed) revert Roach__AlreadyClaimed();
        if (block.timestamp < stakeInfo.startTime + stakeInfo.lockDuration) revert Roach__StakeLocked();

        uint256 principal = stakeInfo.amount;
        uint256 targetReward = (principal * stakeInfo.yieldBasisPoints) / 10000;

        uint256 payoutReward = targetReward;
        uint256 shortfall = 0;

        if (stakingRewardReserve < payoutReward) {
            payoutReward = stakingRewardReserve;
            shortfall = targetReward - payoutReward;
        }

        totalStakedPrincipal -= principal;
        stakingRewardReserve -= payoutReward;
        stakeInfo.claimed = true;

        IERC20(address(roachToken)).safeTransfer(msg.sender, principal + payoutReward);

        emit TokensUnstaked(msg.sender, index, principal, payoutReward, shortfall);
    }

    function emergencyUnstakeEarly(uint256 index) external nonReentrant {
        StakeInfo[] storage stakes = userStakes[msg.sender];
        if (index >= stakes.length) revert Roach__InvalidIndex();
        StakeInfo storage stakeInfo = stakes[index];

        if (stakeInfo.claimed) revert Roach__AlreadyClaimed();

        uint256 principal = stakeInfo.amount;
        stakeInfo.claimed = true;

        uint256 penalty = (principal * 2500) / 10000;
        uint256 netPrincipal = principal - penalty;

        totalStakedPrincipal -= principal;
        stakingRewardReserve += penalty;

        IERC20(address(roachToken)).safeTransfer(msg.sender, netPrincipal);

        emit EmergencyEarlyUnstaked(msg.sender, index, netPrincipal, penalty);
    }

    function fundStakingRewardPool(uint256 amount) external onlyOwner {
        if (amount == 0) revert Roach__ZeroAmount();
        IERC20(address(roachToken)).safeTransferFrom(msg.sender, address(this), amount);
        stakingRewardReserve += amount;
        emit StakingRewardPoolFunded(amount);
    }

    function fundMonthlyRewardPool(uint256 amount) external onlyOwner {
        if (amount == 0) revert Roach__ZeroAmount();
        IERC20(address(roachToken)).safeTransferFrom(msg.sender, address(this), amount);
        monthlyRewardReserve += amount;
        emit MonthlyRewardPoolFunded(amount);
    }

    function requestMonthlyDraw(uint256 rewardTokensAllocated) external nonReentrant onlyOwner returns (uint256 requestId) {
        if (block.timestamp < monthStartTime + MONTH_DURATION) revert Roach__MonthDurationNotElapsed();
        MonthlyData storage month = monthlyStats[currentMonthId];
        if (month.drawRequested) revert Roach__DrawAlreadyRequested();
        if (rewardTokensAllocated == 0) revert Roach__ZeroAmount();
        if (monthlyRewardReserve < rewardTokensAllocated) revert Roach__MonthlyReserveLow();

        monthlyRewardReserve -= rewardTokensAllocated;
        totalPendingRewards += rewardTokensAllocated;

        month.drawRequested = true;
        month.requestTimestamp = block.timestamp;
        month.rewardPoolTokens = rewardTokensAllocated;

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        month.activeRequestId = requestId;
        vrfRequestToMonthId[requestId] = currentMonthId;

        emit MonthlyDrawRequested(currentMonthId, requestId, rewardTokensAllocated);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 monthId = vrfRequestToMonthId[requestId];
        if (monthId == 0) revert Roach__StaleOrInvalidVRF();

        MonthlyData storage month = monthlyStats[monthId];
        if (month.activeRequestId != requestId) revert Roach__StaleOrInvalidVRF();
        if (!month.drawRequested) revert Roach__DrawNotActive();
        if (month.randomnessFulfilled) revert Roach__RandomnessAlreadyFulfilled();

        month.randomSeed = randomWords[0];
        month.randomnessFulfilled = true;

        emit RandomnessReceived(monthId, randomWords[0]);
    }

    function cancelStuckVRFRequest(uint256 monthId) external nonReentrant onlyOwner {
        MonthlyData storage month = monthlyStats[monthId];
        if (!month.drawRequested) revert Roach__DrawNotActive();
        if (month.randomnessFulfilled) revert Roach__RandomnessAlreadyFulfilled();
        if (month.finalized) revert Roach__AlreadyFinalized();
        if (block.timestamp < month.requestTimestamp + 7 days) revert Roach__TimeoutPeriodActive();

        uint256 oldRequestId = month.activeRequestId;
        uint256 stuckTokens = month.rewardPoolTokens;

        month.activeRequestId = 0;
        month.drawRequested = false;
        month.rewardPoolTokens = 0;
        delete vrfRequestToMonthId[oldRequestId];

        totalPendingRewards -= stuckTokens;
        monthlyRewardReserve += stuckTokens;

        emit MonthlyDrawCancelled(monthId, stuckTokens);
    }

    function _getSparseParticipant(uint256 monthId, uint256 index) internal view returns (address) {
        address mappedAddr = sparseShuffleMap[monthId][index];
        if (mappedAddr != address(0)) {
            return mappedAddr;
        }
        return monthlyQualifiedParticipants[monthId][index];
    }

    function _settleTop10Pool(MonthlyData storage month, uint256 top10Pool) internal returns (uint256 unallocated) {
        uint256 activeWhales = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (month.top10Buyers[i] != address(0)) {
                activeWhales++;
            }
        }

        if (activeWhales == 0) return top10Pool;

        uint256[10] memory standardBps = [uint256(2000), 1500, 1000, 750, 750, 400, 400, 400, 400, 400];
        uint256 activeTotalBps = 0;
        for (uint256 i = 0; i < activeWhales; i++) {
            activeTotalBps += standardBps[i];
        }

        uint256 distributedTop10 = 0;
        for (uint256 i = 0; i < activeWhales; i++) {
            address whale = month.top10Buyers[i];
            uint256 share;
            if (i == activeWhales - 1) {
                share = top10Pool - distributedTop10;
            } else {
                share = (top10Pool * standardBps[i]) / activeTotalBps;
                distributedTop10 += share;
            }
            pendingClaimableRewards[whale] += share;
        }
        return 0;
    }

    function _settleLuckyPool(uint256 monthId, MonthlyData storage month, uint256 luckyPool, uint256 randomness) internal returns (uint256 unallocated) {
        uint256 totalParticipants = monthlyQualifiedParticipants[monthId].length;
        if (totalParticipants == 0) return luckyPool;

        uint256 winnerCount = totalParticipants < 20 ? totalParticipants : 20;
        uint256 distributedLucky = 0;

        for (uint256 j = 0; j < winnerCount; j++) {
            uint256 remaining = totalParticipants - j;
            uint256 targetIdx = j + (uint256(keccak256(abi.encode(randomness, j))) % remaining);

            address chosenWinner = _getSparseParticipant(monthId, targetIdx);
            address currentFirst = _getSparseParticipant(monthId, j);

            sparseShuffleMap[monthId][targetIdx] = currentFirst;
            sparseShuffleMap[monthId][j] = chosenWinner;
            month.luckyWinners[j] = chosenWinner;

            uint256 share;
            if (j == winnerCount - 1) {
                share = luckyPool - distributedLucky;
            } else {
                share = luckyPool / winnerCount;
                distributedLucky += share;
            }
            pendingClaimableRewards[chosenWinner] += share;
        }
        return 0;
    }

    function executeMonthlyRewardSettlement(uint256 monthId) external nonReentrant {
        if (monthId != currentMonthId) revert Roach__InvalidMonthId();
        MonthlyData storage month = monthlyStats[monthId];
        if (!month.randomnessFulfilled) revert Roach__RandomnessNotFulfilled();
        if (month.finalized) revert Roach__AlreadyFinalized();
        if (!month.drawRequested) revert Roach__DrawNotActive();

        uint256 rewardTokens = month.rewardPoolTokens;
        if (rewardTokens == 0) revert Roach__ZeroAmount();

        month.finalized = true;
        month.drawRequested = false;
        month.activeRequestId = 0;

        uint256 top10Pool = (rewardTokens * 80) / 100;
        uint256 luckyPool = rewardTokens - top10Pool;

        uint256 unallocatedRefund = _settleTop10Pool(month, top10Pool);
        unallocatedRefund += _settleLuckyPool(monthId, month, luckyPool, month.randomSeed);

        if (unallocatedRefund > 0) {
            totalPendingRewards -= unallocatedRefund;
            monthlyRewardReserve += unallocatedRefund;
        }

        uint256 distributedTokens = rewardTokens - unallocatedRefund;
        emit MonthlySettled(monthId, month.totalUSDEquivalent, distributedTokens, unallocatedRefund);

        monthStartTime = block.timestamp;
        currentMonthId++;
    }

    function claimMonthlyReward() external nonReentrant {
        uint256 amount = pendingClaimableRewards[msg.sender];
        if (amount == 0) revert Roach__NoRewardsToClaim();

        pendingClaimableRewards[msg.sender] = 0;
        totalPendingRewards -= amount;

        IERC20(address(roachToken)).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    // ================================================================
    // Cryptographically Bound Timelock Administration
    // ================================================================

    function _queue(bytes32 actionHash, string memory label) internal {
        if (queuedActions[actionHash].exists) revert Roach__ActionAlreadyQueued();
        uint256 executableAfter = block.timestamp + TIMELOCK_DELAY;
        queuedActions[actionHash] = QueuedAction({
            executableAfter: executableAfter,
            executed: false,
            exists: true
        });
        emit ActionQueued(actionHash, label, executableAfter);
    }

    function _consumeQueuedAction(bytes32 actionHash) internal {
        QueuedAction storage q = queuedActions[actionHash];
        if (!q.exists) revert Roach__ActionNotQueued();
        if (q.executed) revert Roach__ActionAlreadyExecuted();
        if (block.timestamp < q.executableAfter) revert Roach__TimelockActive();
        q.executed = true;
        delete queuedActions[actionHash];
    }

    function cancelAction(bytes32 actionHash, string calldata label) external onlyOwner {
        if (!queuedActions[actionHash].exists) revert Roach__ActionNotQueued();
        if (queuedActions[actionHash].executed) revert Roach__ActionAlreadyExecuted();
        delete queuedActions[actionHash];
        emit ActionCancelled(actionHash, label);
    }

    function queueSetTokensPerUSD(uint256 newRate) external onlyOwner returns (bytes32) {
        if (newRate == 0) revert Roach__ZeroAmount();
        bytes32 actionHash = keccak256(abi.encode("setTokensPerUSD", newRate, ++timelockNonce));
        _queue(actionHash, "setTokensPerUSD");
        return actionHash;
    }

    function executeSetTokensPerUSD(bytes32 actionHash, uint256 newRate) external onlyOwner {
        if (newRate == 0) revert Roach__ZeroAmount();
        _consumeQueuedAction(actionHash);
        tokensPerUSD = newRate;
        baseTokensPerUSD = newRate;
        emit PriceRateUpdated(newRate);
        emit ActionExecuted(actionHash, "setTokensPerUSD");
    }

    function executeSetTokensPerUSDStrict(bytes32 actionHash, uint256 newRate, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("setTokensPerUSD", newRate, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        tokensPerUSD = newRate;
        baseTokensPerUSD = newRate;
        emit PriceRateUpdated(newRate);
        emit ActionExecuted(actionHash, "setTokensPerUSD");
    }

    function queueSetExemption(address account, bool exempt) external onlyOwner returns (bytes32) {
        if (account == address(0)) revert Roach__ZeroAddress();
        bytes32 actionHash = keccak256(abi.encode("setExemption", account, exempt, ++timelockNonce));
        _queue(actionHash, "setExemption");
        return actionHash;
    }

    function executeSetExemptionStrict(bytes32 actionHash, address account, bool exempt, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("setExemption", account, exempt, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        emit ActionExecuted(actionHash, "setExemption");
        roachToken.setExemption(account, exempt);
    }

    function queueWithdrawUnsoldTokens(uint256 amount) external onlyOwner returns (bytes32) {
        if (amount == 0) revert Roach__ZeroAmount();
        bytes32 actionHash = keccak256(abi.encode("withdrawUnsold", amount, ++timelockNonce));
        _queue(actionHash, "withdrawUnsoldTokens");
        return actionHash;
    }

    function executeWithdrawUnsoldTokensStrict(bytes32 actionHash, uint256 amount, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("withdrawUnsold", amount, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        if (availableUnsoldInventory() < amount) revert Roach__ExceedsFreeInventory();
        emit UnsoldTokensWithdrawn(amount);
        emit ActionExecuted(actionHash, "withdrawUnsoldTokens");
        IERC20(address(roachToken)).safeTransfer(owner(), amount);
    }

    function queueMilestoneBurn(uint256 amountToBurn, string calldata milestoneName) external onlyOwner returns (bytes32) {
        if (amountToBurn == 0) revert Roach__ZeroAmount();
        bytes32 actionHash = keccak256(abi.encode("milestoneBurn", amountToBurn, milestoneName, ++timelockNonce));
        _queue(actionHash, "executeMilestoneBurn");
        return actionHash;
    }

    function executeMilestoneBurnStrict(bytes32 actionHash, uint256 amountToBurn, string calldata milestoneName, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("milestoneBurn", amountToBurn, milestoneName, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        if (availableUnsoldInventory() < amountToBurn) revert Roach__ExceedsFreeInventory();
        emit MilestoneBurnExecuted(amountToBurn, milestoneName);
        emit ActionExecuted(actionHash, "executeMilestoneBurn");
        roachToken.burn(amountToBurn);
    }

    function queueSetMaxMonthlyContribution(uint256 usdCap) external onlyOwner returns (bytes32) {
        bytes32 actionHash = keccak256(abi.encode("setMaxMonthlyContribution", usdCap, ++timelockNonce));
        _queue(actionHash, "setMaxMonthlyContribution");
        return actionHash;
    }

    function executeSetMaxMonthlyContributionStrict(bytes32 actionHash, uint256 usdCap, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("setMaxMonthlyContribution", usdCap, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        maxMonthlyContributionPerWallet = usdCap;
        emit ActionExecuted(actionHash, "setMaxMonthlyContribution");
    }

    function queueUpdateTreasury(address payable newTreasury) external onlyOwner returns (bytes32) {
        if (newTreasury == address(0)) revert Roach__ZeroAddress();
        bytes32 actionHash = keccak256(abi.encode("updateTreasury", newTreasury, ++timelockNonce));
        _queue(actionHash, "updateTreasury");
        return actionHash;
    }

    function executeUpdateTreasuryStrict(bytes32 actionHash, address payable newTreasury, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("updateTreasury", newTreasury, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        treasuryWallet = newTreasury;
        emit TreasuryUpdated(newTreasury);
        emit ActionExecuted(actionHash, "updateTreasury");
    }

    function queueSetOracleHeartbeat(uint256 newHeartbeat) external onlyOwner returns (bytes32) {
        if (newHeartbeat == 0) revert Roach__ZeroAmount();
        bytes32 actionHash = keccak256(abi.encode("setOracleHeartbeat", newHeartbeat, ++timelockNonce));
        _queue(actionHash, "setOracleHeartbeat");
        return actionHash;
    }

    function executeSetOracleHeartbeatStrict(bytes32 actionHash, uint256 newHeartbeat, uint256 nonce) external onlyOwner {
        if (keccak256(abi.encode("setOracleHeartbeat", newHeartbeat, nonce)) != actionHash) {
            revert Roach__ParameterMismatch();
        }
        _consumeQueuedAction(actionHash);
        oracleHeartbeatLimit = newHeartbeat;
        emit OracleHeartbeatUpdated(newHeartbeat);
        emit ActionExecuted(actionHash, "setOracleHeartbeat");
    }

    function queueSetVRFParameters(
        bytes32 newKeyHash,
        uint256 newSubscriptionId,
        uint32 newCallbackGasLimit,
        uint16 newRequestConfirmations
    ) external onlyOwner returns (bytes32) {
        if (newKeyHash == bytes32(0)) revert Roach__ZeroAddress();
        if (newSubscriptionId == 0 || newCallbackGasLimit == 0 || newRequestConfirmations == 0) revert Roach__ZeroAmount();

        bytes32 actionHash = keccak256(
            abi.encode(
                "setVRF",
                newKeyHash,
                newSubscriptionId,
                newCallbackGasLimit,
                newRequestConfirmations,
                ++timelockNonce
            )
        );
        _queue(actionHash, "setVRFParameters");
        return actionHash;
    }

    function executeSetVRFParametersStrict(
        bytes32 actionHash,
        bytes32 newKeyHash,
        uint256 newSubscriptionId,
        uint32 newCallbackGasLimit,
        uint16 newRequestConfirmations,
        uint256 nonce
    ) external onlyOwner {
        bytes32 expectedHash = keccak256(
            abi.encode(
                "setVRF",
                newKeyHash,
                newSubscriptionId,
                newCallbackGasLimit,
                newRequestConfirmations,
                nonce
            )
        );
        if (expectedHash != actionHash) {
            revert Roach__ParameterMismatch();
        }

        _consumeQueuedAction(actionHash);
        keyHash = newKeyHash;
        s_subscriptionId = newSubscriptionId;
        callbackGasLimit = newCallbackGasLimit;
        requestConfirmations = newRequestConfirmations;

        emit ActionExecuted(actionHash, "setVRFParameters");
    }

    // ================================================================
    // Backward Compatibility Wrappers (For Prior Foundry Tests)
    // ================================================================

    function executeSetExemption(bytes32 actionHash, address account, bool exempt) external onlyOwner {
        _consumeQueuedAction(actionHash);
        emit ActionExecuted(actionHash, "setExemption");
        roachToken.setExemption(account, exempt);
    }

    function executeWithdrawUnsoldTokens(bytes32 actionHash, uint256 amount) external onlyOwner {
        _consumeQueuedAction(actionHash);
        if (availableUnsoldInventory() < amount) revert Roach__ExceedsFreeInventory();
        emit UnsoldTokensWithdrawn(amount);
        emit ActionExecuted(actionHash, "withdrawUnsoldTokens");
        IERC20(address(roachToken)).safeTransfer(owner(), amount);
    }

    function executeMilestoneBurn(bytes32 actionHash, uint256 amountToBurn, string calldata milestoneName) external onlyOwner {
        _consumeQueuedAction(actionHash);
        if (availableUnsoldInventory() < amountToBurn) revert Roach__ExceedsFreeInventory();
        emit MilestoneBurnExecuted(amountToBurn, milestoneName);
        emit ActionExecuted(actionHash, "executeMilestoneBurn");
        roachToken.burn(amountToBurn);
    }

    function executeSetMaxMonthlyContribution(bytes32 actionHash, uint256 usdCap) external onlyOwner {
        _consumeQueuedAction(actionHash);
        maxMonthlyContributionPerWallet = usdCap;
        emit ActionExecuted(actionHash, "setMaxMonthlyContribution");
    }

    function executeUpdateTreasury(bytes32 actionHash, address payable newTreasury) external onlyOwner {
        _consumeQueuedAction(actionHash);
        treasuryWallet = newTreasury;
        emit TreasuryUpdated(newTreasury);
        emit ActionExecuted(actionHash, "updateTreasury");
    }

    function executeSetOracleHeartbeat(bytes32 actionHash, uint256 newHeartbeat) external onlyOwner {
        _consumeQueuedAction(actionHash);
        oracleHeartbeatLimit = newHeartbeat;
        emit OracleHeartbeatUpdated(newHeartbeat);
        emit ActionExecuted(actionHash, "setOracleHeartbeat");
    }

    function executeSetVRFParameters(
        bytes32 actionHash,
        bytes32 newKeyHash,
        uint256 newSubscriptionId,
        uint32 newCallbackGasLimit,
        uint16 newRequestConfirmations
    ) external onlyOwner {
        _consumeQueuedAction(actionHash);
        keyHash = newKeyHash;
        s_subscriptionId = newSubscriptionId;
        callbackGasLimit = newCallbackGasLimit;
        requestConfirmations = newRequestConfirmations;
        emit ActionExecuted(actionHash, "setVRFParameters");
    }

    // ================================================================
    // View Helpers
    // ================================================================

    function getUserStakeCount(address user) external view returns (uint256) {
        return userStakes[user].length;
    }

    function getMonthlyParticipantCount(uint256 monthId) external view returns (uint256) {
        return monthlyQualifiedParticipants[monthId].length;
    }

    function getMonthlyParticipant(uint256 monthId, uint256 index) external view returns (address) {
        if (index >= monthlyQualifiedParticipants[monthId].length) revert Roach__InvalidIndex();
        return monthlyQualifiedParticipants[monthId][index];
    }

    function accountingStatus()
        external
        view
        returns (
            uint256 tokenBalance,
            uint256 stakedPrincipal,
            uint256 stakingReserve,
            uint256 monthlyReserve,
            uint256 pendingRewards,
            uint256 freeInventory
        )
    {
        tokenBalance = roachToken.balanceOf(address(this));
        stakedPrincipal = totalStakedPrincipal;
        stakingReserve = stakingRewardReserve;
        monthlyReserve = monthlyRewardReserve;
        pendingRewards = totalPendingRewards;
        freeInventory = availableUnsoldInventory();
    }

    receive() external payable {
        revert Roach__DirectPaymentNotAllowed();
    }

    fallback() external payable {
        revert Roach__InvalidCall();
    }
}
