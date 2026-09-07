// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract CockroachAI is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    address public presaleContract;
    mapping(address => bool) public isExempt;

    constructor() ERC20("Cockroach AI", "ROACH") Ownable(msg.sender) {
        isExempt[msg.sender] = true;
        _mint(msg.sender, MAX_SUPPLY);
    }

    function setPresaleContract(address _presale) external onlyOwner {
        presaleContract = _presale;
        isExempt[_presale] = true;
    }
}

contract RoachPresalePro is Ownable {
    IERC20 public immutable roachToken;
    IERC20 public immutable usdtToken;
    AggregatorV3Interface public immutable priceFeed;
    address payable public treasury;

    // Pricing & Stages
    uint256 public constant TOTAL_STAGES = 5;
    uint256[5] public stagePrices = [0.0010 * 1e18, 0.0015 * 1e18, 0.0022 * 1e18, 0.0030 * 1e18, 0.0040 * 1e18];
    uint256[5] public stageCaps = [100_000_000 * 1e18, 100_000_000 * 1e18, 100_000_000 * 1e18, 100_000_000 * 1e18, 100_000_000 * 1e18];
    
    uint256 public currentStage = 0;
    uint256 public currentStageSold = 0;
    uint256 public totalTokensSold = 0;
    uint256 public totalUsdRaised = 0;

    // Staking Pool (High Dynamic APY)
    uint256 public stakingPoolSupply;
    uint256 public constant REWARD_RATE_PER_SECOND = 150; // High APY baseline
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakingTimestamp;

    // Referrals & Leaderboard
    uint256 public constant REFERRAL_PERCENT = 10; // 10% instant bonus
    mapping(address => uint256) public userPurchases;
    mapping(address => uint256) public referralEarnings;
    address[] public leaderboard;

    event TokensPurchased(address indexed buyer, uint256 amount, uint256 costUsd, address indexed referrer);
    event Staked(address indexed user, uint256 amount);

    constructor(
        address _roachToken,
        address _usdtToken,
        address _priceFeed,
        address payable _treasury
    ) Ownable(msg.sender) {
        roachToken = IERC20(_roachToken);
        usdtToken = IERC20(_usdtToken);
        priceFeed = AggregatorV3Interface(_priceFeed);
        treasury = _treasury;
    }

    function getLatestBnbPrice() public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Oracle Error");
        return uint256(price) * 1e10; // 18 decimals
    }

    function buyWithBNB(address referrer) external payable {
        require(msg.value > 0, "Send BNB");
        uint256 bnbPrice = getLatestBnbPrice();
        uint256 usdValue = (msg.value * bnbPrice) / 1e18;
        
        uint256 tokenAmount = (usdValue * 1e18) / stagePrices[currentStage];
        _processPurchase(msg.sender, tokenAmount, usdValue, referrer);

        // Instant 10% Referral Payout in BNB
        if (referrer != address(0) && referrer != msg.sender) {
            uint256 refBonus = (msg.value * REFERRAL_PERCENT) / 100;
            payable(referrer).transfer(refBonus);
            referralEarnings[referrer] += (usdValue * REFERRAL_PERCENT) / 100;
            treasury.transfer(address(this).balance);
        } else {
            treasury.transfer(address(this).balance);
        }
    }

    function buyWithUSDT(uint256 usdtAmount, address referrer) external {
        require(usdtAmount > 0, "Send USDT");
        usdtToken.transferFrom(msg.sender, address(this), usdtAmount);

        uint256 tokenAmount = (usdtAmount * 1e18) / stagePrices[currentStage];
        _processPurchase(msg.sender, tokenAmount, usdtAmount, referrer);

        // Instant 10% Referral Payout in USDT
        if (referrer != address(0) && referrer != msg.sender) {
            uint256 refBonus = (usdtAmount * REFERRAL_PERCENT) / 100;
            usdtToken.transfer(referrer, refBonus);
            referralEarnings[referrer] += refBonus;
            usdtToken.transfer(treasury, usdtToken.balanceOf(address(this)));
        } else {
            usdtToken.transfer(treasury, usdtToken.balanceOf(address(this)));
        }
    }

    function _processPurchase(address buyer, uint256 tokenAmount, uint256 usdValue, address referrer) internal {
        currentStageSold += tokenAmount;
        totalTokensSold += tokenAmount;
        totalUsdRaised += usdValue;

        if (userPurchases[buyer] == 0) {
            leaderboard.push(buyer);
        }
        userPurchases[buyer] += usdValue;

        // Auto Advance Stage if Cap Exceeded
        if (currentStageSold >= stageCaps[currentStage] && currentStage < TOTAL_STAGES - 1) {
            currentStage++;
            currentStageSold = 0;
        }

        // Direct transfer of tokens to buyer
        roachToken.transfer(buyer, tokenAmount);
        emit TokensPurchased(buyer, tokenAmount, usdValue, referrer);
    }

    function fundStakingPool(uint256 amount) external onlyOwner {
        roachToken.transferFrom(msg.sender, address(this), amount);
        stakingPoolSupply += amount;
    }
}
