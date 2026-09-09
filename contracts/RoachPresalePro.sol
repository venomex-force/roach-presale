// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RoachPresalePro is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable roachToken;
    uint256 public constant TOKEN_RATE_PER_BNB = 600000; // Example: 1 BNB = 600,000 $ROACH

    event TokensPurchased(address indexed buyer, uint256 bnbAmount, uint256 tokenAmount);

    constructor(address _roachToken) Ownable(msg.sender) {
        roachToken = IERC20(_roachToken);
    }

    receive() external payable {
        buyWithBNB();
    }

    function buyWithBNB() public payable nonReentrant {
        require(msg.value > 0, "Presale: Send BNB to buy");

        uint256 tokenAmount = (msg.value * TOKEN_RATE_PER_BNB);
        require(roachToken.balanceOf(address(this)) >= tokenAmount, "Presale: Insufficient tokens in pool");

        // Buyer ke wallet me instant transfer
        roachToken.safeTransfer(msg.sender, tokenAmount);

        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }

    function withdrawFunds() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
