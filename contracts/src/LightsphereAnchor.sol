// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LightsphereTypes as T} from "./LightsphereTypes.sol";
import {ILightsphereNetworkAnchor} from "./interfaces/ILightsphereAnchor.sol";
import {IClprApplication, IClprServiceSend, CLPR_REPLY_SUCCESS} from "./interfaces/IClpr.sol";
import {IHederaAccountService, IHederaTokenServiceLite, HederaResponseCodes} from "./interfaces/IHedera.sol";

/// @title LightsphereAnchor
/// @notice Reference anchor contract for the Lightsphere HIP. Escrows HBAR and HTS fungible tokens for
///         signed-mode spheres (co-signed off-ledger states) and network-mode spheres (a Hiero network
///         connected over CLPR).
contract LightsphereAnchor is ILightsphereNetworkAnchor, IClprApplication, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal constant HTS = address(0x167);
    address internal constant HAS = address(0x16a);
    uint256 internal constant SECP256K1_HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint64 public immutable MIN_CHALLENGE_PERIOD;
    address public immutable clprService;

    struct Sphere {
        Status status;
        uint8 mode;
        uint64 challengePeriod;
        uint64 fundingDeadline;
        uint64 challengeEndsAt;
        uint64 version;
        bool hasState;
        uint32 fundedCount;
        bytes32 appDataHash;
        address[] participants;
        address[] assets;
        uint256[] initialDeposits;
        uint256[] balances;
    }

    struct Network {
        bytes32 channelId;
        bytes32 connectorId;
        address gateway;
        uint64 checkpointInterval;
        uint64 haltTimeout;
        uint64 lastHeardAt;
        uint64 lastEpoch;
        bool hasCheckpoint;
        uint64 lastAppliedDepositId;
        uint64 nextDepositId;
        bytes32 balancesRoot;
    }

    struct PendingDeposit {
        bytes32 sphereId;
        uint64 depositId;
        address depositor;
        address recipient;
        address asset;
        uint256 amount;
    }

    struct PendingWithdrawal {
        address account; // sphere account that burned the balance; its leaf counts the withdrawal
        address recipient;
        address asset;
        uint256 amount;
        uint64 sphereEpoch;
        bool received;
        bool released;
    }

    mapping(bytes32 => Sphere) internal _spheres;
    mapping(bytes32 => Network) internal _networks;
    mapping(bytes32 => mapping(address => bool)) public funded;
    mapping(address => mapping(address => uint256)) internal _claimable;

    /// @notice Assets held for each sphere. Payouts for a sphere can never exceed this.
    mapping(bytes32 => mapping(address => uint256)) public escrow;

    mapping(bytes32 => mapping(address => mapping(address => uint256))) public netDeposited;
    mapping(bytes32 => mapping(address => mapping(address => uint256))) public withdrawn;
    mapping(bytes32 => mapping(address => mapping(address => uint64))) public firstSuccessDepositId;
    mapping(bytes32 => mapping(address => mapping(address => bool))) public exited;
    mapping(bytes32 => PendingDeposit) internal _pendingDeposits; // keccak256(channelId, messageId)
    mapping(bytes32 => mapping(uint64 => PendingWithdrawal)) public withdrawals;

    error InvalidParams();
    error InvalidStatus();
    error NotParticipant();
    error AlreadyFunded();
    error WrongValue();
    error FeeOnTransfer();
    error AssetHasCustomFees(address token);
    error AssociationFailed(address token);
    error UnknownAsset();
    error BadSignatures();
    error ConservationViolated();
    error StaleVersion();
    error WindowClosed();
    error WindowOpen();
    error NotFinal();
    error NothingToWithdraw();
    error TransferFailed();
    error Unauthorized();
    error UnknownMessage();
    error NotReleasable();
    error AlreadyExited();
    error InvalidProof();
    error LeafRequired();
    error EscrowExceeded();
    error TooEarly();

    constructor(address clprService_, uint64 minChallengePeriod) EIP712("Lightsphere", "1") {
        clprService = clprService_;
        MIN_CHALLENGE_PERIOD = minChallengePeriod;
    }

    // ---------------------------------------------------------------- open

    function open(T.SphereParams calldata p) external returns (bytes32 sphereId) {
        uint256 nA = p.assets.length;
        if (nA == 0 || nA > T.MAX_ASSETS) revert InvalidParams();
        for (uint256 i; i < nA; ++i) {
            for (uint256 j = i + 1; j < nA; ++j) {
                if (p.assets[i] == p.assets[j]) revert InvalidParams();
            }
        }

        sphereId = keccak256(abi.encode(block.chainid, address(this), p));
        Sphere storage s = _spheres[sphereId];
        if (s.status != Status.NONE) revert InvalidStatus();

        if (p.mode == T.MODE_SIGNED) {
            _validateSigned(p);
            s.challengePeriod = p.challengePeriod;
            s.fundingDeadline = p.fundingDeadline;
            s.participants = p.participants;
            s.initialDeposits = p.initialDeposits;
            s.status = Status.FUNDING;
        } else if (p.mode == T.MODE_NETWORK) {
            if (
                p.participants.length != 0 || p.initialDeposits.length != 0 || p.challengePeriod != 0
                    || p.fundingDeadline != 0
            ) revert InvalidParams();
            T.NetworkConfig memory c = abi.decode(p.networkConfig, (T.NetworkConfig));
            if (c.gateway == address(0) || c.checkpointInterval == 0 || c.haltTimeout < 3 * uint256(c.checkpointInterval))
            {
                revert InvalidParams();
            }
            Network storage n = _networks[sphereId];
            n.channelId = c.channelId;
            n.connectorId = c.connectorId;
            n.gateway = c.gateway;
            n.checkpointInterval = c.checkpointInterval;
            n.haltTimeout = c.haltTimeout;
            n.lastHeardAt = uint64(block.timestamp);
            s.status = Status.OPEN;
        } else {
            revert InvalidParams();
        }
        s.mode = p.mode;
        s.assets = p.assets;

        for (uint256 a; a < nA; ++a) {
            _prepareAsset(p.assets[a]);
        }

        emit SphereOpened(sphereId, p);

        if (p.mode == T.MODE_SIGNED) {
            uint256 nP = p.participants.length;
            for (uint256 i; i < nP; ++i) {
                bool zeroRow = true;
                for (uint256 a; a < nA; ++a) {
                    if (p.initialDeposits[i * nA + a] != 0) zeroRow = false;
                }
                if (zeroRow) _markFunded(sphereId, s, p.participants[i]);
            }
        } else {
            emit SphereActive(sphereId);
        }
    }

    function _validateSigned(T.SphereParams calldata p) internal view {
        uint256 nP = p.participants.length;
        if (nP < 2 || nP > T.MAX_PARTICIPANTS) revert InvalidParams();
        for (uint256 i; i < nP; ++i) {
            if (p.participants[i] == address(0)) revert InvalidParams();
            for (uint256 j = i + 1; j < nP; ++j) {
                if (p.participants[i] == p.participants[j]) revert InvalidParams();
            }
        }
        if (p.initialDeposits.length != nP * p.assets.length) revert InvalidParams();
        if (p.challengePeriod < MIN_CHALLENGE_PERIOD) revert InvalidParams();
        if (p.fundingDeadline <= block.timestamp) revert InvalidParams();
        if (p.networkConfig.length != 0) revert InvalidParams();
    }

    /// @dev For HTS tokens: reject custom fees and associate the anchor. Anything that does not answer as an
    ///      HTS token is treated as a plain ERC-20 (fee-on-transfer is still caught by balance checks).
    function _prepareAsset(address token) internal {
        if (token == address(0)) return;
        (bool ok, bytes memory ret) =
            HTS.call(abi.encodeWithSelector(IHederaTokenServiceLite.getTokenCustomFees.selector, token));
        if (!ok || ret.length < 128) return;
        if (abi.decode(ret, (int256)) != HederaResponseCodes.SUCCESS) return;
        for (uint256 k = 1; k <= 3; ++k) {
            uint256 offset;
            assembly {
                offset := mload(add(ret, add(32, mul(k, 32))))
            }
            if (offset + 32 > ret.length) revert AssetHasCustomFees(token);
            uint256 len;
            assembly {
                len := mload(add(ret, add(32, offset)))
            }
            if (len != 0) revert AssetHasCustomFees(token);
        }
        (ok, ret) = HTS.call(abi.encodeCall(IHederaTokenServiceLite.associateToken, (address(this), token)));
        if (!ok || ret.length < 32) revert AssociationFailed(token);
        int256 rc = abi.decode(ret, (int256));
        if (rc != HederaResponseCodes.SUCCESS && rc != HederaResponseCodes.TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT) {
            revert AssociationFailed(token);
        }
    }

    // ---------------------------------------------------------------- signed mode: funding

    function fund(bytes32 sphereId) external payable nonReentrant {
        Sphere storage s = _spheres[sphereId];
        if (s.status != Status.FUNDING || s.mode != T.MODE_SIGNED) revert InvalidStatus();
        if (block.timestamp > s.fundingDeadline) revert InvalidStatus();
        uint256 idx = _participantIndex(s, msg.sender);
        if (funded[sphereId][msg.sender]) revert AlreadyFunded();

        uint256 nA = s.assets.length;
        uint256 hbarDue;
        for (uint256 a; a < nA; ++a) {
            uint256 amount = s.initialDeposits[idx * nA + a];
            if (amount == 0) continue;
            address asset = s.assets[a];
            if (asset == address(0)) {
                hbarDue += amount;
            } else {
                _pullToken(asset, msg.sender, amount);
            }
            escrow[sphereId][asset] += amount;
        }
        if (msg.value != hbarDue) revert WrongValue();
        _markFunded(sphereId, s, msg.sender);
    }

    function _markFunded(bytes32 sphereId, Sphere storage s, address participant) internal {
        funded[sphereId][participant] = true;
        emit SphereFunded(sphereId, participant);
        if (++s.fundedCount == s.participants.length) {
            s.status = Status.OPEN;
            emit SphereActive(sphereId);
        }
    }

    function reclaimFunding(bytes32 sphereId) external nonReentrant {
        Sphere storage s = _spheres[sphereId];
        if (s.status != Status.FUNDING) revert InvalidStatus();
        if (block.timestamp <= s.fundingDeadline) revert TooEarly();
        s.status = Status.REFUNDED;
        uint256 nA = s.assets.length;
        for (uint256 i; i < s.participants.length; ++i) {
            address who = s.participants[i];
            if (!funded[sphereId][who]) continue;
            for (uint256 a; a < nA; ++a) {
                _credit(sphereId, who, s.assets[a], s.initialDeposits[i * nA + a]);
            }
        }
        emit SphereRefunded(sphereId);
    }

    // ---------------------------------------------------------------- signed mode: states

    function closeCooperative(T.SphereState calldata state, bytes[] calldata sigs) external nonReentrant {
        Sphere storage s = _spheres[state.sphereId];
        if (s.status != Status.OPEN && s.status != Status.CLOSING) revert InvalidStatus();
        if (!state.isFinal) revert NotFinal();
        _verifyState(s, state, sigs);
        if (s.hasState && state.version < s.version) revert StaleVersion();
        _record(s, state);
        _settle(state.sphereId, s);
    }

    function checkpoint(T.SphereState calldata state, bytes[] calldata sigs) external {
        Sphere storage s = _spheres[state.sphereId];
        if (s.status == Status.CLOSING) {
            if (block.timestamp >= s.challengeEndsAt) revert WindowClosed();
        } else if (s.status != Status.OPEN) {
            revert InvalidStatus();
        }
        _verifyState(s, state, sigs);
        if (s.hasState && state.version <= s.version) revert StaleVersion();
        _record(s, state);
    }

    function startClose(bytes32 sphereId, T.SphereState calldata state, bytes[] calldata sigs) external {
        Sphere storage s = _spheres[sphereId];
        if (s.status != Status.OPEN || s.mode != T.MODE_SIGNED) revert InvalidStatus();
        _participantIndex(s, msg.sender);
        if (sigs.length != 0) {
            if (state.sphereId != sphereId) revert InvalidParams();
            _verifyState(s, state, sigs);
            if (!s.hasState || state.version > s.version) _record(s, state);
        }
        s.status = Status.CLOSING;
        s.challengeEndsAt = uint64(block.timestamp) + s.challengePeriod;
        emit CloseStarted(sphereId, s.version, s.challengeEndsAt);
    }

    function finalizeClose(bytes32 sphereId) external nonReentrant {
        Sphere storage s = _spheres[sphereId];
        if (s.status != Status.CLOSING) revert InvalidStatus();
        if (block.timestamp < s.challengeEndsAt) revert WindowOpen();
        _settle(sphereId, s);
    }

    function _verifyState(Sphere storage s, T.SphereState calldata state, bytes[] calldata sigs) internal {
        if (s.mode != T.MODE_SIGNED) revert InvalidStatus();
        uint256 nP = s.participants.length;
        uint256 nA = s.assets.length;
        if (state.balances.length != nP * nA) revert ConservationViolated();
        for (uint256 a; a < nA; ++a) {
            uint256 total;
            uint256 sum;
            for (uint256 p; p < nP; ++p) {
                total += s.initialDeposits[p * nA + a];
                sum += state.balances[p * nA + a];
            }
            if (sum != total) revert ConservationViolated();
        }
        if (sigs.length != nP) revert BadSignatures();
        bytes32 digest = _hashTypedDataV4(T.hashState(state));
        for (uint256 p; p < nP; ++p) {
            if (!_isAuthorized(s.participants[p], digest, sigs[p])) revert BadSignatures();
        }
    }

    function _record(Sphere storage s, T.SphereState calldata state) internal {
        s.version = state.version;
        s.balances = state.balances;
        s.appDataHash = state.appDataHash;
        s.hasState = true;
        emit StateCheckpointed(state.sphereId, state.version, state.appDataHash);
    }

    function _settle(bytes32 sphereId, Sphere storage s) internal {
        s.status = Status.SETTLED;
        uint256 nA = s.assets.length;
        uint256[] storage bal = s.hasState ? s.balances : s.initialDeposits;
        for (uint256 p; p < s.participants.length; ++p) {
            for (uint256 a; a < nA; ++a) {
                _credit(sphereId, s.participants[p], s.assets[a], bal[p * nA + a]);
            }
        }
        emit SphereSettled(sphereId, s.version, s.appDataHash);
    }

    /// @dev Same result as HIP-632 isAuthorizedRaw. 65-byte signatures that recover to the EVM address alias
    ///      take the cheap ecrecover path; everything else (ED25519, long-zero aliases) goes to 0x16a.
    function _isAuthorized(address who, bytes32 digest, bytes calldata sig) internal returns (bool) {
        if (sig.length == 65) {
            bytes32 r = bytes32(sig[0:32]);
            bytes32 sv = bytes32(sig[32:64]);
            uint8 v = uint8(sig[64]);
            if (uint256(sv) > SECP256K1_HALF_N) return false;
            if (v < 27) v += 27;
            address rec = ecrecover(digest, v, r, sv);
            if (rec != address(0) && rec == who) return true;
        } else if (sig.length != 64) {
            return false;
        }
        (bool ok, bytes memory ret) =
            HAS.call(abi.encodeCall(IHederaAccountService.isAuthorizedRaw, (who, abi.encodePacked(digest), sig)));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    // ---------------------------------------------------------------- network mode: deposits

    function depositToSphere(bytes32 sphereId, address asset, uint256 amount, address recipient)
        external
        payable
        nonReentrant
    {
        Sphere storage s = _spheres[sphereId];
        if (s.mode != T.MODE_NETWORK || s.status != Status.OPEN) revert InvalidStatus();
        if (amount == 0 || recipient == address(0)) revert InvalidParams();
        _assetIndex(s, asset);
        if (asset == address(0)) {
            if (msg.value != amount) revert WrongValue();
        } else {
            if (msg.value != 0) revert WrongValue();
            _pullToken(asset, msg.sender, amount);
        }

        Network storage n = _networks[sphereId];
        uint64 depositId = ++n.nextDepositId;
        escrow[sphereId][asset] += amount;
        netDeposited[sphereId][recipient][asset] += amount;

        bytes memory payload = abi.encode(
            T.MSG_DEPOSIT, sphereId, abi.encode(depositId, asset, amount, recipient)
        );
        uint64 messageId = IClprServiceSend(clprService).sendMessage(
            n.channelId, n.connectorId, abi.encodePacked(n.gateway), payload
        );
        _pendingDeposits[keccak256(abi.encode(n.channelId, messageId))] =
            PendingDeposit(sphereId, depositId, msg.sender, recipient, asset, amount);
        emit DepositSent(sphereId, depositId, recipient, asset, amount);
    }

    /// @dev Must never revert: CLPR delivers responses best-effort and drops a reverting callback.
    function onClprResponse(bytes32 channelId, uint64 messageId, uint8 replyStatus, bytes calldata) external {
        if (msg.sender != clprService) return;
        bytes32 key = keccak256(abi.encode(channelId, messageId));
        PendingDeposit memory d = _pendingDeposits[key];
        if (d.depositId == 0) return;
        delete _pendingDeposits[key];
        Sphere storage s = _spheres[d.sphereId];
        if (s.status != Status.OPEN) return; // halted: the exit formula settles this deposit
        if (replyStatus == CLPR_REPLY_SUCCESS) {
            if (firstSuccessDepositId[d.sphereId][d.recipient][d.asset] == 0) {
                firstSuccessDepositId[d.sphereId][d.recipient][d.asset] = d.depositId;
            }
            return;
        }
        netDeposited[d.sphereId][d.recipient][d.asset] -= d.amount;
        escrow[d.sphereId][d.asset] -= d.amount;
        _claimable[d.depositor][d.asset] += d.amount;
        emit DepositRefunded(d.sphereId, d.depositId);
    }

    // ---------------------------------------------------------------- network mode: inbound messages

    function onClprMessage(bytes32 channelId, bytes calldata sender, bytes calldata messageData)
        external
        returns (bytes memory)
    {
        if (msg.sender != clprService) revert Unauthorized();
        (uint8 msgType, bytes32 sphereId, bytes memory body) = abi.decode(messageData, (uint8, bytes32, bytes));
        Sphere storage s = _spheres[sphereId];
        Network storage n = _networks[sphereId];
        if (s.mode != T.MODE_NETWORK || s.status != Status.OPEN) revert InvalidStatus();
        if (channelId != n.channelId || keccak256(sender) != keccak256(abi.encodePacked(n.gateway))) {
            revert Unauthorized();
        }
        n.lastHeardAt = uint64(block.timestamp);

        if (msgType == T.MSG_WITHDRAW) {
            (uint64 withdrawalId, uint64 epoch, address account, address asset, uint256 amount, address recipient) =
                abi.decode(body, (uint64, uint64, address, address, uint256, address));
            _assetIndex(s, asset);
            PendingWithdrawal storage w = withdrawals[sphereId][withdrawalId];
            if (w.received || recipient == address(0)) revert InvalidParams();
            if (n.hasCheckpoint && epoch <= n.lastEpoch) revert InvalidParams();
            withdrawals[sphereId][withdrawalId] =
                PendingWithdrawal(account, recipient, asset, amount, epoch, true, false);
            emit WithdrawalReceived(sphereId, withdrawalId, epoch, account, recipient, asset, amount);
        } else if (msgType == T.MSG_CHECKPOINT) {
            (uint64 epoch, bytes32 root, uint64 lastApplied) = abi.decode(body, (uint64, bytes32, uint64));
            if (n.hasCheckpoint && epoch <= n.lastEpoch) revert InvalidParams();
            if (lastApplied < n.lastAppliedDepositId || lastApplied > n.nextDepositId) revert InvalidParams();
            n.hasCheckpoint = true;
            n.lastEpoch = epoch;
            n.balancesRoot = root;
            n.lastAppliedDepositId = lastApplied;
            emit CheckpointAccepted(sphereId, epoch, root, lastApplied);
        } else {
            revert UnknownMessage();
        }
        return "";
    }

    /// @notice Credits a withdrawal once a checkpoint covering its epoch has been accepted. Holding it until
    ///         then stops funds that arrived after a checkpoint from being withdrawn and also exited.
    function releaseWithdrawal(bytes32 sphereId, uint64 withdrawalId) external {
        Sphere storage s = _spheres[sphereId];
        if (s.mode != T.MODE_NETWORK || s.status != Status.OPEN) revert InvalidStatus();
        Network storage n = _networks[sphereId];
        PendingWithdrawal storage w = withdrawals[sphereId][withdrawalId];
        if (!w.received || w.released || !n.hasCheckpoint || w.sphereEpoch > n.lastEpoch) revert NotReleasable();
        w.released = true;
        withdrawn[sphereId][w.account][w.asset] += w.amount;
        _credit(sphereId, w.recipient, w.asset, w.amount);
        emit WithdrawalReleased(sphereId, withdrawalId);
    }

    // ---------------------------------------------------------------- network mode: halt and exit

    function declareHalt(bytes32 sphereId) external {
        Sphere storage s = _spheres[sphereId];
        if (s.mode != T.MODE_NETWORK || s.status != Status.OPEN) revert InvalidStatus();
        Network storage n = _networks[sphereId];
        if (block.timestamp <= uint256(n.lastHeardAt) + n.haltTimeout) revert TooEarly();
        s.status = Status.HALTED;
        emit SphereHalted(sphereId, n.lastEpoch);
    }

    function exit(
        bytes32 sphereId,
        address asset,
        uint256 balance,
        uint256 cumDepositsApplied,
        uint256 cumWithdrawalsInitiated,
        bytes32[] calldata proof
    ) external nonReentrant {
        Network storage n = _beginExit(sphereId, asset);
        if (!n.hasCheckpoint) revert InvalidProof();
        bytes32 leaf = T.leafHash(msg.sender, asset, balance, cumDepositsApplied, cumWithdrawalsInitiated);
        if (!MerkleProof.verifyCalldata(proof, n.balancesRoot, leaf)) revert InvalidProof();

        int256 amount = int256(balance)
            + (int256(netDeposited[sphereId][msg.sender][asset]) - int256(cumDepositsApplied))
            + (int256(cumWithdrawalsInitiated) - int256(withdrawn[sphereId][msg.sender][asset]));
        _payExit(sphereId, asset, amount);
    }

    /// @notice Exit for an account with no leaf in the last checkpoint. Allowed only when no deposit to the
    ///         account had been applied by that checkpoint, which makes the result a lower bound of the
    ///         leaf-based amount and so never more than the account is owed.
    function exitWithoutLeaf(bytes32 sphereId, address asset) external nonReentrant {
        Network storage n = _beginExit(sphereId, asset);
        uint64 first = firstSuccessDepositId[sphereId][msg.sender][asset];
        if (n.hasCheckpoint && first != 0 && first <= n.lastAppliedDepositId) revert LeafRequired();
        int256 amount =
            int256(netDeposited[sphereId][msg.sender][asset]) - int256(withdrawn[sphereId][msg.sender][asset]);
        _payExit(sphereId, asset, amount);
    }

    function _beginExit(bytes32 sphereId, address asset) internal returns (Network storage n) {
        Sphere storage s = _spheres[sphereId];
        if (s.status != Status.HALTED) revert InvalidStatus();
        _assetIndex(s, asset);
        if (exited[sphereId][msg.sender][asset]) revert AlreadyExited();
        exited[sphereId][msg.sender][asset] = true;
        n = _networks[sphereId];
    }

    function _payExit(bytes32 sphereId, address asset, int256 amount) internal {
        uint256 pay = amount > 0 ? uint256(amount) : 0;
        _credit(sphereId, msg.sender, asset, pay);
        emit Exited(sphereId, msg.sender, asset, pay);
    }

    // ---------------------------------------------------------------- payouts

    function withdraw(address asset) external nonReentrant {
        uint256 amount = _claimable[msg.sender][asset];
        if (amount == 0) revert NothingToWithdraw();
        _claimable[msg.sender][asset] = 0;
        if (asset == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(msg.sender, asset, amount);
    }

    function _credit(bytes32 sphereId, address to, address asset, uint256 amount) internal {
        if (amount == 0) return;
        if (escrow[sphereId][asset] < amount) revert EscrowExceeded();
        escrow[sphereId][asset] -= amount;
        _claimable[to][asset] += amount;
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert FeeOnTransfer();
    }

    // ---------------------------------------------------------------- views and helpers

    function status(bytes32 sphereId) external view returns (Status) {
        return _spheres[sphereId].status;
    }

    function latestState(bytes32 sphereId) external view returns (uint64 version, bytes32 appDataHash) {
        Sphere storage s = _spheres[sphereId];
        return (s.version, s.appDataHash);
    }

    function claimable(address account, address asset) external view returns (uint256) {
        return _claimable[account][asset];
    }

    function challengeEndsAt(bytes32 sphereId) external view returns (uint64) {
        return _spheres[sphereId].challengeEndsAt;
    }

    function network(bytes32 sphereId) external view returns (Network memory) {
        return _networks[sphereId];
    }

    function stateDigest(T.SphereState calldata state) external view returns (bytes32) {
        return _hashTypedDataV4(T.hashState(state));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _participantIndex(Sphere storage s, address who) internal view returns (uint256) {
        for (uint256 i; i < s.participants.length; ++i) {
            if (s.participants[i] == who) return i;
        }
        revert NotParticipant();
    }

    function _assetIndex(Sphere storage s, address asset) internal view returns (uint256) {
        for (uint256 i; i < s.assets.length; ++i) {
            if (s.assets[i] == asset) return i;
        }
        revert UnknownAsset();
    }
}
