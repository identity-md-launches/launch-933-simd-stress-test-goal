// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./helpers/TestBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {FlashLender, IERC3156FlashBorrower} from "../src/FlashLender.sol";

contract FlashBorrower is IERC3156FlashBorrower {
    FlashLender public lender;
    MockToken public token;
    uint8 public mode;
    bool public reentryBlocked;

    constructor(FlashLender l, MockToken t) {
        lender = l;
        token = t;
    }

    function run(uint256 amount, uint8 m) external {
        mode = m;
        lender.flashLoan(this, address(token), amount, "");
    }

    function onFlashLoan(address initiator, address asset, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == address(lender) && initiator == address(this) && asset == address(token));
        if (mode == 1) return bytes32(0);
        if (mode == 2) return lender.CALLBACK_SUCCESS();
        if (mode == 3) {
            (bool success,) =
                address(lender).call(abi.encodeCall(lender.flashLoan, (this, asset, amount, bytes(""))));
            reentryBlocked = !success;
            require(lender.maxFlashLoan(asset) == 0);
        }
        token.approve(address(lender), amount + fee);
        return lender.CALLBACK_SUCCESS();
    }
}

contract FlashLenderTest is TestBase {
    MockToken token;
    FlashLender lender;
    FlashBorrower borrower;

    function setUp() public {
        token = new MockToken(6);
        lender = new FlashLender(token, address(this));
        borrower = new FlashBorrower(lender, token);
        token.mint(address(lender), 10000e6);
        token.mint(address(borrower), 100e6);
    }

    function testLoanFeeAndWithdrawal() public {
        borrower.run(1000e6, 0);
        eq(token.balanceOf(address(lender)), 100009e5);
        lender.withdraw(100009e5, 100009e5);
        eq(token.balanceOf(address(lender)), 0);
    }

    function testCallbackFailureAndNoRepaymentRollback() public {
        vm.expectRevert(FlashLender.RepaymentFailed.selector);
        borrower.run(100e6, 1);
        vm.expectRevert();
        borrower.run(100e6, 2);
        eq(token.balanceOf(address(lender)), 10000e6);
    }

    function testReentryBlockedAndCallerBound() public {
        borrower.run(100e6, 3);
        ok(borrower.reentryBlocked());
        vm.expectRevert(FlashLender.InvalidInput.selector);
        lender.flashLoan(borrower, address(token), 1e6, "");
    }

    function testUnsupportedTokenAndUnauthorizedWithdraw() public {
        eq(lender.maxFlashLoan(ALICE), 0);
        vm.expectRevert(FlashLender.InvalidInput.selector);
        lender.flashFee(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert();
        lender.withdraw(1, 0);
    }

    function testTaxedPrincipalSafelyRejected() public {
        token.setTax(100);
        vm.expectRevert();
        borrower.run(100e6, 0);
        eq(token.balanceOf(address(lender)), 10000e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeAndConservation(uint256 raw) public {
        uint256 amount = bound(raw, 1, 10000e6);
        uint256 fee = lender.flashFee(address(token), amount);
        borrower.run(amount, 0);
        eq(token.balanceOf(address(lender)), 10000e6 + fee);
        eq(fee, (amount * 9 + 9999) / 10000);
    }

    function testZeroAndExcessLoansNeverCallBorrowerOrMoveFunds() public {
        vm.expectRevert(FlashLender.InvalidInput.selector);
        borrower.run(0, 0);
        vm.expectRevert(FlashLender.InvalidInput.selector);
        borrower.run(10000e6 + 1, 0);
        eq(token.balanceOf(address(lender)), 10000e6);
        eq(token.balanceOf(address(borrower)), 100e6);
    }

    function testRevertedOwnerOutputMinimumLeavesCapitalIntact() public {
        token.setTax(100);
        vm.expectRevert();
        lender.withdraw(100e6, 100e6);
        eq(token.balanceOf(address(lender)), 10000e6);
        lender.withdraw(100e6, 99e6);
        eq(token.balanceOf(address(this)), 99e6);
    }

    event Withdrawn(address indexed owner, uint256 amount);

    function testBusinessEventIncludesActorAndAmount() public {
        vm.expectEmit(true, false, false, true, address(lender));
        emit Withdrawn(address(this), 100e6);
        lender.withdraw(100e6, 100e6);
    }
}
