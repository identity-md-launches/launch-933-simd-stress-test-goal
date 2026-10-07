// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {InvariantBase, ActorHandler} from "./helpers/InvariantBase.sol";
import {Timelock} from "../src/Timelock.sol";

contract TimelockHandler is ActorHandler {
    Timelock public lock;
    bytes32[] public ids;
    mapping(bytes32 => uint256) public values;
    mapping(bytes32 => uint256) public ready;
    mapping(bytes32 => bool) public cancelled;
    mapping(bytes32 => bool) public executed;
    uint256 public sent;
    bool public fail;

    constructor() {
        lock = new Timelock(address(this));
        vm.deal(address(lock), 100 ether);
        queue(1);
    }

    function receiveCall() external payable {
        require(!fail);
        require(msg.sender == address(lock));
    }

    function queue(uint256 raw) public {
        if (ids.length >= 32) return;
        uint256 value = bound(raw, 1, 1 ether);
        bytes32 id =
            lock.queue(address(this), value, abi.encodeCall(this.receiveCall, ()), bytes32(ids.length));
        ids.push(id);
        values[id] = value;
        ready[id] = vm.getBlockTimestamp() + 2 days;
        ++successfulCalls;
    }

    function cancel(uint256 raw) public {
        bytes32 id = ids[raw % ids.length];
        try lock.cancel(id) {
            cancelled[id] = true;
            ++successfulCalls;
        } catch {}
    }

    function execute(uint256 raw, bool shouldFail) public {
        bytes32 id = ids[raw % ids.length];
        fail = shouldFail;
        try lock.execute(id) {
            require(vm.getBlockTimestamp() >= ready[id], "early execution");
            require(!cancelled[id] && !executed[id], "terminal operation reused");
            executed[id] = true;
            sent += values[id];
            ++successfulCalls;
        } catch {}
    }

    function unauthorized(uint256 who, uint256 raw) public {
        // None of the actors are admin; successful execution would violate authorization.
        bool success =
            callAs(actor(who), address(lock), abi.encodeCall(lock.execute, (ids[raw % ids.length])));
        require(!success, "non-admin execution");
    }

    function count() external view returns (uint256) {
        return ids.length;
    }
}

contract TimelockInvariantTest is InvariantBase {
    TimelockHandler private handler;

    function setUp() public {
        handler = new TimelockHandler();
        target(address(handler));
        exclude(address(handler), TimelockHandler.receiveCall.selector);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_DelayTerminalFlagsAndETHConservation() public view {
        Timelock lock = handler.lock();
        eq(address(lock).balance + handler.sent(), 100 ether);
        eq(address(handler).balance, handler.sent());
        for (uint256 i; i < handler.count(); ++i) {
            bytes32 id = handler.ids(i);
            (uint256 ready, bool done, bool cancelled) = lock.status(id);
            eq(ready, handler.ready(id));
            ok(done == handler.executed(id) && cancelled == handler.cancelled(id));
            ok(!(done && cancelled));
        }
    }
}
