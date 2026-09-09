// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/CockroachToken.sol";
import "../contracts/RoachPresalePro.sol";

contract MockStakingVault {
    IERC20 public token;
    mapping(address => uint256) public balances;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function stake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }
}

contract CockroachProtocolTest is Test {
    CockroachToken public roach;
    RoachPresalePro public presale;
    MockStakingVault public vault;

    address public owner = address(0xABCD);
    address public buyer1 = address(0x1111);
    address public buyer2 = address(0x2222);

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Token (1 Billion Supply)
        roach = new CockroachToken("CockroachAI", "ROACH", 1_000_000_000);

        // 2. Deploy Presale Contract
        presale = new RoachPresalePro(address(roach));

        // 3. Deploy Mock Staking Vault
        vault = new MockStakingVault(address(roach));

        // 4. Whitelist Presale & Staking Vault
        roach.setExemption(address(presale), true);
        roach.setExemption(address(vault), true);

        // 5. Fund Presale with 400M tokens
        roach.transfer(address(presale), 400_000_000 * 1e18);

        vm.stopPrank();

        vm.deal(buyer1, 10 ether);
        vm.deal(buyer2, 10 ether);
    }

    function test_DirectWalletDeliveryOnBuy() public {
        vm.prank(buyer1);
        presale.buyWithBNB{value: 1 ether}();

        // 1 BNB = 600,000 $ROACH
        uint256 expectedTokens = 600_000 * 1e18;
        assertEq(roach.balanceOf(buyer1), expectedTokens, "Buyer must receive tokens directly in wallet");
    }

    function test_RevertWhenTransferringLockedTokens() public {
        vm.prank(buyer1);
        presale.buyWithBNB{value: 1 ether}();

        // Buyer1 tries to transfer to Buyer2 before launch -> MUST REVERT
        vm.prank(buyer1);
        vm.expectRevert("ROACH: Transfer locked until official DEX launch");
        roach.transfer(buyer2, 10_000 * 1e18);
    }

    function test_StakingAllowedDuringPresaleLock() public {
        vm.prank(buyer1);
        presale.buyWithBNB{value: 1 ether}();

        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(buyer1);
        roach.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount);
        vm.stopPrank();

        assertEq(vault.balances(buyer1), stakeAmount, "Buyer must be able to stake locked tokens");
        assertEq(roach.balanceOf(buyer1), (600_000 - 100_000) * 1e18);
    }

    function test_PermanentLaunchUnlock() public {
        vm.prank(buyer1);
        presale.buyWithBNB{value: 1 ether}();

        // Owner unlocks trading for DEX launch
        vm.prank(owner);
        roach.enableTrading();

        // Now Buyer1 can freely transfer to Buyer2
        vm.prank(buyer1);
        roach.transfer(buyer2, 50_000 * 1e18);

        assertEq(roach.balanceOf(buyer2), 50_000 * 1e18);
    }
}
