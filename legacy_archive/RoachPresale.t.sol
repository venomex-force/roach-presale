// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Minimal ERC20 Mock
contract MockERC20 {
    string public name = "Mock USDT";
    string public symbol = "USDT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Allowance exceeded");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// CockroachAI Token Mock
contract CockroachToken is MockERC20 {
    constructor() {
        name = "CockroachAI";
        symbol = "ROACH";
    }
}

// Presale Engine Contract
contract RoachPresale {
    address public owner;
    CockroachToken public roachToken;
    MockERC20 public usdtToken;

    uint256 public bnbPriceUsd = 600; // $600 per BNB
    uint256 public stagePriceUsd = 100; // $0.0010 (scaled by 1e5: 100 = $0.0010)
    uint256 public constant REFERRAL_PERCENT = 10;

    mapping(address => uint256) public purchasedTokens;

    event TokensPurchasedBNB(address indexed buyer, address indexed referrer, uint256 bnbAmount, uint256 tokenAmount);
    event TokensPurchasedUSDT(address indexed buyer, address indexed referrer, uint256 usdtAmount, uint256 tokenAmount);

    constructor(address _roach, address _usdt) {
        owner = msg.sender;
        roachToken = CockroachToken(_roach);
        usdtToken = MockERC20(_usdt);
    }

    // Buy with BNB
    function buyWithBNB(address referrer) external payable {
        require(msg.value > 0, "Zero BNB sent");

        uint256 refBonus = 0;
        if (referrer != address(0) && referrer != msg.sender) {
            refBonus = (msg.value * REFERRAL_PERCENT) / 100;
            payable(referrer).transfer(refBonus);
        }

        // Calculation: (bnbAmount * bnbPriceUsd * 10^18) / (stagePrice / 10^5)
        // For 1 BNB ($600) @ $0.0010/token = 600,000 tokens
        uint256 tokenAmount = (msg.value * bnbPriceUsd * 100000) / stagePriceUsd;
        purchasedTokens[msg.sender] += tokenAmount;

        emit TokensPurchasedBNB(msg.sender, referrer, msg.value, tokenAmount);
    }

    // Buy with USDT
    function buyWithUSDT(uint256 usdtAmount, address referrer) external {
        require(usdtAmount > 0, "Zero USDT");
        usdtToken.transferFrom(msg.sender, address(this), usdtAmount);

        if (referrer != address(0) && referrer != msg.sender) {
            uint256 refBonus = (usdtAmount * REFERRAL_PERCENT) / 100;
            usdtToken.transfer(referrer, refBonus);
        }

        uint256 tokenAmount = (usdtAmount * 100000) / stagePriceUsd;
        purchasedTokens[msg.sender] += tokenAmount;

        emit TokensPurchasedUSDT(msg.sender, referrer, usdtAmount, tokenAmount);
    }

    function withdrawBNB() external {
        require(msg.sender == owner, "Only Owner");
        payable(owner).transfer(address(this).balance);
    }
}

// Foundry Simulation Suite
contract RoachPresaleTest is Test {
    RoachPresale presale;
    CockroachToken roach;
    MockERC20 usdt;

    address owner = address(0xAA);
    address alice = address(0xBB); // Buyer
    address bob = address(0xCC);   // Referrer

    function setUp() public {
        vm.deal(owner, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 0 ether);

        vm.startPrank(owner);
        roach = new CockroachToken();
        usdt = new MockERC20();
        presale = new RoachPresale(address(roach), address(usdt));
        vm.stopPrank();

        usdt.mint(alice, 5000 * 1e18); // 5000 USDT to Alice
    }

    // Test 1: BNB Purchase with Referral Bonus
    function test_BuyWithBNB_And_ReferralTransfer() public {
        vm.startPrank(alice);
        
        uint256 bnbToSend = 1 ether; // 1 BNB = $600 => should yield 600,000 $ROACH
        presale.buyWithBNB{value: bnbToSend}(bob);

        vm.stopPrank();

        // Check Alice got 600,000 tokens allocated
        assertEq(presale.purchasedTokens(alice), 600_000 * 1e18);

        // Check Bob received 10% instant BNB commission (0.1 BNB)
        assertEq(bob.balance, 0.1 ether);

        // Contract retains remaining 0.9 BNB
        assertEq(address(presale).balance, 0.9 ether);
    }

    // Test 2: USDT Purchase with Referral Bonus
    function test_BuyWithUSDT_And_ReferralTransfer() public {
        vm.startPrank(alice);
        
        uint256 usdtAmount = 100 * 1e18; // 100 USDT => should yield 100,000 $ROACH @ $0.001
        usdt.approve(address(presale), usdtAmount);
        presale.buyWithUSDT(usdtAmount, bob);

        vm.stopPrank();

        // Check Alice's token balance
        assertEq(presale.purchasedTokens(alice), 100_000 * 1e18);

        // Bob receives 10% instant USDT commission (10 USDT)
        assertEq(usdt.balanceOf(bob), 10 * 1e18);

        // Presale holds 90 USDT
        assertEq(usdt.balanceOf(address(presale)), 90 * 1e18);
    }

    // Test 3: Owner BNB Withdrawal
    function test_OwnerWithdrawal() public {
        vm.prank(alice);
        presale.buyWithBNB{value: 2 ether}(address(0));

        uint256 initialOwnerBalance = owner.balance;

        vm.prank(owner);
        presale.withdrawBNB();

        assertEq(owner.balance, initialOwnerBalance + 2 ether);
        assertEq(address(presale).balance, 0);
    }
}
