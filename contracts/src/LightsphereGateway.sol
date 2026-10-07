// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import {LightsphereTypes as T} from "./LightsphereTypes.sol";
import {IClprApplication, IClprServiceSend, CLPR_REPLY_SUCCESS} from "./interfaces/IClpr.sol";

/// @title LightsphereGateway
/// @notice Reference gateway for a network-mode sphere. Runs on the sphere network, keeps sphere-local balances
///         for the anchored assets, and maintains the checkpoint Merkle tree incrementally so a checkpoint
///         costs the same however many accounts exist.
/// @dev Positional tree of depth TREE_DEPTH, hashed with sorted pairs so proofs verify with OpenZeppelin
///      MerkleProof. Empty subtrees are bytes32(0); a parent of two empty children is also zero, which never
///      lies on the path of a real leaf. Every leaf change emits LeafUpdated so any indexer can rebuild the
///      tree, and the proofs, for any checkpoint.
contract LightsphereGateway is IClprApplication {
    uint256 public constant TREE_DEPTH = 20;

    address public immutable clprService;
    bytes32 public immutable channelId;
    bytes32 public immutable connectorId;
    address public immutable anchor;
    uint64 public immutable checkpointInterval;
    address private immutable _deployer;

    bytes32 public sphereId;
    mapping(address => bool) public isAsset;

    uint64 public epoch = 1;
    uint64 public lastCheckpointAt;
    uint64 public lastAppliedDepositId;
    uint64 public nextWithdrawalId;

    struct Account {
        uint256 balance;
        uint256 cumDepositsApplied;
        uint256 cumWithdrawalsInitiated;
        uint32 index; // 1-based leaf position, 0 = no leaf yet
    }

    struct PendingWithdrawal {
        address account;
        address asset;
        uint256 amount;
    }

    mapping(bytes32 => Account) internal _accounts; // keccak256(abi.encode(account, asset))
    uint32 public leafCount;
    mapping(uint256 => mapping(uint256 => bytes32)) internal _nodes; // level => position => hash
    mapping(uint64 => PendingWithdrawal) internal _pending; // CLPR messageId => withdrawal

    event LeafUpdated(
        address indexed account,
        address indexed asset,
        uint32 index,
        uint256 balance,
        uint256 cumDepositsApplied,
        uint256 cumWithdrawalsInitiated
    );
    event DepositApplied(uint64 depositId, address indexed recipient, address indexed asset, uint256 amount);
    event Transfer(address indexed from, address indexed to, address indexed asset, uint256 amount);
    event WithdrawalSent(
        uint64 withdrawalId, uint64 epoch, address indexed account, address indexed asset, uint256 amount, address recipient
    );
    event WithdrawalRefunded(uint64 withdrawalMessageId, address indexed account, address indexed asset, uint256 amount);
    event CheckpointSent(uint64 epoch, bytes32 root, uint64 lastAppliedDepositId);

    error Unauthorized();
    error AlreadyInitialized();
    error NotInitialized();
    error UnknownAsset();
    error InvalidMessage();
    error InsufficientBalance();
    error TooEarly();
    error TreeFull();

    constructor(
        address clprService_,
        bytes32 channelId_,
        bytes32 connectorId_,
        address anchor_,
        uint64 checkpointInterval_,
        address[] memory assets_
    ) {
        clprService = clprService_;
        channelId = channelId_;
        connectorId = connectorId_;
        anchor = anchor_;
        checkpointInterval = checkpointInterval_;
        _deployer = msg.sender;
        for (uint256 i; i < assets_.length; ++i) {
            isAsset[assets_[i]] = true;
        }
    }

    /// @notice One-time binding to the anchor's sphereId (which itself commits to this gateway's address).
    function initialize(bytes32 sphereId_) external {
        if (msg.sender != _deployer) revert Unauthorized();
        if (sphereId != bytes32(0)) revert AlreadyInitialized();
        sphereId = sphereId_;
        lastCheckpointAt = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- CLPR

    function onClprMessage(bytes32 channelId_, bytes calldata sender, bytes calldata messageData)
        external
        returns (bytes memory)
    {
        if (msg.sender != clprService || channelId_ != channelId) revert Unauthorized();
        if (keccak256(sender) != keccak256(abi.encodePacked(anchor))) revert Unauthorized();
        (uint8 msgType, bytes32 sid, bytes memory body) = abi.decode(messageData, (uint8, bytes32, bytes));
        if (sphereId == bytes32(0)) revert NotInitialized();
        if (msgType != T.MSG_DEPOSIT || sid != sphereId) revert InvalidMessage();
        (uint64 depositId, address asset, uint256 amount, address recipient) =
            abi.decode(body, (uint64, address, uint256, address));
        if (!isAsset[asset]) revert UnknownAsset();
        if (depositId <= lastAppliedDepositId) revert InvalidMessage();

        Account storage a = _accounts[_key(recipient, asset)];
        a.balance += amount;
        a.cumDepositsApplied += amount;
        lastAppliedDepositId = depositId;
        _updateLeaf(recipient, asset, a);
        emit DepositApplied(depositId, recipient, asset, amount);
        return "";
    }

    /// @dev Must never revert. A failed WITHDRAW is undone on the sphere, including its cumulative counter.
    function onClprResponse(bytes32 channelId_, uint64 messageId, uint8 replyStatus, bytes calldata) external {
        if (msg.sender != clprService || channelId_ != channelId) return;
        PendingWithdrawal memory w = _pending[messageId];
        if (w.account == address(0)) return;
        delete _pending[messageId];
        if (replyStatus == CLPR_REPLY_SUCCESS) return;
        Account storage a = _accounts[_key(w.account, w.asset)];
        a.balance += w.amount;
        a.cumWithdrawalsInitiated -= w.amount;
        _updateLeaf(w.account, w.asset, a);
        emit WithdrawalRefunded(messageId, w.account, w.asset, w.amount);
    }

    // ---------------------------------------------------------------- sphere-local actions

    function transfer(address asset, address to, uint256 amount) external {
        if (!isAsset[asset]) revert UnknownAsset();
        Account storage from = _accounts[_key(msg.sender, asset)];
        if (from.balance < amount) revert InsufficientBalance();
        from.balance -= amount;
        Account storage dst = _accounts[_key(to, asset)];
        dst.balance += amount;
        _updateLeaf(msg.sender, asset, from);
        _updateLeaf(to, asset, dst);
        emit Transfer(msg.sender, to, asset, amount);
    }

    /// @notice Burns a sphere-local balance and asks the anchor to pay `recipient`. The anchor releases it once
    ///         the checkpoint for the current epoch has arrived.
    function withdraw(address asset, uint256 amount, address recipient) external returns (uint64 withdrawalId) {
        if (!isAsset[asset]) revert UnknownAsset();
        if (sphereId == bytes32(0)) revert NotInitialized();
        Account storage a = _accounts[_key(msg.sender, asset)];
        if (amount == 0 || a.balance < amount) revert InsufficientBalance();
        a.balance -= amount;
        a.cumWithdrawalsInitiated += amount;
        _updateLeaf(msg.sender, asset, a);

        withdrawalId = ++nextWithdrawalId;
        bytes memory payload =
            abi.encode(T.MSG_WITHDRAW, sphereId, abi.encode(withdrawalId, epoch, msg.sender, asset, amount, recipient));
        uint64 messageId =
            IClprServiceSend(clprService).sendMessage(channelId, connectorId, abi.encodePacked(anchor), payload);
        _pending[messageId] = PendingWithdrawal(msg.sender, asset, amount);
        emit WithdrawalSent(withdrawalId, epoch, msg.sender, asset, amount, recipient);
    }

    /// @notice Closes the current epoch and sends its balances root to the anchor. Anyone may call once the
    ///         interval has passed.
    function checkpoint() external {
        if (sphereId == bytes32(0)) revert NotInitialized();
        if (block.timestamp < uint256(lastCheckpointAt) + checkpointInterval) revert TooEarly();
        bytes32 root = _nodes[TREE_DEPTH][0];
        bytes memory payload =
            abi.encode(T.MSG_CHECKPOINT, sphereId, abi.encode(epoch, root, lastAppliedDepositId));
        IClprServiceSend(clprService).sendMessage(channelId, connectorId, abi.encodePacked(anchor), payload);
        emit CheckpointSent(epoch, root, lastAppliedDepositId);
        lastCheckpointAt = uint64(block.timestamp);
        ++epoch;
    }

    // ---------------------------------------------------------------- tree

    function _updateLeaf(address account, address asset, Account storage a) internal {
        if (a.index == 0) {
            if (leafCount == uint32(1 << TREE_DEPTH)) revert TreeFull();
            a.index = ++leafCount;
        }
        bytes32 h = T.leafHash(account, asset, a.balance, a.cumDepositsApplied, a.cumWithdrawalsInitiated);
        uint256 pos = a.index - 1;
        _nodes[0][pos] = h;
        for (uint256 level; level < TREE_DEPTH; ++level) {
            bytes32 sibling = _nodes[level][pos ^ 1];
            h = (h == bytes32(0) && sibling == bytes32(0)) ? bytes32(0) : Hashes.commutativeKeccak256(h, sibling);
            pos >>= 1;
            _nodes[level + 1][pos] = h;
        }
        emit LeafUpdated(account, asset, a.index, a.balance, a.cumDepositsApplied, a.cumWithdrawalsInitiated);
    }

    function _key(address account, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, asset));
    }

    // ---------------------------------------------------------------- views

    function root() external view returns (bytes32) {
        return _nodes[TREE_DEPTH][0];
    }

    function accountOf(address who, address asset) external view returns (Account memory) {
        return _accounts[_key(who, asset)];
    }

    /// @notice Proof against the current root. Wallets call this right after each checkpoint (or rebuild it
    ///         from LeafUpdated events) and keep it for a possible exit.
    function proofOf(address who, address asset) external view returns (bytes32[] memory proof) {
        uint32 index = _accounts[_key(who, asset)].index;
        if (index == 0) return proof;
        proof = new bytes32[](TREE_DEPTH);
        uint256 pos = index - 1;
        for (uint256 level; level < TREE_DEPTH; ++level) {
            proof[level] = _nodes[level][pos ^ 1];
            pos >>= 1;
        }
    }
}
