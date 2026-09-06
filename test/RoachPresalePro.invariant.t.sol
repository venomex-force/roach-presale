// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RoachPresalePro, CockroachAI, AggregatorV3Interface} from "../src/RoachPresalePro.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract Handler is Test {
    RoachPresalePro public presale;
    CockroachAI public token;
    address public user = address(0x999);

    constructor(RoachPresalePro _presale, CockroachAI _token) {
        presale = _presale;
        token = _token;
    }

    function buyWithBNB(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 5 ether);
        vm.deal(user, amount);
        vm.prank(user);
        presale.buyWithBNB{value: amount}();
    }

    function stake(uint256 durationIndex) public {
        uint256 userBal = token.balanceOf(user);
        if (userBal == 0) return;

        uint256 duration = 60;
        if (durationIndex % 5 == 1) duration = 90;
        if (durationIndex % 5 == 2) duration = 180;
        if (durationIndex % 5 == 3) duration = 270;
        if (durationIndex % 5 == 4) duration = 365;

        vm.startPrank(user);
        token.approve(address(presale), userBal);
        presale.stakeTokens(userBal, duration);
        vm.stopPrank();
    }
}

contract RoachPresaleProInvariant is StdInvariant, Test {
    RoachPresalePro public presale;
    CockroachAI public token;
    MockUSDT public usdt;
    MockAggregator public feed;
    Handler public handler;

    function setUp() public {
        token = new CockroachAI();
        usdt = new MockUSDT();
        feed = new MockAggregator();

        presale = new RoachPresalePro(
            address(token),
            address(usdt),
            address(feed),
            address(0xBBBB),
            bytes32(0),
            1,
            payable(address(0xAAAA)),
            120
        );

        token.setPresaleContract(address(presale));
        token.transfer(address(presale), 500_000_000 * 1e18);

        handler = new Handler(presale, token);
        targetContract(address(handler));
    }

    // Invariant: Contract must never become insolvent regardless of call sequences
    function invariant_SolvencyAlwaysMaintained() public view {
        assertTrue(presale.verifyContractSolvency());
    }

    // Invariant: Reserved accounting must not exceed current token balance
    function invariant_AccountingReservoirIntegrity() public view {
        assertGe(token.balanceOf(address(presale)), presale.totalReservedTokens());
    }
}
