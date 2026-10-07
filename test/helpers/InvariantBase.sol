// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";

/// @dev Foundry discovers targetContracts without requiring a forge-std dependency.
abstract contract InvariantBase is TestBase {
    address[] private targets;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }
    FuzzSelector[] private excluded;

    function target(address handler) internal {
        targets.push(handler);
    }

    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    function exclude(address handler, bytes4 selector) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        excluded.push(FuzzSelector(handler, selectors));
    }

    function excludeSelectors() public view returns (FuzzSelector[] memory) {
        return excluded;
    }
}

abstract contract ActorHandler is TestBase {
    uint256 public successfulCalls;

    function actor(uint256 seed) internal pure returns (address) {
        return seed % 3 == 0 ? ALICE : seed % 3 == 1 ? BOB : CAROL;
    }

    function callAs(address who, address destination, bytes memory data) internal returns (bool success) {
        vm.prank(who);
        (success,) = destination.call(data);
        if (success) ++successfulCalls;
    }

    function advance(uint256 raw) public {
        vm.warp(block.timestamp + bound(raw, 1, 2 days));
    }
}
