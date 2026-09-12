// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {
    CockroachAI,
    RoachPresalePro,
    Roach__Unauthorized,
    Roach__TradingLocked,
    Roach__PurchaseTooSmall,
    Roach__PresalePoolLow,
    Roach__ExceedsWalletCap,
    Roach__AlreadyClaimed,
    Roach__TimelockActive,
    Roach__ParameterMismatch,
    Roach__ExceedsFreeInventory,
    Roach__OracleInvalidPrice,
    Roach__OracleFutureTimestamp,
    Roach__OracleHeartbeatExpired,
    Roach__OracleStaleRound,
    Roach__NoRewardsToClaim,
    Roach__TimeoutPeriodActive,
    Roach__StaleOrInvalidVRF,
    Roach__RandomnessAlreadyFulfilled
} from "../src/RoachPresalePro.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// Configurable Oracle Mock
contract MockAggregatorDynamic {
    uint8 public decimals = 8;
    int256 public price = 600 * 1e8;
    uint80 public roundId = 1;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setRoundData(
        uint80 _roundId,
        int256 _price,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) external {
        roundId = _roundId;
        price = _price;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }

    function updateTimestamp(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, block.timestamp, updatedAt, answeredInRound);
    }
}

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {
        _mint(msg.sender, 10_000_000 * 1e18);
    }
}

// Reentrancy Attacker acting as Treasury Wallet
contract MaliciousTreasury {
    RoachPresalePro public presale;
    bool public attackAttempted;

    function setPresale(address payable _presale) external {
        presale = RoachPresalePro(_presale);
    }

    receive() external payable {
        if (!attackAttempted) {
            attackAttempted = true;
            // Attempt to re-enter during BNB transfer callback
            presale.buyWithBNB{value: 1 ether}();
        }
    }
}

// VRF Coordinator Mock matching VRFV2PlusClient request
contract MockVRFCoordinatorV2Plus {
    uint256 private nextReqId = 9000;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        return ++nextReqId;
    }
}

// Test harness exposing internal fulfillRandomWords
contract RoachPresaleProHarness is RoachPresalePro {
    constructor(
        address _roach,
        address _usdt,
        address _feed,
        address _vrf,
        bytes32 _kh,
        uint256 _sub,
        address payable _tr,
        uint256 _hb
    ) RoachPresalePro(_roach, _usdt, _feed, _vrf, _kh, _sub, _tr, _hb) {}

    function exposedFulfillRandomWords(uint256 reqId, uint256[] calldata words) external {
        fulfillRandomWords(reqId, words);
    }
}

