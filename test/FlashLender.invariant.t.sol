// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {FlashLender} from "../src/FlashLender.sol";
import {FlashBorrower} from "./FlashLender.t.sol";

contract FlashHandler is ActorHandler {
    MockToken public token;
    FlashLender public lender;
    FlashBorrower public borrower;
    uint256 public funded;
    uint256 public withdrawn;
    uint256 public fees;
    bool public badCallback;

    constructor() {
        token = new MockToken(6);
        lender = new FlashLender(token, address(this));
        borrower = new FlashBorrower(lender, token);
        token.mint(address(this), 1000000e6);
        token.approve(address(lender), type(uint256).max);
        token.mint(address(borrower), 1000000e6);
        fund(10000e6 - 1);
    }

    function fund(uint256 raw) public {
        uint256 amount = bound(raw, 1, 10000e6);
        try lender.fund(amount) {
            funded += amount;
            ++successfulCalls;
        } catch {}
    }

    function withdraw(uint256 raw) public {
        uint256 cash = token.balanceOf(address(lender));
        if (cash == 0) return;
        uint256 amount = bound(raw, 1, cash);
        lender.withdraw(amount, amount);
        withdrawn += amount;
        ++successfulCalls;
    }

    function loan(uint256 raw, uint8 mode) public {
        uint256 cash = token.balanceOf(address(lender));
        if (cash == 0) return;
        uint256 amount = bound(raw, 1, cash);
        uint256 fee = lender.flashFee(address(token), amount);
        mode %= 4;
        try borrower.run(amount, mode) {
            fees += fee;
            ++successfulCalls;
            if (mode == 1 || mode == 2 || (mode == 3 && !borrower.reentryBlocked())) badCallback = true;
        } catch {}
    }

    function unauthorizedWithdraw(uint256 who, uint256 raw) public {
        if (callAs(actor(who), address(lender), abi.encodeCall(lender.withdraw, (bound(raw, 1, 1000e6), 0))))
        {
            badCallback = true;
        }
    }
}

contract FlashLenderInvariantTest is InvariantBase {
    FlashHandler private handler;

    function setUp() public {
        handler = new FlashHandler();
        target(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_LoansNeverReduceIdleCapital() public view {
        FlashLender lender = handler.lender();
        uint256 cash = handler.token().balanceOf(address(lender));
        eq(cash + handler.withdrawn(), handler.funded() + handler.fees());
        eq(lender.maxFlashLoan(address(handler.token())), cash);
        ok(!handler.badCallback());
    }
}
