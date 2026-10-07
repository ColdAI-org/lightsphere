// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IClprApplication, IClprServiceSend} from "../../src/interfaces/IClpr.sol";

/// @notice One side of a CLPR Channel. Keeps a single ordered outbound queue that carries both initiating
///         messages and responses, as the CLPR spec requires (§3.2.8), so tests see real ordering.
contract MockClprService is IClprServiceSend {
    struct Item {
        bool isResponse;
        uint64 messageId;
        bytes sender; // initiating: 20-byte source app
        address app; // initiating: target app on peer; response: origin app on peer
        bytes data;
        uint8 status;
    }

    uint8 public constant APPLICATION_ERROR = 1;
    uint8 public constant CONNECTOR_UNDERFUNDED = 3;

    MockClprService public peer;
    bytes32 public channelId;
    uint64 public nextMessageId;
    Item[] internal _outbound;
    uint256 public head;
    bool public failNextDelivery;
    /// Models CLPR's best-effort response callback not running (for example, out of gas): the response is
    /// consumed from the queue but the origin application is never told.
    bool public dropNextResponse;
    uint256 public droppedFailureResponses;

    function setDropNextResponse(bool v) external {
        dropNextResponse = v;
    }

    function link(MockClprService peer_, bytes32 channelId_) external {
        peer = peer_;
        channelId = channelId_;
    }

    function setFailNextDelivery(bool v) external {
        failNextDelivery = v;
    }

    function sendMessage(bytes32 ch, bytes32, bytes calldata targetApplication, bytes calldata messageData)
        external
        returns (uint64 messageId)
    {
        require(ch == channelId, "channel");
        messageId = ++nextMessageId;
        _outbound.push(
            Item(false, messageId, abi.encodePacked(msg.sender), address(bytes20(targetApplication)), messageData, 0)
        );
    }

    function pending() external view returns (uint256) {
        return _outbound.length - head;
    }

    /// @notice Moves the oldest queued item to the peer ledger.
    function relayOne() external {
        Item memory it = _outbound[head++];
        if (it.isResponse) peer.deliverResponse(it);
        else peer.deliverData(it);
    }

    function relayAll() external {
        while (head < _outbound.length) this.relayOne();
    }

    /// @dev Called by the peer service: dispatch to the local app and queue the response back.
    function deliverData(Item calldata it) external {
        require(msg.sender == address(peer), "peer");
        uint8 status;
        bytes memory resp;
        if (failNextDelivery) {
            failNextDelivery = false;
            status = CONNECTOR_UNDERFUNDED;
        } else {
            try IClprApplication(it.app).onClprMessage(channelId, it.sender, it.data) returns (bytes memory r) {
                resp = r;
            } catch {
                status = APPLICATION_ERROR;
            }
        }
        _outbound.push(Item(true, it.messageId, "", address(bytes20(it.sender)), resp, status));
    }

    function deliverResponse(Item calldata it) external {
        require(msg.sender == address(peer), "peer");
        if (dropNextResponse) {
            dropNextResponse = false;
            if (it.status != 0) ++droppedFailureResponses;
            return;
        }
        try IClprApplication(it.app).onClprResponse(channelId, it.messageId, it.status, it.data) {} catch {}
    }
}

/// @notice Stand-in for the HTS system contract at 0x167.
contract MockHTS {
    struct FixedFee {
        int64 amount;
        address tokenId;
        bool useHbarsForPayment;
        bool useCurrentTokenForPayment;
        address feeCollector;
    }

    struct FractionalFee {
        int64 numerator;
        int64 denominator;
        int64 minimumAmount;
        int64 maximumAmount;
        bool netOfTransfers;
        address feeCollector;
    }

    struct RoyaltyFee {
        int64 numerator;
        int64 denominator;
        int64 amount;
        address tokenId;
        bool useHbarsForPayment;
        address feeCollector;
    }

    mapping(address => bool) public isHts;
    mapping(address => bool) public hasFee;
    mapping(address => mapping(address => bool)) public associated;

    function register(address token, bool withFee) external {
        isHts[token] = true;
        hasFee[token] = withFee;
    }

    function getTokenCustomFees(address token)
        external
        view
        returns (int64, FixedFee[] memory fixedFees, FractionalFee[] memory fractional, RoyaltyFee[] memory royalty)
    {
        if (!isHts[token]) return (int64(167), fixedFees, fractional, royalty); // INVALID_TOKEN_ID
        if (hasFee[token]) {
            fixedFees = new FixedFee[](1);
            fixedFees[0] = FixedFee(1, address(0), true, false, address(0xfee));
        }
        return (int64(22), fixedFees, fractional, royalty);
    }

    function associateToken(address account, address token) external returns (int64) {
        if (associated[account][token]) return 194;
        associated[account][token] = true;
        return 22;
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, address(0xdead), value / 100);
            value -= value / 100;
        }
        super._update(from, to, value);
    }
}
