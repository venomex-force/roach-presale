// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CockroachAI, RoachPresalePro} from "../src/RoachPresalePro.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAggregator {
    uint8 public decimals = 8;
    int256 public price = 600 * 1e8; // $600 BNB

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether", "USDT") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }
}

contract RoachPresaleProTest is Test {
    CockroachAI token;
    RoachPresalePro presale;
    MockUSDT usdt;
    MockAggregator feed;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new CockroachAI();
        usdt = new MockUSDT();
        feed = new MockAggregator();

        presale = new RoachPresalePro(
            address(token),
            address(usdt),
            address(feed),
            address(0x1),
            bytes32(0),
            1,
            payable(treasury),
            300
        );

        token.setPresaleContract(address(presale));
        token.transfer(address(presale), 500_000_000 * 1e18);

        token.approve(address(presale), 50_000_000 * 1e18);
        presale.fundStakingRewardPool(20_000_000 * 1e18);

        vm.deal(alice, 10 ether);
        usdt.transfer(alice, 1000 * 1e18);
    }

    function test_InitialBNBPurchase() public {
        vm.startPrank(alice);
        presale.buyWithBNB{value: 1 ether}();
        vm.stopPrank();

        // 1 BNB @ $600 * 1000 tokens/USD = 600,000 ROACH
        assertEq(token.balanceOf(alice), 600_000 * 1e18);
        assertEq(treasury.balance, 1 ether);
    }

    function test_PricingHikeAndFloorFreeze() public {
        assertEq(presale.getCurrentTokensPerUSD(), 1000);

        // 1 Week baad (Rate -20)
        vm.warp(block.timestamp + 7 days);
        assertEq(presale.getCurrentTokensPerUSD(), 980);

        // 50 Weeks baad ($0.05 cap test -> 20 tokens/USD)
        vm.warp(block.timestamp + (50 * 7 days));
        assertEq(presale.getCurrentTokensPerUSD(), 20);
    }

    function test_EarlyUnstake25PercentPenalty() public {
        vm.startPrank(alice);
        presale.buyWithBNB{value: 1 ether}();

        token.approve(address(presale), 10_000 * 1e18);
        presale.stakeTokens(10_000 * 1e18, 60);

        presale.emergencyUnstakeEarly(0);
        vm.stopPrank();

        // 600k total - 10k staked + 7.5k returned = 597,500 ROACH
        assertEq(token.balanceOf(alice), 597_500 * 1e18);
    }
}
