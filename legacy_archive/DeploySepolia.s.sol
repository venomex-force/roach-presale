// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/RoachPresalePro.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {
        _mint(msg.sender, 1_000_000 * 10**18);
    }
}

contract DeploySepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address payable treasury = payable(0x278B4D3804Ad3E6551B92ec20143F447eA2Dbf4A);
        
        // Sepolia Official Chainlink Parameters
        address ethUsdFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
        bytes32 keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
        uint256 subId = 0;
        uint256 heartbeat = 3600;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CockroachAI Token (1 Billion Supply)
        CockroachAI token = new CockroachAI();

        // 2. Deploy Mock USDT
        MockUSDT usdt = new MockUSDT();

        // 3. Deploy RoachPresalePro Engine (Exact Constructor Order)
        RoachPresalePro presale = new RoachPresalePro(
            address(token),
            address(usdt),
            ethUsdFeed,
            vrfCoordinator,
            keyHash,
            subId,
            treasury,
            heartbeat
        );

        // 4. Connect Token & Seed Supply
        token.setPresaleContract(address(presale));
        token.transfer(address(presale), 520_000_000 * 10**18); // 500M Presale + 20M Staking
        
        // 5. Fund Monthly VRF Reserve Pool
        token.approve(address(presale), 10_000_000 * 10**18);
        presale.fundMonthlyRewardPool(10_000_000 * 10**18);

        vm.stopBroadcast();

        console.log("==================================================");
        console.log("CockroachAI Token Deployed at :", address(token));
        console.log("Mock USDT Deployed at          :", address(usdt));
        console.log("RoachPresalePro Engine at     :", address(presale));
        console.log("==================================================");
    }
}
