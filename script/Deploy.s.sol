// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/CockroachToken.sol";
import "../contracts/RoachPresalePro.sol";

contract DeployProtocol is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying contracts with deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CockroachToken (1 Billion Supply)
        CockroachToken roach = new CockroachToken("CockroachAI", "ROACH", 1_000_000_000);
        console.log("CockroachToken deployed at:", address(roach));

        // 2. Deploy Presale Contract
        RoachPresalePro presale = new RoachPresalePro(address(roach));
        console.log("RoachPresalePro deployed at:", address(presale));

        // 3. Set Lock Exemption for Presale Contract
        roach.setExemption(address(presale), true);
        console.log("Presale contract exempted from transfer lock.");

        // 4. Fund Presale Pool (400,000,000 ROACH - 40% Allocation)
        uint256 presaleFundAmount = 400_000_000 * 1e18;
        roach.transfer(address(presale), presaleFundAmount);
        console.log("Transferred 400M $ROACH to Presale Pool.");

        vm.stopBroadcast();
    }
}