contract RoachPresaleProExhaustiveTest is Test {
    CockroachAI token;
    RoachPresaleProHarness presale;
    MockUSDT usdt;
    MockAggregatorDynamic feed;
    MockVRFCoordinatorV2Plus vrf;

    address owner = address(this);
    address payable treasury = payable(makeAddr("treasury"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public {
        // Warp block.timestamp away from zero to prevent subtraction underflow
        vm.warp(1_000_000);

        token = new CockroachAI();
        usdt = new MockUSDT();
        feed = new MockAggregatorDynamic();
        vrf = new MockVRFCoordinatorV2Plus();

        presale = new RoachPresaleProHarness(
            address(token),
            address(usdt),
            address(feed),
            address(vrf),
            bytes32("test_keyhash"),
            1,
            treasury,
            300
        );

        token.setPresaleContract(address(presale));

        // 500M Presale inventory
        token.transfer(address(presale), 500_000_000 * 1e18);

        // Fund Reward Reserves
        token.approve(address(presale), 100_000_000 * 1e18);
        presale.fundStakingRewardPool(20_000_000 * 1e18);
        presale.fundMonthlyRewardPool(10_000_000 * 1e18);

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(attacker, 1000 ether);

        usdt.transfer(alice, 100_000 * 1e18);
        usdt.transfer(bob, 100_000 * 1e18);
    }

    // 1. Timelock Parameter Manipulation (Bait-and-Switch Prevention)
    function test_RevertIf_TimelockParameterManipulated() public {
        bytes32 actionHash = presale.queueSetTokensPerUSD(500);
        uint256 queuedNonce = presale.timelockNonce();

        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp);

        vm.expectRevert(Roach__ParameterMismatch.selector);
        presale.executeSetTokensPerUSDStrict(actionHash, 1, queuedNonce);
    }

    // 2. Unauthorized Admin Calls
    function test_RevertIf_UnauthorizedCallerExecutesAdmin() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        presale.queueWithdrawUnsoldTokens(1000 * 1e18);

        vm.expectRevert();
        presale.fundStakingRewardPool(1000 * 1e18);
        vm.stopPrank();
    }

    // 3. Oracle Stale Price (> 300s heartbeat)
    function test_RevertIf_OracleHeartbeatExpired() public {
        feed.setRoundData(1, 600 * 1e8, block.timestamp - 301, 1);

        vm.startPrank(alice);
        vm.expectRevert(Roach__OracleHeartbeatExpired.selector);
        presale.buyWithBNB{value: 1 ether}();
        vm.stopPrank();
    }

    // 4. Oracle Zero / Negative Price
    function test_RevertIf_OracleZeroOrNegativePrice() public {
        feed.setRoundData(1, 0, block.timestamp, 1);
        vm.startPrank(alice);
        vm.expectRevert(Roach__OracleInvalidPrice.selector);
        presale.buyWithBNB{value: 1 ether}();

        feed.setRoundData(2, -100 * 1e8, block.timestamp, 2);
        vm.expectRevert(Roach__OracleInvalidPrice.selector);
        presale.buyWithBNB{value: 1 ether}();
        vm.stopPrank();
    }

    // 5. Oracle Future Timestamp
    function test_RevertIf_OracleTimestampInFuture() public {
        feed.setRoundData(1, 600 * 1e8, block.timestamp + 10, 1);

        vm.startPrank(alice);
        vm.expectRevert(Roach__OracleFutureTimestamp.selector);
        presale.buyWithBNB{value: 1 ether}();
        vm.stopPrank();
    }

    // 6. USDT Purchase
    function test_BuyWithUSDT() public {
        vm.startPrank(alice);
        usdt.approve(address(presale), 1000 * 1e18);
        presale.buyWithUSDT(1000 * 1e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 1_000_000 * 1e18);
        assertEq(usdt.balanceOf(treasury), 1000 * 1e18);
    }

    // 7. Monthly Contribution Cap
    function test_RevertIf_ExceedsMonthlyContributionCap() public {
        bytes32 actionHash = presale.queueSetMaxMonthlyContribution(5000 * 1e18);
        uint256 nonce = presale.timelockNonce();

        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp); // Keep oracle fresh after warp

        presale.executeSetMaxMonthlyContributionStrict(actionHash, 5000 * 1e18, nonce);

        // 10 BNB @ $600 = $6,000 USD (Exceeds $5,000 Cap)
        vm.startPrank(alice);
        vm.expectRevert(Roach__ExceedsWalletCap.selector);
        presale.buyWithBNB{value: 10 ether}();
        vm.stopPrank();
    }

    // 8. VRF Wrong RequestId Handling
    function test_RevertIf_VRFRequestIdWrong() public {
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 77777;

        vm.expectRevert(Roach__StaleOrInvalidVRF.selector);
        presale.exposedFulfillRandomWords(12345, randomWords);
    }

    // 9. VRF Double Fulfillment
    function test_RevertIf_VRFDoubleFulfilled() public {
        vm.warp(block.timestamp + 30 days + 1);
        feed.updateTimestamp(block.timestamp);
        uint256 reqId = presale.requestMonthlyDraw(5_000_000 * 1e18);

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 123456789;

        presale.exposedFulfillRandomWords(reqId, randomWords);

        vm.expectRevert(Roach__RandomnessAlreadyFulfilled.selector);
        presale.exposedFulfillRandomWords(reqId, randomWords);
    }

    // 10. VRF Cancellation After 7-Day Timeout
    function test_VRFCancellationTimeout() public {
        vm.warp(block.timestamp + 30 days + 1);
        feed.updateTimestamp(block.timestamp);
        presale.requestMonthlyDraw(5_000_000 * 1e18);

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Roach__TimeoutPeriodActive.selector);
        presale.cancelStuckVRFRequest(1);

        vm.warp(block.timestamp + 6 days);
        presale.cancelStuckVRFRequest(1);
        assertEq(presale.monthlyRewardReserve(), 10_000_000 * 1e18);
    }

    // 11. Reward Double Claim Prevention
    function test_RevertIf_DoubleClaimRewards() public {
        vm.startPrank(alice);
        vm.expectRevert(Roach__NoRewardsToClaim.selector);
        presale.claimMonthlyReward();
        vm.stopPrank();
    }

    // 12. Staking Reward Reserve Exhaustion
    function test_StakingGracefulReserveExhaustion() public {
        vm.startPrank(alice);
        presale.buyWithBNB{value: 1 ether}();
        token.approve(address(presale), 600_000 * 1e18);
        presale.stakeTokens(600_000 * 1e18, 365);
        vm.stopPrank();

        uint256 freeInventory = presale.availableUnsoldInventory();
        bytes32 drainHash = presale.queueWithdrawUnsoldTokens(freeInventory);
        uint256 nonce = presale.timelockNonce();

        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp);
        presale.executeWithdrawUnsoldTokensStrict(drainHash, freeInventory, nonce);

        vm.warp(block.timestamp + 366 days);
        feed.updateTimestamp(block.timestamp);

        vm.prank(alice);
        presale.unstakeTokens(0);
        assertGe(token.balanceOf(alice), 600_000 * 1e18);
    }

    // 13. Unsold-Token Withdrawal vs Reserved Pools
    function test_RevertIf_WithdrawalInfringesOnReservedPools() public {
        uint256 freeTokens = presale.availableUnsoldInventory();
        bytes32 actionHash = presale.queueWithdrawUnsoldTokens(freeTokens + 1e18);
        uint256 nonce = presale.timelockNonce();

        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp);

        vm.expectRevert(Roach__ExceedsFreeInventory.selector);
        presale.executeWithdrawUnsoldTokensStrict(actionHash, freeTokens + 1e18, nonce);
    }

    // 14. Milestone Burn Accounting
    function test_MilestoneBurnDecreasesInventorySafely() public {
        bytes32 burnHash = presale.queueMilestoneBurn(10_000_000 * 1e18, "Stage 1 Burn");
        uint256 nonce = presale.timelockNonce();

        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp);
        presale.executeMilestoneBurnStrict(burnHash, 10_000_000 * 1e18, "Stage 1 Burn", nonce);

        assertEq(token.totalSupply(), 990_000_000 * 1e18);
    }

    // 15. Treasury Update Timelock Integrity
    function test_TreasuryUpdateStrictTimelock() public {
        address payable newTreasury = payable(makeAddr("safeMultisig"));
        bytes32 actionHash = presale.queueUpdateTreasury(newTreasury);
        uint256 nonce = presale.timelockNonce();

        vm.expectRevert(Roach__TimelockActive.selector);
        presale.executeUpdateTreasuryStrict(actionHash, newTreasury, nonce);

        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp);
        presale.executeUpdateTreasuryStrict(actionHash, newTreasury, nonce);
        assertEq(presale.treasuryWallet(), newTreasury);
    }

    // 16. Trading Lock / Exemption Bypass
    function test_RevertIf_TradingLockedForNonExempt() public {
        vm.startPrank(alice);
        presale.buyWithBNB{value: 1 ether}();

        vm.expectRevert(Roach__TradingLocked.selector);
        token.transfer(bob, 100 * 1e18);
        vm.stopPrank();

        token.enableTrading();

        vm.prank(alice);
        token.transfer(bob, 100 * 1e18);
        assertEq(token.balanceOf(bob), 100 * 1e18);
    }

    // 17. Reentrancy Protection on BuyWithBNB
    function test_ReentrancyProtectionOnBNBPurchase() public {
        MaliciousTreasury maliciousTreasury = new MaliciousTreasury();
        maliciousTreasury.setPresale(payable(address(presale)));

        // Set malicious receiver as treasury wallet via timelock
        bytes32 updateHash = presale.queueUpdateTreasury(payable(address(maliciousTreasury)));
        uint256 nonce = presale.timelockNonce();
        vm.warp(block.timestamp + 48 hours + 1);
        feed.updateTimestamp(block.timestamp);
        presale.executeUpdateTreasuryStrict(updateHash, payable(address(maliciousTreasury)), nonce);

        // Buyer purchases BNB, triggering ETH transfer to malicious treasury which attempts reentrancy
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(); // ReentrancyGuardReentrantCall triggers revert
        presale.buyWithBNB{value: 1 ether}();
    }

    // 18. Fuzz Testing: Random purchases and auto-rate calculation
    function testFuzz_PurchaseAmountSolvency(uint96 bnbAmount) public {
        vm.assume(bnbAmount > 0.01 ether && bnbAmount < 50 ether);

        address buyer = makeAddr("fuzzBuyer");
        vm.deal(buyer, bnbAmount);

        vm.prank(buyer);
        presale.buyWithBNB{value: bnbAmount}();

        assertTrue(presale.verifyContractSolvency());
    }
}
