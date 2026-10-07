// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function warp(uint256) external;
    function roll(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function addr(uint256) external returns (address);
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    function eq(uint256 a, uint256 b) internal pure {
        require(a == b, "not equal");
    }

    function eq(address a, address b) internal pure {
        require(a == b, "not equal address");
    }

    function ok(bool condition) internal pure {
        require(condition, "assertion failed");
    }

    function bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + x % (hi - lo + 1);
    }
    receive() external payable {}
}
