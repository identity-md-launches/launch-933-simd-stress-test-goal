// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Liquid donation-yield vault with an optional FIFO redemption queue.
contract Vault4626 is ERC4626, Ownable2Step, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error TransferTax();
    error NotReady();
    error Slippage();
    uint256 public depositCap;
    uint256 public reservedAssets;
    uint256 public head;
    uint256 public tail;
    uint256 public constant QUEUE_DELAY = 1 days;

    struct Request {
        address account;
        uint256 shares;
        uint256 readyAt;
    }
    mapping(uint256 => Request) public requests;
    mapping(address => uint256) public claimable;
    event CapSet(uint256 cap);
    event YieldAdded(address indexed funder, uint256 assets);
    event Requested(uint256 indexed id, address indexed account, uint256 shares, uint256 readyAt);
    event RequestCancelled(uint256 indexed id);
    event Processed(uint256 indexed id, uint256 assets);
    event Claimed(address indexed account, uint256 assets);

    constructor(IERC20 token, address admin, uint256 cap)
        ERC20("SIMD Vault Share", "SVS")
        ERC4626(token)
        Ownable(admin)
    {
        if (address(token).code.length == 0 || cap == 0) revert InvalidInput();
        depositCap = cap;
        emit CapSet(cap);
    }

    /// @notice Assets backing live shares; queued claims already priced are excluded.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - reservedAssets;
    }

    /// @notice Remaining active-asset deposit capacity.
    function maxDeposit(address) public view override returns (uint256) {
        uint256 managed = totalAssets();
        return managed >= depositCap ? 0 : depositCap - managed;
    }

    /// @notice Maximum shares mintable within the current deposit cap.
    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice Deposit an exact untaxed asset amount, rounding shares down.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @notice Mint exact shares, rounding asset cost up; transfer taxes revert.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @notice Withdraw exact assets, rounding share cost up; allowance needed for another owner.
    function withdraw(uint256 assets, address receiver, address account)
        public
        override
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, account);
    }

    /// @notice Redeem exact shares, rounding assets down; transfer taxes revert.
    function redeem(uint256 shares, address receiver, address account)
        public
        override
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, account);
    }

    /// @notice Extension for taxed input: mint against net receipt with explicit share slippage.
    function depositReceived(uint256 amount, address receiver, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        uint256 beforeAssets = totalAssets();
        uint256 received = IERC20(asset()).pull(amount);
        if (received > depositCap || beforeAssets > depositCap - received) revert InvalidInput();
        shares = Math.mulDiv(received, totalSupply() + 1e6, beforeAssets + 1);
        if (shares == 0 || shares < minShares || receiver == address(this)) revert Slippage();
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, received, shares);
    }

    /// @notice Add yield to all active shares by donating caller funds.
    function addYield(uint256 amount) external nonReentrant {
        uint256 received = IERC20(asset()).pull(amount);
        emit YieldAdded(msg.sender, received);
    }

    /// @notice Owner changes future deposit capacity; cannot extract or freeze assets.
    function setCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit CapSet(cap);
    }

    /// @notice Escrow caller's shares for permissionless processing after one day.
    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 id) {
        if (shares == 0) revert InvalidInput();
        id = tail++;
        uint256 ready = block.timestamp + QUEUE_DELAY;
        requests[id] = Request(msg.sender, shares, ready);
        _transfer(msg.sender, address(this), shares);
        emit Requested(id, msg.sender, shares, ready);
    }

    /// @notice Recover caller's unprocessed shares; processor skips cancelled entries.
    function cancelRequest(uint256 id) external nonReentrant {
        Request memory r = requests[id];
        if (r.account != msg.sender || r.shares == 0) revert InvalidInput();
        delete requests[id];
        _transfer(address(this), msg.sender, r.shares);
        emit RequestCancelled(id);
    }

    /// @notice Process exactly one FIFO entry, pricing at processing time and reserving a pull claim.
    function processNext() external nonReentrant {
        if (head >= tail) revert NotReady();
        uint256 id = head;
        Request memory r = requests[id];
        if (r.shares > 0 && block.timestamp < r.readyAt) revert NotReady();
        head = id + 1;
        delete requests[id];
        uint256 assets = 0;
        if (r.shares > 0) {
            assets = previewRedeem(r.shares);
            _burn(address(this), r.shares);
            reservedAssets += assets;
            claimable[r.account] += assets;
        }
        emit Processed(id, assets);
    }

    /// @notice Pull caller's processed assets, enforcing a net receipt minimum for taxed outputs.
    function claim(uint256 minimum) external nonReentrant {
        uint256 assets = claimable[msg.sender];
        if (assets == 0) revert InvalidInput();
        claimable[msg.sender] = 0;
        reservedAssets -= assets;
        emit Claimed(msg.sender, assets);
        IERC20(asset()).send(msg.sender, assets, minimum);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (caller != msg.sender || assets == 0 || shares == 0 || receiver == address(this)) {
            revert InvalidInput();
        }
        if (IERC20(asset()).pull(assets) < assets) revert TransferTax();
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        if (shares == 0) revert InvalidInput();
        if (caller != account) _spendAllowance(account, caller, shares);
        _burn(account, shares);
        emit Withdraw(caller, receiver, account, assets, shares);
        IERC20(asset()).send(receiver, assets, assets);
    }
}
