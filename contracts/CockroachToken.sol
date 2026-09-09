// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CockroachToken is ERC20, Ownable {
    bool public tradingEnabled = false;
    bool public tradingPermanentlyUnlocked = false;

    mapping(address => bool) public isExemptFromLock;

    event TradingEnabled();
    event ExemptionUpdated(address indexed account, bool isExempt);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        isExemptFromLock[msg.sender] = true;
        _mint(msg.sender, initialSupply_ * 10 ** decimals());
    }

    function setExemption(address account, bool exempt) external onlyOwner {
        isExemptFromLock[account] = exempt;
        emit ExemptionUpdated(account, exempt);
    }

    function enableTrading() external onlyOwner {
        require(!tradingPermanentlyUnlocked, "ROACH: Trading already unlocked permanently");
        tradingEnabled = true;
        tradingPermanentlyUnlocked = true;
        emit TradingEnabled();
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        if (from != address(0) && to != address(0)) {
            if (!tradingEnabled) {
                require(
                    isExemptFromLock[from] || isExemptFromLock[to],
                    "ROACH: Transfer locked until official DEX launch"
                );
            }
        }
        super._update(from, to, value);
    }
}
