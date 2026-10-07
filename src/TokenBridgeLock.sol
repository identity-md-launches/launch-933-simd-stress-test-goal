// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TokenIO} from "./common/TokenIO.sol";

/// @notice Custodial lock/unlock simulator using an immutable threshold relayer set; not a real bridge.
contract TokenBridgeLock is EIP712, ReentrancyGuard {
    using TokenIO for IERC20;
    error InvalidInput();
    error InvalidAuthorization();
    IERC20 public immutable token;
    uint256 public immutable threshold;
    mapping(address => bool) public isRelayer;
    mapping(bytes32 => bool) public processed;
    uint256 public nonce;
    bytes32 public constant UNLOCK_TYPEHASH =
        keccak256("Unlock(bytes32 sourceId,address recipient,uint256 amount,uint256 deadline)");
    event RelayerConfigured(address indexed relayer);
    event Locked(uint256 indexed nonce, address indexed sender, bytes32 indexed destination, uint256 amount);
    event Unlocked(bytes32 indexed sourceId, address indexed recipient, uint256 amount);

    constructor(IERC20 asset, address[] memory relayers, uint256 required) EIP712("SIMD Bridge Lock", "1") {
        if (
            address(asset).code.length == 0 || relayers.length == 0 || relayers.length > 32 || required == 0
                || required > relayers.length
        ) revert InvalidInput();
        token = asset;
        threshold = required;
        for (uint256 i; i < relayers.length; ++i) {
            address relayer = relayers[i];
            if (relayer == address(0) || isRelayer[relayer]) revert InvalidInput();
            isRelayer[relayer] = true;
            emit RelayerConfigured(relayer);
        }
    }

    /// @notice Lock caller funds, assign a unique local nonce, and emit net receipt plus destination identifier.
    function lock(uint256 amount, bytes32 destination) external nonReentrant returns (uint256 id) {
        if (destination == bytes32(0)) revert InvalidInput();
        uint256 received = token.pull(amount);
        id = nonce++;
        emit Locked(id, msg.sender, destination, received);
    }

    /// @notice EIP712 digest binding an unlock to this contract, chain, source id, recipient, amount and expiry.
    function unlockDigest(bytes32 sourceId, address recipient, uint256 amount, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(UNLOCK_TYPEHASH, sourceId, recipient, amount, deadline)));
    }

    /// @notice Recipient presents exactly threshold distinct, ascending-address relayer signatures and pulls payment.
    function unlock(
        bytes32 sourceId,
        uint256 amount,
        uint256 deadline,
        bytes[] calldata signatures,
        uint256 minimum
    ) external nonReentrant {
        if (
            sourceId == bytes32(0) || amount == 0 || block.timestamp > deadline || processed[sourceId]
                || signatures.length != threshold
        ) revert InvalidAuthorization();
        bytes32 digest = unlockDigest(sourceId, msg.sender, amount, deadline);
        address previous = address(0);
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isRelayer[signer] || signer <= previous) revert InvalidAuthorization();
            previous = signer;
        }
        processed[sourceId] = true;
        emit Unlocked(sourceId, msg.sender, amount);
        token.send(msg.sender, amount, minimum);
    }
}
