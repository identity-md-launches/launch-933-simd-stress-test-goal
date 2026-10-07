// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockToken is ERC20 {
    uint8 private immutable precision;
    uint256 public tax;

    constructor(uint8 d) ERC20("Mock", "MOCK") {
        precision = d;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(uint256 bps) external {
        require(bps <= 10000);
        tax = bps;
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 fee = from == address(0) || to == address(0) ? 0 : amount * tax / 10000;
        if (fee > 0) super._update(from, address(0), fee);
        super._update(from, to, amount - fee);
    }
}

contract MockPrice {
    uint256 public price = 2e18;

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockNFT is ERC721 {
    constructor() ERC721("Mock NFT", "NFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract CallbackToken is ERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool public blocked;
    bool private calling;
    constructor() ERC20("Callback", "CALL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0) && !calling && callbackTarget != address(0)) {
            calling = true;
            (bool success,) = callbackTarget.call(callbackData);
            blocked = !success;
            calling = false;
        }
    }
}
