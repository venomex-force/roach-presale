// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CockroachAI, RoachPresalePro} from "../src/RoachPresalePro.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {
        _mint(msg.sender, 10_000_000 * 1e18);
    }
}

contract MockAggregator {
    uint8 public decimals = 8;
    int256 public price = 600 * 1e8; // $600 per BNB

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract DeployRoach is Script {
    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address myMetaMask = 0x278B4D3804Ad3E6551B92ec20143F447eA2Dbf4A;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Token Deploy
        CockroachAI token = new CockroachAI();
        console.log("-----------------------------------------------");
        console.log("1. CockroachAI Token Deployed at :", address(token));

        // 2. Mock USDT Deploy
        MockUSDT usdt = new MockUSDT();
        console.log("2. Mock USDT Deployed at          :", address(usdt));

        // 3. Mock Price Feed ($600 per BNB)
        MockAggregator feed = new MockAggregator();
        console.log("3. Mock Price Feed ($600) at      :", address(feed));

        // Valid Checksummed VRF Address
        address vrfCoordinator = 0xDA3B641d438362c44415858Ed97B117243785226;
        bytes32 keyHash = 0xc54030491de8524c53fdde651109b0256d69102de7003986c6615ae65738ab3e;
        uint256 subscriptionId = 1;
        uint256 heartbeat = 300;

        // 4. Presale Engine Deploy (Treasury = Your MetaMask)
        RoachPresalePro presale = new RoachPresalePro(
            address(token),
            address(usdt),
            address(feed),
            vrfCoordinator,
            keyHash,
            subscriptionId,
            payable(myMetaMask),
            heartbeat
        );
        console.log("4. RoachPresalePro Engine at     :", address(presale));

        // 5. Whitelist Presale in Token
        token.setPresaleContract(address(presale));

        // 6. Transfer 500M ROACH to Presale Pool
        token.transfer(address(presale), 500_000_000 * 1e18);

        // 7. Fund Reserves (20M Staking + 10M Monthly)
        token.approve(address(presale), 50_000_000 * 1e18);
        presale.fundStakingRewardPool(20_000_000 * 1e18);
        presale.fundMonthlyRewardPool(10_000_000 * 1e18);

        // 8. Send 10,000 USDT and 1,000,000 ROACH to your MetaMask for testing
        usdt.transfer(myMetaMask, 10_000 * 1e18);
        token.transfer(myMetaMask, 1_000_000 * 1e18);

        vm.stopBroadcast();
        console.log("-----------------------------------------------");
        console.log("ALL CONTRACTS DEPLOYED & TEST TOKENS TRANSFERRED!");
        console.log("-----------------------------------------------");
    }
}
