// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vault4626} from "../src/Vault4626.sol";
import {Subscription} from "../src/Subscription.sol";

contract LegacyToken is ERC20 {
    uint8 public mode;
    bool public paused;
    constructor() ERC20("Legacy", "L") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }

    function configure(uint8 resultMode, bool pause) external {
        mode = resultMode;
        paused = pause;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!paused, "paused");
        super.transfer(to, amount);
        if (mode == 1) return false;
        if (mode == 2) {
            assembly { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!paused, "paused");
        super.transferFrom(from, to, amount);
        if (mode == 1) return false;
        if (mode == 2) {
            assembly { return(0, 0) }
        }
        return true;
    }
}

contract TokenCompatibilityTest is TestBase {
    LegacyToken private token;
    Vault4626 private vault;
    Subscription private subscription;

    function setUp() public {
        token = new LegacyToken();
        vault = new Vault4626(token, address(this), 10000e6);
        subscription = new Subscription(token, CAROL, 10e6);
        token.mint(address(this), 1000e6);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(subscription), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzNoReturnTokenDepositWithdrawalRoundTrip(uint256 raw) public {
        uint256 amount = bound(raw, 1, 500e6);
        token.configure(2, false);
        uint256 shares = vault.deposit(amount, address(this));
        vault.redeem(shares, address(this), address(this));
        subscription.deposit(amount);
        subscription.withdraw(amount, amount);
        eq(token.balanceOf(address(this)), 1000e6);
        eq(vault.totalSupply(), 0);
        eq(subscription.totalPrepaid(), 0);
    }

    function testFalseReturnTransferFromRollsBackBothTokensAndEntitlements() public {
        token.configure(1, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.deposit(100e6, address(this));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        subscription.deposit(100e6);
        eq(token.balanceOf(address(this)), 1000e6);
        eq(vault.totalSupply(), 0);
        eq(subscription.totalPrepaid(), 0);
    }

    function testFalseReturnOutputPreservesSharesAndPrepaidBalance() public {
        uint256 shares = vault.deposit(100e6, address(this));
        subscription.deposit(100e6);
        token.configure(1, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.redeem(shares, address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        subscription.withdraw(100e6, 100e6);
        eq(vault.balanceOf(address(this)), shares);
        eq(subscription.prepaid(address(this)), 100e6);
        eq(token.balanceOf(address(vault)), 100e6);
        eq(token.balanceOf(address(subscription)), 100e6);
    }

    function testTokenPauseBlocksOutputsWithoutDestroyingClaims() public {
        uint256 shares = vault.deposit(100e6, address(this));
        subscription.deposit(100e6);
        token.configure(0, true);
        vm.expectRevert(bytes("paused"));
        vault.redeem(shares, address(this), address(this));
        vm.expectRevert(bytes("paused"));
        subscription.withdraw(100e6, 100e6);
        eq(vault.balanceOf(address(this)), shares);
        eq(subscription.prepaid(address(this)), 100e6);
        token.configure(0, false);
        vault.redeem(shares, address(this), address(this));
        subscription.withdraw(100e6, 100e6);
        eq(token.balanceOf(address(this)), 1000e6);
    }
}
