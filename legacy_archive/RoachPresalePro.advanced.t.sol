// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {RoachPresalePro, CockroachAI, AggregatorV3Interface} from "../src/RoachPresalePro.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock VRF Coordinator v2.5
contract MockVRFCoordinator {
    uint256 public nextRequestId = 1;
    address public consumer;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        consumer = msg.sender;
        return nextRequestId++;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        consumer = msg.sender;
        return abi.encode(nextRequestId++);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        VRFConsumerBaseV2Plus(consumer).rawFulfillRandomWords(requestId, randomWords);
    }
}

contract MockAggregator is AggregatorV3Interface {
    uint8 public override decimals = 8;
    int256 public answer = 600 * 1e8;

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {
        _mint(msg.sender, 1_000_000_000 * 1e18);
    }
}

contract RoachPresaleProAdvancedTest is Test {
    CockroachAI public token;
    RoachPresalePro public presale;
    MockUSDT public usdt;
    MockAggregator public feed;
    MockVRFCoordinator public vrfCoordinator;

    address public owner = address(this);
    address payable public treasury = payable(address(0xAAAA));
    address public buyer1 = address(0x101);
    address public buyer2 = address(0x102);

    function setUp() public {
        token = new CockroachAI();
        usdt = new MockUSDT();
        feed = new MockAggregator();
        vrfCoordinator = new MockVRFCoordinator();

        presale = new RoachPresalePro(
            address(token),
            address(usdt),
            address(feed),
            address(vrfCoordinator),
            bytes32(0),
            1,
            treasury,
            120
        );

        token.setPresaleContract(address(presale));
        token.transfer(address(presale), 500_000_000 * 1e18);

        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
    }

    // 1. Monthly VRF Draw & Settlement Flow
    function test_MonthlyVRFDrawAndSettlement() public {
        vm.prank(buyer1);
        presale.buyWithBNB{value: 2 ether}();

        vm.prank(buyer2);
        presale.buyWithBNB{value: 1 ether}();

        uint256 poolReward = 100_000 * 1e18;
        token.approve(address(presale), poolReward);
        presale.fundMonthlyRewardPool(poolReward);

        vm.warp(block.timestamp + 31 days);

        uint256 requestId = presale.requestMonthlyDraw(poolReward);

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 777888999;
        vrfCoordinator.fulfillRandomWords(requestId, randomWords);

        presale.executeMonthlyRewardSettlement(1);

        uint256 pending1 = presale.pendingClaimableRewards(buyer1);
        uint256 pending2 = presale.pendingClaimableRewards(buyer2);

        assertTrue(pending1 > 0);
        assertTrue(pending2 > 0);

        vm.prank(buyer1);
        presale.claimMonthlyReward();
        assertEq(presale.pendingClaimableRewards(buyer1), 0);
    }

    // 2. 48-Hour Timelock Actions
    function test_TimelockedRateChange() public {
        uint256 newRate = 2000;

        bytes32 actionHash = presale.queueSetTokensPerUSD(newRate);

        vm.expectRevert();
        presale.executeSetTokensPerUSD(actionHash, newRate);

        vm.warp(block.timestamp + 48 hours + 1 seconds);

        presale.executeSetTokensPerUSD(actionHash, newRate);

        assertEq(presale.tokensPerUSD(), newRate);
    }

    // 3. Timelocked Milestone Burn
    function test_TimelockedMilestoneBurn() public {
        uint256 burnAmount = 10_000_000 * 1e18;
        string memory milestone = "Stage 1 Target Hit";

        bytes32 actionHash = presale.queueMilestoneBurn(burnAmount, milestone);

        vm.warp(block.timestamp + 48 hours + 1 seconds);

        uint256 supplyBefore = token.totalSupply();
        presale.executeMilestoneBurn(actionHash, burnAmount, milestone);
        uint256 supplyAfter = token.totalSupply();

        assertEq(supplyBefore - supplyAfter, burnAmount);
    }
}
